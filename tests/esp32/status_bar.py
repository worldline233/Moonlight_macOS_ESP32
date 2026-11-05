"""Check production HUD ordering and exercise its AppKit methods on macOS."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile
from button_ordering import method
ROOT = Path(__file__).resolve().parents[2]

def check():
    source = (ROOT/'Limelight/macOS/ViewControllers/StreamViewController.m').read_text().split('@implementation StreamViewController\n',1)[1]
    assert 'setupESP32StatusBar' not in method(source, '- (void)prepareForStreaming')
    started = method(source, '- (void)connectionStarted')
    assert started.index('[self setupESP32StatusBar];') < started.index('if ([SettingsClass showPerformanceOverlayFor:')
    assert 'removeESP32StatusBar' in method(source, '- (void)tearDownStreamLifecycleObserversAndTimers')
    print('ESP32 HUD lifecycle: passed (after renderer, independent of performance toggle, teardown)')

FIXTURE = r'''
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <cassert>
@interface Bridge : NSObject
@property BOOL enabled;
- (NSDictionary *)monitorSnapshot;
@end
@implementation Bridge
- (NSDictionary *)monitorSnapshot { return @{ @"ready": @YES, @"keyboard": @YES, @"mouse": @YES }; }
@end
@interface HID : NSObject
@property(strong) Bridge *esp32Input;
@property BOOL shouldSendInputEvents;
@end
@implementation HID
@end
__BAR_CLASS__
@interface Harness : NSObject
@property(strong) NSView *view;
@property(strong) HID *hidSupport;
@property(strong) NSView *overlayContainer;
@property(strong) NSTimer *esp32StatusTimer;
@property(strong) NSView *esp32StatusContainer;
@property(strong) NSTextField *esp32StatusLabel;
- (void)setupESP32StatusBar;
- (void)updateESP32StatusBar;
- (void)removeESP32StatusBar;
@end
@implementation Harness
__METHODS__
@end
int main() {
 @autoreleasepool {
    [NSApplication sharedApplication];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = @"esp32.showStatusBar";
    id saved = [defaults objectForKey:key];
    [defaults setBool:YES forKey:key];
    Harness *owner = [Harness new];
    owner.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,1000,700)];
    owner.hidSupport = [HID new];
    owner.hidSupport.esp32Input = [Bridge new];
    owner.hidSupport.esp32Input.enabled = YES;
    owner.hidSupport.shouldSendInputEvents = YES;
    NSView *video = [[NSView alloc] initWithFrame:owner.view.bounds];
    [owner.view addSubview:video];
    [owner setupESP32StatusBar];
    NSView *bar = owner.esp32StatusContainer;
    assert(bar && !bar.hidden && owner.view.subviews.lastObject == bar);
    assert(NSWidth(bar.frame) > 100 && NSHeight(bar.frame) == 26);
    assert(NSMidX(bar.frame) == NSMidX(owner.view.bounds));
    assert(NSMaxY(bar.frame) == 680);
    assert([bar hitTest:NSMakePoint(10,10)] == nil);
    assert([owner.esp32StatusLabel.stringValue containsString:@"Connected"]);
    // Replacing the renderer must not bury the independent HUD.
    [owner.view addSubview:video positioned:NSWindowAbove relativeTo:nil];
    [owner updateESP32StatusBar];
    assert(owner.view.subviews.lastObject == bar);
    owner.overlayContainer = [[NSView alloc] initWithFrame:NSMakeRect(0,600,600,60)];
    [owner.view addSubview:owner.overlayContainer];
    [owner updateESP32StatusBar];
    assert(NSMaxY(bar.frame) == 614);
    owner.overlayContainer.hidden = YES;
    [owner updateESP32StatusBar];
    assert(NSMaxY(bar.frame) == 680);
    [defaults setBool:NO forKey:key]; [owner updateESP32StatusBar]; assert(bar.hidden);
    [defaults setBool:YES forKey:key]; [owner updateESP32StatusBar]; assert(!bar.hidden);
    [owner removeESP32StatusBar];
    assert(!bar.superview && !owner.esp32StatusTimer);
    if (saved) [defaults setObject:saved forKey:key]; else [defaults removeObjectForKey:key];
    puts("ESP32 HUD AppKit: passed (standalone, video replacement, stacking, toggle, click-through, cleanup)");
 }
}
'''

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--check',action='store_true'); args=parser.parse_args()
    check()
    if args.check: return
    assert platform.system() == 'Darwin', 'AppKit test requires macOS'
    source=(ROOT/'Limelight/macOS/ViewControllers/StreamViewController+Diagnostics.m').read_text()
    start=source.index('@interface MLESP32StatusView')
    end=source.index('// Host-selected dynamic HDR',start)
    methods='\n'.join(method(source,s) for s in ('- (void)removeESP32StatusBar', '- (void)setupESP32StatusBar', '- (void)updateESP32StatusBar'))
    fixture=FIXTURE.replace('__BAR_CLASS__',source[start:end]).replace('__METHODS__',methods)
    with tempfile.TemporaryDirectory(prefix='esp32-hud-') as tmp:
        path=Path(tmp)/'hud.m'; binary=Path(tmp)/'hud'; path.write_text(fixture)
        subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','AppKit','-framework','QuartzCore',str(path),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=15)
if __name__ == '__main__': main()
