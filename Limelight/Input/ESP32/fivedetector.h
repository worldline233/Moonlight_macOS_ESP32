#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include "fivetemplates.h"
namespace FiveVision {
constexpr int Size=84;
using Patch=std::array<uint8_t,Size*Size>;
// Pixel-centre coordinates in the decoded source, independent of client window size.
template<class Pixel> bool extract(int w,int h,Pixel pixel,Patch& out) {
    if(w<1280 || h<720 || w>7680 || h>4320 || std::abs(double(w)/h-16.0/9)>0.02) return false;
    for(int y=0;y<Size;++y) for(int x=0;x<Size;++x) {
        double sx=(800+x+0.5)*w/2560.0-0.5,sy=(1210+y+0.5)*h/1440.0-0.5;
        int ix=int(std::floor(sx)),iy=int(std::floor(sy));double fx=sx-ix,fy=sy-iy;
        if(ix<0 || iy<0 || ix+1>=w || iy+1>=h)return false;
        double v=(1-fy)*((1-fx)*pixel(ix,iy)+fx*pixel(ix+1,iy))+fy*((1-fx)*pixel(ix,iy+1)+fx*pixel(ix+1,iy+1));
        out[y*Size+x]=uint8_t(std::max(0.0,std::min(255.0,std::floor(v+0.5))));
    }
    return true;
}
inline double correlation(const uint8_t* a,int stride,const uint8_t* b,int w,int h) {
    double sa=0,sb=0,saa=0,sbb=0,sab=0;int n=w*h;
    for(int y=0;y<h;++y) for(int x=0;x<w;++x){double av=a[y*stride+x],bv=b[y*w+x];sa+=av;sb+=bv;saa+=av*av;sbb+=bv*bv;sab+=av*bv;}
    double den=(saa-sa*sa/n)*(sbb-sb*sb/n);
    return den>1 ? (sab-sa*sb/n)/std::sqrt(den) : 0;
}
struct Result {int digit=0;double icon=0,five=0,three=0;};
inline Result detect(const Patch& p) {
    Result r;int bx=18,by=16;
    for(int y=12;y<=20;++y)for(int x=14;x<=22;++x){double s=correlation(p.data()+y*Size+x,Size,Icon,48,43);if(s>r.icon){r.icon=s;bx=x;by=y;}}
    if(r.icon<0.80) {r.digit=r.icon<0.55 ? -1:0;return r;}
    // Resolution-matched antialiasing samples; compete with the observed 3.
    for(int bank=0;bank<BankCount;++bank) {
        r.five=std::max(r.five,correlation(p.data()+(by+44)*Size+bx+24,Size,Digits5[bank],8,11));
        r.three=std::max(r.three,correlation(p.data()+(by+44)*Size+bx+24,Size,Digits3[bank],8,11));
    }
    if(r.five>=0.78 && r.five-r.three>=0.065)r.digit=5;
    else if(r.three>=0.78 && r.three-r.five>=0.065)r.digit=3;
    return r;
}
class Edge {
    bool latched=false;int positive=0,negative=0;uint64_t last=0;
public:
    void reset(){latched=false;positive=negative=0;last=0;}
    bool update(int digit,uint64_t ms) {
        if(last && (ms<=last || ms-last>150)){positive=negative=0;}last=ms;
        if(digit==5){negative=0;if(++positive>=2 && !latched){latched=true;return true;}}
        else {positive=0;if(digit==3 || digit==-1){if(++negative>=3)latched=false;}else negative=0;}
        return false;
    }
};
}
