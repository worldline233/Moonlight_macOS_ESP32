#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include "fivetemplates.h"
namespace FiveVision {
constexpr int Size=84;
constexpr int SlotCount=3, SlotSpacing=58;
constexpr int Width=Size+(SlotCount-1)*SlotSpacing, Height=Size;
constexpr int OriginX=800-(SlotCount-1)*SlotSpacing, OriginY=1210;
constexpr double IconThreshold=0.80, DigitThreshold=0.78, DigitMargin=0.065;
using Patch=std::array<uint8_t,Width*Height>;
// Pixel-centre coordinates in the decoded source, independent of window size.
// The original rightmost slot is retained; two equal slots extend to its left.
// Slot indices increase from left to right.
template<class Pixel> bool extract(int w,int h,Pixel pixel,Patch& out) {
    if(w<1280 || h<720 || w>7680 || h>4320 || std::abs(double(w)/h-16.0/9)>0.02) return false;
    for(int y=0;y<Height;++y) for(int x=0;x<Width;++x) {
        double sx=(OriginX+x+0.5)*w/2560.0-0.5,sy=(OriginY+y+0.5)*h/1440.0-0.5;
        int ix=int(std::floor(sx)),iy=int(std::floor(sy));double fx=sx-ix,fy=sy-iy;
        if(ix<0 || iy<0 || ix+1>=w || iy+1>=h)return false;
        double v=(1-fy)*((1-fx)*pixel(ix,iy)+fx*pixel(ix+1,iy))+fy*((1-fx)*pixel(ix,iy+1)+fx*pixel(ix+1,iy+1));
        out[y*Width+x]=uint8_t(std::max(0.0,std::min(255.0,std::floor(v+0.5))));
    }
    return true;
}
inline double correlation(const uint8_t* a,int stride,const uint8_t* b,int w,int h) {
    double sa=0,sb=0,saa=0,sbb=0,sab=0;int n=w*h;
    for(int y=0;y<h;++y) for(int x=0;x<w;++x){double av=a[y*stride+x],bv=b[y*w+x];sa+=av;sb+=bv;saa+=av*av;sbb+=bv*bv;sab+=av*bv;}
    double den=(saa-sa*sa/n)*(sbb-sb*sb/n);
    return den>1 ? (sab-sa*sb/n)/std::sqrt(den) : 0;
}
// -1 means uncertain, 0 absent, 1 icon without a count, 2..5 counted icon.
struct SlotResult {
    int digit=-1;double icon=0,five=0,three=0,margin=0;
    std::array<double,6> scores{};
    int digitOffsetX=0,digitOffsetY=0;
};
struct Result : SlotResult {
    int slot=-1;
    std::array<SlotResult,SlotCount> slotResults{};
};
inline SlotResult detectSlot(const Patch& p,int slot) {
    SlotResult r;int bx=18+slot*SlotSpacing,by=16;
    for(int y=12;y<=20;++y)for(int x=14+slot*SlotSpacing;x<=22+slot*SlotSpacing;++x){
        double s=correlation(p.data()+y*Width+x,Width,Icon,48,43);
        if(s>r.icon){r.icon=s;bx=x;by=y;}
    }
    if(r.icon<IconThreshold) {r.digit=r.icon<0.55 ? 0:-1;return r;}
    const uint8_t (*templates[])[88]={Digits1,Digits2,Digits3,Digits4,Digits5};
    std::array<int,6> offsetsX{},offsetsY{};
    // Actual video places the left/middle count one pixel farther right than
    // the rightmost count. Align the glyph locally instead of fixing its origin.
    for(int dy=-1;dy<=1;++dy)for(int dx=-1;dx<=1;++dx)
        for(int bank=0;bank<BankCount;++bank)for(int d=1;d<=5;++d){
            double score=correlation(p.data()+(by+44+dy)*Width+bx+24+dx,Width,templates[d-1][bank],8,11);
            if(score>r.scores[d]){r.scores[d]=score;offsetsX[d]=dx;offsetsY[d]=dy;}
        }
    r.five=r.scores[5];r.three=r.scores[3];
    int best=1;double second=0;
    for(int d=2;d<=5;++d)if(r.scores[d]>r.scores[best])best=d;
    for(int d=1;d<=5;++d)if(d!=best)second=std::max(second,r.scores[d]);
    r.margin=r.scores[best]-second;
    r.digitOffsetX=offsetsX[best];r.digitOffsetY=offsetsY[best];
    if(r.scores[best]>=DigitThreshold && r.margin>=DigitMargin)r.digit=best;
    return r;
}
inline Result detect(const Patch& p) {
    Result r;int chosen=-1;bool uncertain=false;
    for(int s=0;s<SlotCount;++s){
        r.slotResults[s]=detectSlot(p,s);const auto& v=r.slotResults[s];
        uncertain=uncertain || v.digit==-1;
        if(v.icon>=IconThreshold && (chosen<0 || (v.digit==5 && r.slotResults[chosen].digit!=5) ||
           ((v.digit==5)==(r.slotResults[chosen].digit==5) && v.icon>r.slotResults[chosen].icon)))chosen=s;
    }
    if(chosen>=0){static_cast<SlotResult&>(r)=r.slotResults[chosen];r.slot=chosen;}
    else {r.digit=uncertain ? -1:0;for(const auto& v:r.slotResults)r.icon=std::max(r.icon,v.icon);}
    return r;
}
class Edge {
    bool latched=false;int positive=0,negative=0;uint64_t last=0;
    int requiredPositive=2;uint64_t maxGap=150;
public:
    explicit Edge(int confirmations=2,int intervalMs=10):requiredPositive(std::max(1,std::min(2,confirmations))),maxGap(uint64_t(std::max(150,std::max(1,std::min(1000,intervalMs))*3))){}
    void reset(){latched=false;positive=negative=0;last=0;}
    bool isLatched() const{return latched;}
    int positiveCount() const{return positive;}
    bool update(int digit,uint64_t ms) {
        if(last && (ms<=last || ms-last>maxGap)){positive=negative=0;}last=ms;
        if(digit==5){negative=0;positive=std::min(positive+1,requiredPositive);if(positive>=requiredPositive && !latched){latched=true;return true;}}
        else {positive=0;if(digit>=0 && digit<=4){negative=std::min(negative+1,3);if(negative>=3)latched=false;}else negative=0;}
        return false;
    }
};
}
