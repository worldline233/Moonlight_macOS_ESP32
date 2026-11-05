#import "ESP32InputBridge.h"
#include <cassert>

int main() {
    @autoreleasepool {
        NSString *host = [@"esp32-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSMutableDictionary *settings = [[ESP32InputBridge settingsForHost:host] mutableCopy];
        assert(![settings[@"enabled"] boolValue]);
        settings[@"enabled"] = @YES;
        settings[@"address"] = @"127.0.0.1";
        settings[@"access_key"] = @"123456";
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
