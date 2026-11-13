#import "ESP32InputBridge.h"
#include <cassert>
#include <cstring>
#include <unistd.h>

static void settle(void) { usleep(150000); }
static void waitReady(ESP32InputBridge *bridge) {
    for (int i = 0; i < 250 && !bridge.ready; ++i) usleep(20000);
    assert(bridge.ready);
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
        assert([ESP32InputBridge saveSettings:settings forHost:host]);
        ESP32InputBridge *bridge = [[ESP32InputBridge alloc] initWithHostUUID:host];
        if (strcmp(argv[2], "macro") == 0 || strcmp(argv[2], "legacy_macro") == 0) {
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
