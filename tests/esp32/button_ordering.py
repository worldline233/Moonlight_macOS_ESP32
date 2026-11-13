#!/usr/bin/env python3
"""Run production button dispatch/cancellation methods with Foundation + GCD.

--check validates call-site wiring on Linux/WSL. Default execution requires
macOS and runs real serial-queue tests with deliberately suspended dispatch.
"""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def method(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

def sources():
    pointer = (ROOT/'Limelight/Input/HIDSupport+Pointer.m').read_text()
    adapter = (ROOT/'Limelight/Input/HIDSupport.m').read_text()
    internal = (ROOT/'Limelight/Input/HIDSupport_Internal.h').read_text()
    return pointer, adapter, internal

def check_wiring():
    pointer, adapter, _ = sources()
    dispatch = method(pointer, '- (void)dispatchMouseButton:')
    release = method(pointer, '- (void)releaseAllPressedMouseButtons')
    assert pointer.count('[self dispatchMouseButton:') == 8, 'All five GCMouse, AppKit down/up, and synced clicks must use the dispatcher'
    assert pointer.count('LiSendMouseButtonEventCtx(') == 2, 'Only the dispatcher and ordered forced releases may submit native buttons'
    assert '@synchronized (self.mouseButtonDispatchLock)' in dispatch
    assert 'HIDDispatchInput(self, inputCtx' in release
    assert release.index('HIDDispatchInput(') < release.index('LiSendMouseButtonEventCtx(')
    assert '@synchronized (self.mouseButtonDispatchLock)' in method(adapter, '- (void)setShouldSendInputEvents:')
    assert '@synchronized (self.mouseButtonDispatchLock)' in method(adapter, '- (BOOL)handleESP32LocalControl:')
    assert 'dispatch_sync(self.inputQueue' in method(adapter, '- (void)setInputContext:')
    baseline = subprocess.check_output(['git', 'show', '0781c7f2842f2df2a891d9610a5b6f6b68a1fdc4:Limelight/Input/HIDSupport+Pointer.m'], cwd=ROOT).decode()
    assert method(pointer, '- (void)mouseMoved:') == method(baseline, '- (void)mouseMoved:')
    print('Button dispatch wiring: passed (all physical button paths; ordered release; original mouse motion retained)')

FIXTURE = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <cassert>
#include "ESP32MouseRouter.h"
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 0
typedef void *PML_CONNECTION_CONTEXT;
typedef struct { PML_CONNECTION_CONTEXT connectionContext; bool alive; } InputContext;
typedef InputContext *PML_INPUT_STREAM_CONTEXT;
typedef struct { int unused; } ControllerMenuGesture;
static void ControllerMenuGestureInterrupt(ControllerMenuGesture *, BOOL) {}
static char HIDInputQueueSpecificKey;
static NSMutableArray<NSString *> *wire;
static bool hostButtons[5];
@interface FakeBridge : NSObject
@property BOOL configured;
@property uint64_t epoch;
@property uint8_t selected;
@property NSUInteger usbReports;
- (BOOL)handleMouseButton:(int)button pressed:(BOOL)pressed;
- (uint8_t)releaseMouseButtons;
- (void)releaseAll;
@end
@implementation FakeBridge { Esp32MouseRouter _router; }
- (instancetype)init {
    if ((self=[super init])) { self.configured=YES; self.epoch=1; self.selected=2; }
    return self;
}
- (BOOL)handleMouseButton:(int)button pressed:(BOOL)pressed {
    if (!self.configured) return NO;
    static const unsigned map[]={99,0,2,1,3,4};
    auto decision=_router.handle(button>=1 && button<=5 ? map[button] : 99, pressed, self.epoch, self.selected);
    if (decision.sendUsb) self.usbReports++;
    return decision.consume;
}
- (uint8_t)releaseMouseButtons { return _router.cancel(); }
- (void)releaseAll { _router.cancel(); }
@end
@interface FakeTouchpad : NSObject
- (void)reset;
@end
@implementation FakeTouchpad
- (void)reset {}
@end
@interface FakeController : NSObject
@property int playerIndex;
@property ControllerMenuGesture menuGesture;
@end
@implementation FakeController
@end
@interface HIDSupport : NSObject
@property(nonatomic) BOOL shouldSendInputEvents;
@property(nonatomic) void *inputContext;
@property(nonatomic) dispatch_queue_t inputQueue;
@property(nonatomic,strong) NSObject *mouseButtonDispatchLock;
@property(nonatomic) uint64_t mouseButtonDispatchGeneration;
@property(nonatomic) uint32_t pressedMouseButtonsMask;
@property(nonatomic,strong) FakeBridge *esp32Input;
@property(nonatomic,strong) FakeTouchpad *precisionTouchpad;
@property(nonatomic,strong) FakeController *controller;
@property(nonatomic) NSInteger controllerDriver;
@property(nonatomic) BOOL gamepadMenuPressed;
- (void)dispatchMouseButton:(int)button pressed:(BOOL)pressed inputContext:(PML_INPUT_STREAM_CONTEXT)inputCtx beforeSend:(dispatch_block_t)beforeSend;
- (void)releaseAllPressedMouseButtons;
- (void)releaseAllModifierKeys;
- (void)rumbleLowFreqMotor:(unsigned short)low highFreqMotor:(unsigned short)high;
- (void)sendControllerEvent;
- (void)syncScrollTraceDiagnosticsPreferenceToInputContext;
- (void)recordMouseButtonDiagnosticsAction:(NSString *)action button:(int)button mask:(uint32_t)mask synthetic:(BOOL)synthetic;
@end
static PML_INPUT_STREAM_CONTEXT HIDInputContext(HIDSupport *s) { return (PML_INPUT_STREAM_CONTEXT)s.inputContext; }
static bool HIDValidateInputContext(PML_INPUT_STREAM_CONTEXT ctx, const char *) { return ctx && ctx->alive; }
static void LiSetThreadConnectionContext(PML_CONNECTION_CONTEXT) {}
static void LiSendMouseButtonEventCtx(PML_INPUT_STREAM_CONTEXT ctx, int action, int button) {
    assert(ctx && ctx->alive);
    assert(button>=1 && button<=5);
    hostButtons[button-1]=action==BUTTON_ACTION_PRESS;
    [wire addObject:[NSString stringWithFormat:@"%d:%d",button,action]];
}
static void LiSendMultiControllerEventCtx(PML_INPUT_STREAM_CONTEXT, int, ...) {}
'''

CHECKS = r'''
static HIDSupport *support(InputContext *ctx) {
    HIDSupport *s=[HIDSupport new];
    s.mouseButtonDispatchLock=[NSObject new];
    s.inputQueue=dispatch_queue_create("button-ordering-test",DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(s.inputQueue,&HIDInputQueueSpecificKey,(__bridge void *)s,NULL);
    s.esp32Input=[FakeBridge new];
    s.controller=[FakeController new];
    s.precisionTouchpad=[FakeTouchpad new];
    s.controllerDriver=1;
    s.inputContext=ctx;
    s.shouldSendInputEvents=YES;
    return s;
}
static void drain(HIDSupport *s) { dispatch_sync(s.inputQueue,^{}); }
static void click(HIDSupport *s,int button,BOOL down) {
    [s dispatchMouseButton:button pressed:down inputContext:HIDInputContext(s) beforeSend:nil];
}
static void resetWire() {
    wire=[NSMutableArray array];
    for (bool &button:hostButtons) button=false;
}
int main() { @autoreleasepool {
    // Pending native down must not appear after a forced release; a physical
    // up consumed by the real router must still leave the host released.
    resetWire(); InputContext c1={NULL,true}; HIDSupport *s=support(&c1);
    dispatch_suspend(s.inputQueue);
    click(s,BUTTON_LEFT,YES);
    [s releaseAllPressedMouseButtons];
    assert(wire.count==0);
    dispatch_resume(s.inputQueue); drain(s);
    assert(!hostButtons[0] && [wire isEqual:@[@"1:0"]]);
    click(s,BUTTON_LEFT,NO); drain(s);
    assert(!hostButtons[0]);

    // A queued normal up has already removed the button from routing state.
    // Invalidating that up would strand a previously delivered down.
    resetWire(); InputContext c2={NULL,true}; s=support(&c2);
    click(s,BUTTON_LEFT,YES); drain(s); assert(hostButtons[0]);
    dispatch_suspend(s.inputQueue);
    click(s,BUTTON_LEFT,NO);
    [s releaseAllPressedMouseButtons];
    dispatch_resume(s.inputQueue); drain(s);
    assert(!hostButtons[0] && [wire.lastObject isEqual:@"1:0"]);

    // Fresh press after cancellation must survive while the old press is dropped.
    resetWire(); InputContext c3={NULL,true}; s=support(&c3);
    dispatch_suspend(s.inputQueue);
    click(s,BUTTON_LEFT,YES); [s releaseAllPressedMouseButtons];
    click(s,BUTTON_LEFT,NO); click(s,BUTTON_LEFT,YES);
    dispatch_resume(s.inputQueue); drain(s);
    assert(([wire isEqual:@[@"1:0",@"1:1"]] && hostButtons[0]));
    click(s,BUTTON_LEFT,NO); drain(s); assert(!hostButtons[0]);

    // Capture loss is atomic with routing/submission; late callbacks cannot
    // append a new native down between cancellation and capture being disabled.
    resetWire(); InputContext c4={NULL,true}; s=support(&c4);
    dispatch_suspend(s.inputQueue);
    click(s,BUTTON_LEFT,YES); s.shouldSendInputEvents=NO;
    click(s,BUTTON_LEFT,YES);
    dispatch_resume(s.inputQueue); drain(s); assert(!hostButtons[0]);
    s.shouldSendInputEvents=YES; click(s,BUTTON_LEFT,NO);
    click(s,BUTTON_LEFT,YES); drain(s); assert(hostButtons[0]);
    click(s,BUTTON_LEFT,NO); drain(s); assert(!hostButtons[0]);

    // Keep coordinates before native clicks. Selected USB buttons still use
    // the bridge and do not gain an accidental second native send.
    resetWire(); InputContext c5={NULL,true}; s=support(&c5);
    [s dispatchMouseButton:BUTTON_LEFT pressed:YES inputContext:&c5 beforeSend:^{[wire addObject:@"position"];}];
    drain(s); assert(([wire isEqual:@[@"position",@"1:1"]]));
    click(s,BUTTON_LEFT,NO); drain(s); resetWire();
    [s dispatchMouseButton:BUTTON_RIGHT pressed:YES inputContext:&c5 beforeSend:^{[wire addObject:@"usb-position"];}];
    drain(s); assert(s.esp32Input.usbReports==1 && [wire isEqual:@[@"usb-position"]]);
    click(s,BUTTON_RIGHT,NO); drain(s); assert(s.esp32Input.usbReports==2);

    // Offline selected-button fallback uses the same ordered native releases.
    resetWire(); InputContext c6={NULL,true}; s=support(&c6); s.esp32Input.epoch=0;
    dispatch_suspend(s.inputQueue);
    click(s,BUTTON_RIGHT,YES); [s releaseAllPressedMouseButtons];
    dispatch_resume(s.inputQueue); drain(s); assert(!hostButtons[2]);

    // Concurrent callback/focus producers exercise the production routing lock.
    resetWire(); InputContext c7={NULL,true}; s=support(&c7);
    dispatch_group_t producers=dispatch_group_create();
    dispatch_group_async(producers,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        for(int i=0;i<300;i++){click(s,BUTTON_LEFT,YES);click(s,BUTTON_LEFT,NO);}
    });
    for(int i=0;i<300;i++) [s releaseAllPressedMouseButtons];
    dispatch_group_wait(producers,DISPATCH_TIME_FOREVER);
    [s releaseAllPressedMouseButtons]; drain(s); assert(!hostButtons[0]);

    // Replacing a context drains its pending release before the caller frees it.
    resetWire(); InputContext c8={NULL,true}, replacement={NULL,true}; s=support(&c8);
    click(s,BUTTON_LEFT,YES); drain(s); assert(hostButtons[0]);
    s.inputContext=&replacement; c8.alive=false;
    assert(!hostButtons[0]);
    click(s,BUTTON_LEFT,NO);
    click(s,BUTTON_LEFT,YES); drain(s); assert(hostButtons[0]);
    s.shouldSendInputEvents=NO;
    s.inputContext=NULL; replacement.alive=false;
    assert(!hostButtons[0]);
    // The MFI/GC path also needs forced release when ESP32 is disabled.
    resetWire(); InputContext c9={NULL,true}; s=support(&c9);
    s.esp32Input.configured=NO;
    click(s,BUTTON_LEFT,YES); drain(s); assert(hostButtons[0]);
    s.shouldSendInputEvents=NO; drain(s); assert(!hostButtons[0]);
    s.inputContext=NULL; c9.alive=false;
    puts("PASS: production button queue cancellation, release, recapture, USB/native routing, concurrent callbacks and context drain");
} }
'''

def program():
    pointer, adapter, internal = sources()
    helpers = '\n'.join(method(internal, name) for name in ['static inline uint32_t HIDMouseButtonBitForButton', 'static inline void HIDDispatchInput'])
    implementation = '\n'.join([
        '@implementation HIDSupport',
        '@synthesize shouldSendInputEvents = _shouldSendInputEvents;',
        '@synthesize inputContext = _inputContext;',
        method(adapter, '- (BOOL)shouldSendInputEvents'),
        method(adapter, '- (void)setShouldSendInputEvents:'),
        method(adapter, '- (void)setInputContext:'),
        method(pointer, '- (void)dispatchMouseButton:'),
        method(pointer, '- (void)releaseAllPressedMouseButtons'),
        '- (void)releaseAllModifierKeys {}',
        '- (void)rumbleLowFreqMotor:(unsigned short)low highFreqMotor:(unsigned short)high {}',
        '- (void)sendControllerEvent {}',
        '- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {}',
        '- (void)recordMouseButtonDiagnosticsAction:(NSString *)action button:(int)button mask:(uint32_t)mask synthetic:(BOOL)synthetic {}',
        '@end',
    ])
    return FIXTURE + helpers + implementation + CHECKS

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--emit', type=Path)
    args = parser.parse_args()
    check_wiring()
    if args.emit:
        args.emit.write_text(program())
        return
    if args.check:
        return
    if platform.system() != 'Darwin':
        raise SystemExit('Native queue regression requires macOS Foundation / GCD. Use --check for source wiring only.')
    with tempfile.TemporaryDirectory(prefix='mouse-button-order-') as directory:
        directory = Path(directory)
        source = directory/'test.mm'
        source.write_text(program())
        binary = directory/'test'
        subprocess.run(['xcrun','clang++','-std=c++14','-fobjc-arc','-fblocks','-framework','Foundation',
                        '-I',str(ROOT/'Limelight/Input/ESP32'),str(source),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=20)

if __name__ == '__main__':
    main()
