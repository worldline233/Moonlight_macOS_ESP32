#import "ESP32InputBridge.h"
#include <cassert>

int main() {
    @autoreleasepool {
        NSString *host = [@"esp32-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSMutableDictionary *settings = [[ESP32InputBridge settingsForHost:host] mutableCopy];
        assert(![settings[@"enabled"] boolValue]);
        settings[@"enabled"] = @YES;
        assert([settings[@"macro_repeats"] isEqual:@3]);
        assert([settings[@"macro_hold_ms"] isEqual:@2] && [settings[@"macro_interval_ms"] isEqual:@2]);
        settings[@"address"] = @"127.0.0.1";
        settings[@"access_key"] = @"123456";
        assert([ESP32InputBridge validationErrorForSettings:settings] == nil);
        for (NSString *field in @[@"macro_repeats", @"macro_hold_ms", @"macro_interval_ms", @"shortcut_macro"]) {
            id original = settings[field];
            settings[field] = @3.5;
            assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
            settings[field] = original;
        }
        for (NSNumber *reserved in @[@9, @10, @11]) {
            settings[@"shortcut_macro"] = reserved;
            assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        }
        settings[@"shortcut_macro"] = @8;
        assert([settings[@"macro_key"] isEqual:@"KeyE"]);
        for (id invalid in @[@"ControlLeft", @"F13", @"typo", @42, @""]) {
            settings[@"macro_key"] = invalid;
            assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        }
        for (NSString *valid in @[@"E", @"g", @"1", @"F8", @"Space", @"Enter"]) {
            settings[@"macro_key"] = valid;
            assert([ESP32InputBridge validationErrorForSettings:settings] == nil);
        }
        settings[@"macro_key"] = @"KeyE";
        settings[@"shortcut_macro"] = @8;
        assert([ESP32InputBridge validationErrorForSettings:settings] == nil);
        settings[@"address"] = @"ws://user:pass@127.0.0.1";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"address"] = @"ws://127.0.0.1:1234";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"address"] = @"ws://127.0.0.1/other";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"address"] = @"ws://[::1]/ws";
        assert([ESP32InputBridge validationErrorForSettings:settings] == nil);
        settings[@"access_key"] = @"12345";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"access_key"] = @"１２３４５６";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"access_key"] = @"123456";
        settings[@"excluded_keys"] = @"MetaLeft, KeyQ";
        assert([ESP32InputBridge validationErrorForSettings:settings] == nil);
        settings[@"excluded_keys"] = @"typo";
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        settings[@"excluded_keys"] = @"";
        settings[@"keyboard_enabled"] = @NO;
        settings[@"mouse_enabled"] = @NO;
        assert([ESP32InputBridge validationErrorForSettings:settings] != nil);
        assert(![ESP32InputBridge saveSettings:settings forHost:host]);
        assert(![ESP32InputBridge saveSettings:settings forHost:@"__global__"]);

        // Invalid configuration still owns the keyboard: it must never fall
        // back to Sunshine while the user expects USB-only input.
        settings[@"keyboard_enabled"] = @YES;
        settings[@"access_key"] = @"invalid";
        NSString *store = [@"esp32.input.host." stringByAppendingString:host];
        [NSUserDefaults.standardUserDefaults setObject:settings forKey:store];
        ESP32InputBridge *bridge = [[ESP32InputBridge alloc] initWithHostUUID:host];
        assert(bridge.keyboardExclusive && !bridge.ready && !bridge.configured);
        assert([bridge isExclusiveMacroKeyCode:100]); // F8 physical position.
        assert(![bridge isExclusiveMacroKeyCode:101]);
        [bridge triggerExclusiveMacro]; // Offline must not activate an input route.
        assert([bridge handleMacKeyCode:0 pressed:YES]);
        assert([bridge handleMacKeyCode:999 pressed:YES]);
        assert(![bridge handleMouseButton:1 pressed:YES]);
        [bridge togglePaused];
        assert(bridge.paused && [bridge handleMacKeyCode:0 pressed:NO]);
        [bridge stop];
        [bridge stop];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:store];

        // Disabled and other-host defaults never consume input or connect.
        ESP32InputBridge *other = [[ESP32InputBridge alloc] initWithHostUUID:NSUUID.UUID.UUIDString];
        assert(!other.enabled && !other.keyboardExclusive && !other.ready);
        assert(![other handleMacKeyCode:0 pressed:YES]);
        assert(![other handleMouseButton:1 pressed:YES]);
        [other stop];
        NSLog(@"ESP32 native configuration and offline routing: passed");
    }
    return 0;
}
