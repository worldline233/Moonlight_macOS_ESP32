#include "fivedetector.h"
#include <cassert>
int main(){
    FiveVision::Edge single(1);assert(single.update(5,1));assert(!single.update(5,12));
    for(int i=0;i<3;++i)assert(!single.update(0,23+i*11));
    assert(single.update(5,56));
    FiveVision::Edge slow(2,1000);assert(!slow.update(5,1));assert(slow.update(5,1001));
    uint64_t t=1;FiveVision::Edge edge;
    assert(!edge.update(5,t+=30));assert(edge.update(5,t+=30));
    for(int i=0;i<200;++i)assert(!edge.update(5,t+=30));
    // Uncertain images never rearm an active five.
    for(int i=0;i<20;++i){assert(!edge.update(-1,t+=30));assert(!edge.update(5,t+=30));}
    // Every confirmed quantity 0..4 rearms after three consecutive samples.
    for(int d=0;d<=4;++d){
        for(int i=0;i<3;++i)assert(!edge.update(d,t+=30));
        assert(!edge.isLatched());assert(!edge.update(5,t+=30));assert(edge.update(5,t+=30));
    }
    // Two negatives, uncertainty, then another negative are not three consecutive.
    assert(!edge.update(2,t+=30));assert(!edge.update(2,t+=30));
    assert(!edge.update(-1,t+=30));assert(!edge.update(2,t+=30));assert(edge.isLatched());
    for(int i=0;i<3;++i)assert(!edge.update(0,t+=30));
    assert(!edge.update(5,t+=30));assert(!edge.update(5,t+=200));assert(edge.update(5,t+=30));
    // The aggregate quantity stays five when the icon moves to another slot.
    for(int slot=0;slot<3;++slot)for(int i=0;i<3;++i)assert(!edge.update(5,t+=30));
    // A sampling gap does not by itself release the latch.
    assert(!edge.update(5,t+=1000));assert(!edge.update(5,t+=30));
}
