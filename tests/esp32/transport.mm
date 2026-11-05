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
        assert([ESP32InputBridge saveSettings:settings forHost:host]);
        ESP32InputBridge *bridge = [[ESP32InputBridge alloc] initWithHostUUID:host];
        if (strcmp(argv[2], "lifecycle") == 0) {
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
            usleep(1300000); // Observe an actual WebSocket ping/pong RTT.
            NSDictionary *snapshot = [bridge monitorSnapshot];
            assert([snapshot[@"ready"] boolValue] && [snapshot[@"keyboard"] boolValue]);
            assert([snapshot[@"mouse"] boolValue] && [snapshot[@"rttMs"] doubleValue] >= 0);
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
            assert([[bridge monitorSnapshot][@"paused"] boolValue]);
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
        assert([[bridge monitorSnapshot][@"rttMs"] doubleValue] < 0);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:store];
    }
    return 0;
}
