#import "ESP32InputBridge.h"
#include <cassert>
#include <cstring>
#include <unistd.h>
#include "ESP32PixelBufferReader.h"
#include "fivedetector.h"

static void settle(void) { usleep(150000); }
static void waitReady(ESP32InputBridge *bridge) {
    for (int i = 0; i < 250 && !bridge.ready; ++i) usleep(20000);
    assert(bridge.ready);
}
struct EncodedPixelFixture { CMSampleBufferRef sample=nullptr;CVPixelBufferRef frame=nullptr; };
static void pixelFixtureEncoded(void *ref,void *,OSStatus status,VTEncodeInfoFlags,CMSampleBufferRef sample) {
    auto *fixture=static_cast<EncodedPixelFixture*>(ref);
    if(status==noErr && sample && !fixture->sample)fixture->sample=(CMSampleBufferRef)CFRetain(sample);
}
static void pixelFixtureDecoded(void *ref,void *,OSStatus status,VTDecodeInfoFlags,CVImageBufferRef image,CMTime,CMTime) {
    auto *fixture=static_cast<EncodedPixelFixture*>(ref);
    if(status==noErr && image && !fixture->frame)fixture->frame=CVPixelBufferRetain(image);
}
static CVPixelBufferRef decodeCompressedFixture(CVPixelBufferRef source,OSStatus& status,bool wantCompressed=true) {
    EncodedPixelFixture fixture;VTCompressionSessionRef encoder=nullptr;
    status=VTCompressionSessionCreate(kCFAllocatorDefault,2560,1440,kCMVideoCodecType_H264,nullptr,nullptr,nullptr,pixelFixtureEncoded,&fixture,&encoder);
    if(status!=noErr)return nullptr;
    VTSessionSetProperty(encoder,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue);
    int rate=80000000;CFNumberRef number=CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&rate);
    VTSessionSetProperty(encoder,kVTCompressionPropertyKey_AverageBitRate,number);CFRelease(number);
    status=VTCompressionSessionEncodeFrame(encoder,source,CMTimeMake(0,60),CMTimeMake(1,60),nullptr,nullptr,nullptr);
    if(status==noErr)status=VTCompressionSessionCompleteFrames(encoder,kCMTimeInvalid);
    VTCompressionSessionInvalidate(encoder);CFRelease(encoder);
    if(!fixture.sample)return nullptr;
    for(int requested=1;requested>=0 && !fixture.frame;--requested) {
        NSMutableDictionary *attributes=[@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES} mutableCopy];
        if(requested || !wantCompressed)attributes[(id)kCVPixelBufferPixelFormatTypeKey]=@(wantCompressed ? (OSType)0x26387630 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        VTDecompressionSessionRef decoder=nullptr;
        VTDecompressionOutputCallbackRecord callback={pixelFixtureDecoded,&fixture};
        status=VTDecompressionSessionCreate(kCFAllocatorDefault,CMSampleBufferGetFormatDescription(fixture.sample),nullptr,(__bridge CFDictionaryRef)attributes,&callback,&decoder);
        if(status!=noErr)continue;
        status=VTDecompressionSessionDecodeFrame(decoder,fixture.sample,0,nullptr,nullptr);
        VTDecompressionSessionWaitForAsynchronousFrames(decoder);
        VTDecompressionSessionInvalidate(decoder);CFRelease(decoder);
        if(wantCompressed && fixture.frame && !ESP32PixelBufferReader::compressed420(CVPixelBufferGetPixelFormatType(fixture.frame))) {
            NSLog(@"Compression fixture decode delivered linear format=0x%08x",(unsigned)CVPixelBufferGetPixelFormatType(fixture.frame));
            CVPixelBufferRelease(fixture.frame);fixture.frame=nullptr;
        }
    }
    CFRelease(fixture.sample);
    if(fixture.frame)status=noErr;
    return fixture.frame;
}
static CVPixelBufferRef quantityFixture(int digit,int slot) {
    CVPixelBufferRef frame=nullptr;
    assert(CVPixelBufferCreate(kCFAllocatorDefault,2560,1440,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nullptr,&frame)==kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(frame,0)==kCVReturnSuccess);
    auto *base=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(frame,0);size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(frame,0);
    memset(base,43,pitch*1440);memset(CVPixelBufferGetBaseAddressOfPlane(frame,1),128,CVPixelBufferGetBytesPerRowOfPlane(frame,1)*720);
    if(digit){
        for(int y=0;y<43;++y)memcpy(base+(1226+y)*pitch+702+58*slot,FiveVision::Icon+48*y,48);
        const uint8_t (*templates[])[88]={FiveVision::Digits1,FiveVision::Digits2,FiveVision::Digits3,FiveVision::Digits4,FiveVision::Digits5};
        for(int y=0;y<11;++y)memcpy(base+(1270+y)*pitch+726+58*slot,templates[digit-1][3]+8*y,8);
    }
    FiveVision::Patch patch;assert(FiveVision::extract(2560,1440,[&](int x,int y){return int(base[y*pitch+x]);},patch));
    auto result=FiveVision::detect(patch);assert(result.digit==digit);if(digit)assert(result.slot==slot);
    CVPixelBufferUnlockBaseAddress(frame,0);return frame;
}
static void testThreeSlots(ESP32InputBridge *bridge){
    for(int slot=0;slot<3;++slot)for(int digit=0;digit<=5;++digit){
        CVPixelBufferRef frame=quantityFixture(digit,slot);CVPixelBufferRelease(frame);
    }
    // Preserve the active five latch across unknown pixels and slot changes.
    CVPixelBufferRef unknown=nullptr;
    assert(CVPixelBufferCreate(kCFAllocatorDefault,2560,1440,kCVPixelFormatType_32BGRA,nullptr,&unknown)==kCVReturnSuccess);
    [bridge observeVideoFrame:unknown active:YES];CVPixelBufferRelease(unknown);usleep(80000);
    for(int slot=0;slot<3;++slot){
        CVPixelBufferRef frame=quantityFixture(5,slot);
        for(int i=0;i<3;++i){[bridge observeVideoFrame:frame active:YES];usleep(80000);}
        CVPixelBufferRelease(frame);
    }
    NSLog(@"THREE_SLOT_FIXTURE_PASSED states=18 moving_five_macros=1");
}
static void testPixelReader(ESP32InputBridge *bridge) {
    assert(ESP32PixelBufferReader::compressed420(0x26387630));
    assert(ESP32PixelBufferReader::compressed420(0x26386630));
    assert(!ESP32PixelBufferReader::compressed420(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
    CVPixelBufferRef linear=nullptr;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    assert(CVPixelBufferCreate(kCFAllocatorDefault,2560,1440,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&linear)==kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(linear,0)==kCVReturnSuccess);
    auto *y=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(linear,0);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(linear,0);
    memset(y,16,stride*1440);
    memset(CVPixelBufferGetBaseAddressOfPlane(linear,1),128,CVPixelBufferGetBytesPerRowOfPlane(linear,1)*720);
    for(int row=0;row<43;++row)memcpy(y+(1226+row)*stride+818,FiveVision::Icon+row*48,48);
    for(int row=0;row<11;++row)memcpy(y+(1270+row)*stride+842,FiveVision::Digits5[3]+row*8,8);
    CVPixelBufferUnlockBaseAddress(linear,0);
    ESP32PixelBufferReader reader;OSStatus status;
    CVPixelBufferRef converted=reader.convert(linear,status);assert(status==noErr && converted);
    assert(CVPixelBufferLockBaseAddress(converted,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
    FiveVision::Patch patch;auto *base=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(converted,0);size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(converted,0);
    assert(FiveVision::extract(2560,1440,[&](int x,int y){return int(base[y*pitch+x]);},patch));
    CVPixelBufferUnlockBaseAddress(converted,kCVPixelBufferLock_ReadOnly);
    assert(FiveVision::detect(patch).digit==5);
    // Exercise the actual compressed source path when this Mac exposes allocation.
    CVPixelBufferRef compressed=nullptr;VTPixelTransferSessionRef encoder=nullptr;
    CVReturn allocation=CVPixelBufferCreate(kCFAllocatorDefault,2560,1440,(OSType)0x26387630,(__bridge CFDictionaryRef)attrs,&compressed);
    OSStatus compression=allocation;
    if(compressed && VTPixelTransferSessionCreate(kCFAllocatorDefault,&encoder)==noErr)compression=VTPixelTransferSessionTransferImage(encoder,linear,compressed);
    if(!compressed || compression!=noErr) {
        if(compressed){CVPixelBufferRelease(compressed);compressed=nullptr;}
        compressed=decodeCompressedFixture(linear,compression);
    }
    if(compressed && compression==noErr) {
        auto *decompressed=reader.convert(compressed,status);assert(status==noErr && decompressed);
        assert(CVPixelBufferLockBaseAddress(decompressed,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
        base=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(decompressed,0);pitch=CVPixelBufferGetBytesPerRowOfPlane(decompressed,0);
        assert(FiveVision::extract(2560,1440,[&](int x,int y){return int(base[y*pitch+x]);},patch));
        CVPixelBufferUnlockBaseAddress(decompressed,kCVPixelBufferLock_ReadOnly);
        assert(FiveVision::detect(patch).digit==5);
        NSLog(@"COMPRESSED_FIXTURE_PASSED source=0x26387630");
        // Compressed conversion is optional fallback; the production decoder now explicitly requests linear output.
    } else NSLog(@"COMPRESSED_FIXTURE_UNAVAILABLE allocation=%d transfer=%d; linear conversion and recognition passed",(int)allocation,(int)compression);
    CVPixelBufferRef decodedLinear=decodeCompressedFixture(linear,status,false);
    assert(status==noErr && decodedLinear);
    assert(CVPixelBufferGetPixelFormatType(decodedLinear)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    assert(CVPixelBufferLockBaseAddress(decodedLinear,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
    base=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(decodedLinear,0);pitch=CVPixelBufferGetBytesPerRowOfPlane(decodedLinear,0);
    assert(FiveVision::extract(2560,1440,[&](int x,int y){return int(base[y*pitch+x]);},patch));
    CVPixelBufferUnlockBaseAddress(decodedLinear,kCVPixelBufferLock_ReadOnly);
    assert(FiveVision::detect(patch).digit==5);
    for(int i=0;i<6;++i){[bridge observeVideoFrame:decodedLinear active:YES];usleep(60000);}
    CVPixelBufferRelease(decodedLinear);
    NSLog(@"LINEAR_DECODE_FIXTURE_PASSED output=420v digit=5");
    testThreeSlots(bridge);
    if(encoder){VTPixelTransferSessionInvalidate(encoder);CFRelease(encoder);}
    if(compressed)CVPixelBufferRelease(compressed);CVPixelBufferRelease(linear);
}
static void observeTestFrame(ESP32InputBridge *bridge, OSType format, size_t w, size_t h, BOOL active) {
    CVPixelBufferRef frame=nullptr;
    assert(CVPixelBufferCreate(kCFAllocatorDefault,w,h,format,nullptr,&frame)==kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(frame,0)==kCVReturnSuccess);
    if(CVPixelBufferIsPlanar(frame)) {
        for(size_t i=0;i<CVPixelBufferGetPlaneCount(frame);++i)
            memset(CVPixelBufferGetBaseAddressOfPlane(frame,i),0,CVPixelBufferGetBytesPerRowOfPlane(frame,i)*CVPixelBufferGetHeightOfPlane(frame,i));
    } else memset(CVPixelBufferGetBaseAddress(frame),0,CVPixelBufferGetBytesPerRow(frame)*h);
    CVPixelBufferUnlockBaseAddress(frame,0);
    [bridge observeVideoFrame:frame active:active];CVPixelBufferRelease(frame);settle();
}
int main(int argc, const char **argv) {
    assert(argc == 3);
    @autoreleasepool {
        NSString *host = [@"esp32-loopback-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *store = [@"esp32.input.host." stringByAppendingString:host];
        NSMutableDictionary *settings = [[ESP32InputBridge settingsForHost:host] mutableCopy];
        settings[@"enabled"] = @YES;
        settings[@"address"] = @"127.0.0.1";
        settings[@"port"] = @([[NSString stringWithUTF8String:argv[1]] intValue]);
        settings[@"access_key"] = @"123456"; // synthetic loopback key only
        settings[@"excluded_keys"] = @"KeyQ";
        settings[@"shortcut_macro"] = @8;
        settings[@"macro_repeats"] = @5;
        settings[@"macro_key"] = @"g";
        if(strcmp(argv[2],"vision")==0)settings[@"vision_enabled"]=@YES;
        assert([ESP32InputBridge saveSettings:settings forHost:host]);
        ESP32InputBridge *bridge = [[ESP32InputBridge alloc] initWithHostUUID:host];
        if(strcmp(argv[2],"vision")==0) {
            waitReady(bridge);
            [bridge noteVideoPath:@"test_native" captureActive:YES];
            observeTestFrame(bridge,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,2560,1440,YES);
            observeTestFrame(bridge,kCVPixelFormatType_32BGRA,1920,1080,YES);
            observeTestFrame(bridge,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,1920,1200,YES);
            [bridge togglePaused];
            observeTestFrame(bridge,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,2560,1440,YES);
            [bridge togglePaused];
            observeTestFrame(bridge,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,2560,1440,NO);
            [bridge logDiagnostics];
            // Restore active capture after the diagnostics gate tests.
            testPixelReader(bridge);
        } else if (strcmp(argv[2], "macro") == 0 || strcmp(argv[2], "legacy_macro") == 0) {
            waitReady(bridge);
            assert([bridge handleMacKeyCode:13 pressed:YES]); // W held.
            settle();
            [bridge triggerExclusiveMacro];
            settle();
            assert([bridge handleMacKeyCode:13 pressed:NO]);
            assert([bridge handleMacKeyCode:0 pressed:YES]); // Latest A.
            assert([bridge handleMouseButton:1 pressed:YES]);
            assert([bridge handleMouseButton:1 pressed:NO]);
            settle(); // No macro completion notification from the fake ESP.
            [bridge releaseAll]; // Explicit stop must send the cancel command.
            settle();
        } else if (strcmp(argv[2], "lifecycle") == 0) {
            // Keep every old bridge alive, as AppKit/input callbacks can do.
            // The firmware-like server admits only one control connection.
            NSMutableArray<ESP32InputBridge *> *retained = [NSMutableArray array];
            for (int cycle = 0; cycle < 3; ++cycle) {
                waitReady(bridge);
                assert([bridge handleMacKeyCode:0 pressed:YES]);
                assert([bridge handleMouseButton:1 pressed:YES]);
                settle();
                [retained addObject:bridge];
                [bridge stop];
                [bridge stop]; // Teardown callbacks can overlap.
                assert(!bridge.ready);
                if (cycle != 2) bridge = [[ESP32InputBridge alloc] initWithHostUUID:host];
            }
            usleep(500000);
            for (ESP32InputBridge *old in retained) assert(!old.ready);
        } else if (strcmp(argv[2], "bad") == 0) {
            sleep(1);
            assert(!bridge.ready && bridge.keyboardExclusive);
            assert([bridge handleMacKeyCode:0 pressed:YES]);
        } else {
            waitReady(bridge);
            assert([bridge handleMacKeyCode:0 pressed:YES]); // A
            [bridge handlePhysicalModifierMask:(1u << 2) | (1u << 3)]; // both controls
            assert([bridge handleMouseButton:1 pressed:YES]);
            settle();
            [bridge releaseAll];
            settle();
            [bridge handleMacKeyCode:0 pressed:NO];
            [bridge handleMouseButton:1 pressed:NO];
            [bridge handlePhysicalModifierMask:0];
            [bridge handleMacKeyCode:12 pressed:YES]; // excluded Q
            [bridge handleMacKeyCode:12 pressed:NO];
            settle();
            [bridge togglePaused];
            assert([bridge handleMacKeyCode:11 pressed:YES]); // B, suppressed while paused
            settle();
            [bridge togglePaused];
            [bridge handleMacKeyCode:11 pressed:YES]; // still held, no replay
            settle();
            [bridge handleMacKeyCode:11 pressed:NO];
            [bridge handleMacKeyCode:11 pressed:YES];
            settle();
            [bridge handleMacKeyCode:11 pressed:NO];
            [bridge handleMacKeyCode:0 pressed:YES]; // hold A across reconnect
            settle();
            [bridge reconnect];
            waitReady(bridge);
            [bridge handleMacKeyCode:0 pressed:YES]; // must remain suppressed
            settle();
            [bridge handleMacKeyCode:0 pressed:NO];
            [bridge handleMacKeyCode:8 pressed:YES]; // fresh C on second connection
            settle();
            [bridge handleMacKeyCode:8 pressed:NO];
            settle();
        }
        [bridge stop];
        usleep(350000);
        assert(!bridge.ready);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:store];
    }
    return 0;
}
