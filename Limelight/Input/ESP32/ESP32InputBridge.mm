#import "ESP32InputBridge.h"
#include "ESP32MacKeyMap.h"
#include "ESP32KeyboardRouter.h"
#include "ESP32MouseRouter.h"
#include <limits>
#include "fivedetector.h"
#include "ESP32PixelBufferReader.h"
#ifdef ESP32_STANDALONE_TEST
#define ESP32Log(...) NSLog(__VA_ARGS__)
#else
#import "../../Utility/Logger.h"
#define ESP32Log(...) LogTag(LOG_I, @"ESP32", __VA_ARGS__)
#endif
#import <dispatch/dispatch.h>

static NSString *ESP32MacroCode(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 1) {
        unichar c = [name.uppercaseString characterAtIndex:0];
        if (c >= 'A' && c <= 'Z') name = [@"Key" stringByAppendingString:name.uppercaseString];
        else if (c >= '0' && c <= '9') name = [@"Digit" stringByAppendingString:name];
    }
    for (unsigned usage = 4; usage <= 99; ++usage) {
        const char *code = esp32KeyboardCode(usage);
        if (code && [name caseInsensitiveCompare:[NSString stringWithUTF8String:code]] == NSOrderedSame)
            return [NSString stringWithUTF8String:code];
    }
    return nil;
}

static NSString *const ESP32SettingsPrefix = @"esp32.input.host.";
static NSArray<NSString *> *ESP32ButtonNames(void) {
    return @[@"left", @"right", @"middle", @"back", @"forward"];
}
static NSString *ESP32Code(unsigned usage) {
    const char *code = esp32KeyboardCode(usage);
    return code ? [NSString stringWithUTF8String:code] : nil;
}

// Configuration is a snapshot for the lifetime of a stream. Host profiles never
// inherit an ESP32 endpoint from a global/default profile.
static NSURL *ESP32Endpoint(NSDictionary *settings) {
    if (![settings[@"address"] isKindOfClass:NSString.class] ||
        ![settings[@"access_key"] isKindOfClass:NSString.class]) return nil;
    NSString *address = [settings[@"address"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![address containsString:@"://"]) address = [@"ws://" stringByAppendingString:address];
    NSURLComponents *parts = [NSURLComponents componentsWithString:address];
    if ([parts.scheme isEqualToString:@"http"]) parts.scheme = @"ws";
    if ([parts.scheme isEqualToString:@"https"]) parts.scheme = @"wss";
    NSString *key = settings[@"access_key"];
    NSNumber *port = settings[@"port"];
    if (![port isKindOfClass:NSNumber.class] || port.doubleValue != port.integerValue ||
        port.integerValue < 1 || port.integerValue > 65535 ||
        (parts.port && ![parts.port isEqualToNumber:port]) ||
        parts.host.length == 0 ||
        (![parts.scheme isEqualToString:@"ws"] && ![parts.scheme isEqualToString:@"wss"]) ||
        parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil ||
        (parts.path.length && ![parts.path isEqualToString:@"/"] && ![parts.path isEqualToString:@"/ws"]) ||
        key.length != 6 || [key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
    parts.port = port;
    parts.path = @"/ws";
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"key" value:key]];
    return parts.URL;
}

@interface ESP32InputBridge ()
- (void)startOnQueue;
- (void)openOnQueue;
- (void)tickOnQueue;
- (void)setStatusOnQueue:(NSString *)status;
- (void)appendOnQueue:(NSString *)type fields:(NSDictionary *)fields;
- (void)enqueueInput:(NSString *)type fields:(NSDictionary *)fields keyboard:(BOOL)keyboard;
- (void)enqueueKeyboardReport:(const Esp32KeyboardRouter::Report &)report;
- (void)receiveOnQueue:(NSURLSessionWebSocketTask *)task;
- (void)failOnQueue:(NSString *)status;
- (void)pumpOnQueue;
@end

@implementation ESP32InputBridge {
    dispatch_queue_t _visionQueue;
    BOOL _visionBusy, _visionWasActive;
    uint64_t _visionGeneration;
    NSTimeInterval _visionSampled;
    FiveVision::Edge _visionEdge;
    ESP32PixelBufferReader _pixelReader;
    NSString *_visionReason;
    NSString *_videoPath;
    NSString *_visionFailure;
    NSTimeInterval _visionLastWatchdog;
    NSTimeInterval _visionLastFrame, _visionLastSummary;
    unsigned long long _visionFrames, _visionSamples, _visionSkipped, _macroRequests;
    int _visionLastDigit;
    OSType _visionFormat;
    size_t _visionWidth, _visionHeight;
    NSDictionary *_settings;
    NSURL *_endpoint;
    NSSet<NSString *> *_excluded;
    BOOL _enabled, _exclusive, _paused, _stopped;
    uint8_t _selected;
    uint64_t _epoch, _nextEpoch, _keyboardGeneration, _mouseGeneration;
    NSUInteger _pendingReports;
    NSString *_statusText;
    Esp32KeyboardRouter _keyboard;
    Esp32MouseRouter _mouse;

    // All transport state below belongs exclusively to _queue.
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSURLSessionWebSocketTask *_task;
    NSMutableArray<NSDictionary *> *_outbox;
    BOOL _sending, _awaitingHello, _exclusiveSupported;
    uint32_t _sequence;
    NSTimeInterval _openedAt, _lastPong, _retryAt;
    unsigned _pingTicks;
}

+ (NSDictionary *)settingsForHost:(NSString *)hostUUID {
    NSDictionary *defaults = @{@"enabled": @NO, @"keyboard_enabled": @YES,
        @"mouse_enabled": @YES, @"mouse_buttons": @31, @"address": @"",
        @"port": @80, @"access_key": @"", @"excluded_keys": @"",
        @"vision_enabled": @NO, @"shortcut_macro": @0, @"macro_key": @"E", @"macro_repeats": @3, @"macro_hold_ms": @2, @"macro_interval_ms": @2};
    NSMutableDictionary *result = defaults.mutableCopy;
    if (hostUUID.length) {
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:[ESP32SettingsPrefix stringByAppendingString:hostUUID]];
        if (saved) [result addEntriesFromDictionary:saved];
    }
    NSString *code=ESP32MacroCode(result[@"macro_key"]);
    if ([code hasPrefix:@"Key"] && code.length==4) result[@"macro_key"]=[code substringFromIndex:3];
    else if ([code hasPrefix:@"Digit"] && code.length==6) result[@"macro_key"]=[code substringFromIndex:5];
    else if(code)result[@"macro_key"]=code;
    return result;
}

+ (NSString *)validationErrorForSettings:(NSDictionary *)settings {
    if (![settings[@"enabled"] boolValue]) return nil;
    if (!ESP32Endpoint(settings)) return @"ESP32 invalid endpoint";
    NSNumber *buttons = settings[@"mouse_buttons"];
    if (![buttons isKindOfClass:NSNumber.class] || buttons.doubleValue != buttons.integerValue ||
        buttons.integerValue < 0 || buttons.integerValue > 31 ||
        (![settings[@"keyboard_enabled"] boolValue] &&
         (![settings[@"mouse_enabled"] boolValue] || buttons.integerValue == 0))) return @"ESP32 select input";
    if (![settings[@"excluded_keys"] isKindOfClass:NSString.class]) return @"ESP32 invalid excluded keys";
    if (!ESP32MacroCode(settings[@"macro_key"] ?: @"KeyE")) return @"ESP32 invalid macro key";
    NSDictionary *ranges = @{@"shortcut_macro": @[@0, @12, @0], @"macro_repeats": @[@3, @5, @3],
                              @"macro_hold_ms": @[@1, @2000, @2], @"macro_interval_ms": @[@1, @60000, @2]};
    for (NSString *field in ranges) {
        NSArray *range = ranges[field];
        NSNumber *value = settings[field] ?: range[2];
        if (![value isKindOfClass:NSNumber.class] || value.doubleValue != value.integerValue ||
            value.integerValue < [range[0] integerValue] || value.integerValue > [range[1] integerValue])
            return @"ESP32 invalid macro settings";
        if ([field isEqualToString:@"shortcut_macro"] && value.integerValue >= 9 && value.integerValue <= 11)
            return @"ESP32 macro shortcut reserved";
    }
    NSMutableSet *valid = [NSMutableSet set];
    for (unsigned i = 0; i < 232; ++i) if (ESP32Code(i)) [valid addObject:ESP32Code(i)];
    for (NSString *raw in [settings[@"excluded_keys"] componentsSeparatedByString:@","]) {
        NSString *code = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (code.length && ![valid containsObject:code]) return @"ESP32 invalid excluded keys";
    }
    return nil;
}

+ (BOOL)saveSettings:(NSDictionary *)settings forHost:(NSString *)hostUUID {
    if (!hostUUID.length || [hostUUID isEqualToString:@"__global__"] || [self validationErrorForSettings:settings]) return NO;
    [NSUserDefaults.standardUserDefaults setObject:settings forKey:[ESP32SettingsPrefix stringByAppendingString:hostUUID]];
    return YES;
}

- (instancetype)initWithHostUUID:(NSString *)hostUUID {
    if ((self = [super init])) {
        _settings = [[self.class settingsForHost:hostUUID] copy];
        _enabled = [_settings[@"enabled"] boolValue];
        _exclusive = _enabled && [_settings[@"keyboard_enabled"] boolValue];
        _selected = _enabled && [_settings[@"mouse_enabled"] boolValue] ? [_settings[@"mouse_buttons"] unsignedCharValue] & 31 : 0;
        NSMutableSet *excluded = [NSMutableSet set];
        if ([_settings[@"excluded_keys"] isKindOfClass:NSString.class]) {
            for (NSString *raw in [_settings[@"excluded_keys"] componentsSeparatedByString:@","]) {
                [excluded addObject:[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            }
        }
        _excluded = excluded.copy;
        _statusText = @"ESP32 disabled";
        _queue = dispatch_queue_create("org.worldline233.moonlight.esp32", DISPATCH_QUEUE_SERIAL);
        _visionLastDigit = -99;
        ESP32Log(@"[config] enabled=%d keyboard=%d vision=%d output=%@ repeats=%@ hold_ms=%@ interval_ms=%@ shortcut_F=%@", _enabled, _exclusive, [_settings[@"vision_enabled"] boolValue], _settings[@"macro_key"], _settings[@"macro_repeats"], _settings[@"macro_hold_ms"], _settings[@"macro_interval_ms"], _settings[@"shortcut_macro"]);
        _visionQueue = dispatch_queue_create("org.worldline233.esp32.vision", DISPATCH_QUEUE_SERIAL);
        _outbox = [NSMutableArray array];
        if (_enabled) {
            if ([self.class validationErrorForSettings:_settings]) {
                _statusText = @"ESP32 invalid endpoint";
            } else {
                _endpoint = ESP32Endpoint(_settings);
                __weak ESP32InputBridge *weakSelf = self;
                dispatch_async(_queue, ^{ [weakSelf startOnQueue]; });
            }
        }
    }
    return self;
}

- (BOOL)enabled { return _enabled; }
- (BOOL)visionEnabled { return _exclusive && [_settings[@"vision_enabled"] boolValue]; }
- (BOOL)configured { return _endpoint != nil; }
- (BOOL)keyboardExclusive { return _exclusive; }
- (BOOL)ready { @synchronized (self) { return !_stopped && _epoch != 0; } }
- (BOOL)paused { @synchronized (self) { return _paused; } }
- (NSString *)statusText { @synchronized (self) { return _statusText; } }

- (void)setStatusOnQueue:(NSString *)status {
    @synchronized (self) { _statusText = status.copy; }
    // Never log an endpoint or an NSError: either can contain the control key.
    ESP32Log(@"[connection] status=%@", status);
}

- (NSDictionary *)monitorSnapshot {
    @synchronized (self) {
        return @{ @"ready": @(!_stopped && _epoch != 0), @"paused": @(_paused),
                  @"keyboard": @(_exclusive), @"mouse": @(_selected != 0) };
    }
}

- (void)startOnQueue {
    @synchronized (self) { if (_stopped) return; }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), 200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    __weak ESP32InputBridge *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tickOnQueue]; });
    dispatch_resume(_timer);
    [self openOnQueue];
}

- (void)openOnQueue {
    @synchronized (self) { if (_stopped) return; _epoch = 0; }
    _sequence = 0;
    _sending = NO;
    [_outbox removeAllObjects];
    _awaitingHello = YES;
    _exclusiveSupported = NO;
    _openedAt = NSProcessInfo.processInfo.systemUptime;
    _task = [NSURLSession.sharedSession webSocketTaskWithURL:_endpoint];
    _task.maximumMessageSize = 4096;
    [_task resume];
    [self setStatusOnQueue:@"ESP32 connecting"];
    [self appendOnQueue:@"hello" fields:@{@"protocol": @2, @"client": @"moonlight-macos-esp32-nkro"}];
    [self receiveOnQueue:_task];
}

- (void)receiveOnQueue:(NSURLSessionWebSocketTask *)task {
    __weak ESP32InputBridge *weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        ESP32InputBridge *bridge = weakSelf;
        if (!bridge) return;
        dispatch_async(bridge->_queue, ^{
            @synchronized (bridge) { if (bridge->_stopped) return; }
            if (bridge->_task != task) return;
            if (error || message.type != NSURLSessionWebSocketMessageTypeString) {
                [bridge failOnQueue:@"ESP32 disconnected"]; return;
            }
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
            if (![decoded isKindOfClass:NSDictionary.class] || [decoded[@"type"] isEqual:@"error"]) {
                [bridge failOnQueue:@"ESP32 protocol rejected"]; return;
            }
            if (bridge->_awaitingHello && [decoded[@"type"] isEqual:@"macro_status"] &&
                [decoded[@"running"] isEqual:@NO]) {
                if (![decoded[@"protocol"] isEqual:@2] || ![decoded[@"keyboard_nkro"] isEqual:@YES] ||
                    ![decoded[@"keyboard_max_keys"] isEqual:@16]) {
                    [bridge failOnQueue:@"ESP32 incompatible firmware"]; return;
                }
                bridge->_exclusiveSupported = [decoded[@"exclusive_latest_state"] isEqual:@YES] &&
                    [decoded[@"exclusive_configurable_key"] isEqual:@YES];
                ESP32Log(@"[handshake] protocol=%@ nkro=%@ max_keys=%@ latest_state=%@ configurable_key=%@ macro_supported=%d", decoded[@"protocol"], decoded[@"keyboard_nkro"], decoded[@"keyboard_max_keys"], decoded[@"exclusive_latest_state"], decoded[@"exclusive_configurable_key"], bridge->_exclusiveSupported);
                bridge->_awaitingHello = NO;
                bridge->_lastPong = NSProcessInfo.processInfo.systemUptime;
                bridge->_pingTicks = 0;
                // The ordered send pump places this before all new input reports.
                [bridge appendOnQueue:@"release_all" fields:@{}];
                @synchronized (bridge) { bridge->_epoch = ++bridge->_nextEpoch; }
                [bridge setStatusOnQueue:@"ESP32 connected"];
            }
            if ([decoded[@"type"] isEqual:@"macro_status"]) {
                ESP32Log(@"[device-status] running=%d phase=%@ completed_steps=%@ remaining_ms=%@ (status snapshot, not USB completion acknowledgement)", [decoded[@"running"] boolValue], [@[@"idle",@"active",@"resting",@"stopping",@"stopped"] containsObject:decoded[@"phase"] ?: @""] ? decoded[@"phase"] : @"unknown", [decoded[@"completed_steps"] isKindOfClass:NSNumber.class] ? decoded[@"completed_steps"] : @0, [decoded[@"total_remaining_ms"] isKindOfClass:NSNumber.class] ? decoded[@"total_remaining_ms"] : @0);
            }
            [bridge receiveOnQueue:task];
        });
    }];
}

- (void)tickOnQueue {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!_task) {
        if (now >= _retryAt) [self openOnQueue];
        return;
    }
    if ((_awaitingHello && now - _openedAt > 5.0) || (!_awaitingHello && now - _lastPong > 3.0)) {
        [self failOnQueue:@"ESP32 timeout"]; return;
    }
    if (_awaitingHello) return;
    [self appendOnQueue:@"ping" fields:@{}];
    if (++_pingTicks % 5 == 0) {
        NSURLSessionWebSocketTask *task = _task;
        __weak ESP32InputBridge *weakSelf = self;
        [task sendPingWithPongReceiveHandler:^(NSError *error) {
            ESP32InputBridge *bridge = weakSelf;
            if (!bridge) return;
            dispatch_async(bridge->_queue, ^{
                if (bridge->_task != task) return;
                if (error) [bridge failOnQueue:@"ESP32 disconnected"];
                else bridge->_lastPong = NSProcessInfo.processInfo.systemUptime;
            });
        }];
    }
}

- (void)failOnQueue:(NSString *)status {
    @synchronized (self) { _epoch = 0; ++_keyboardGeneration; ++_mouseGeneration; }
    NSURLSessionWebSocketTask *old = _task;
    _task = nil;
    [old cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    [_outbox removeAllObjects];
    _sending = NO;
    _awaitingHello = NO;
    _retryAt = NSProcessInfo.processInfo.systemUptime + 2.0;
    [self setStatusOnQueue:status];
}

- (void)appendOnQueue:(NSString *)type fields:(NSDictionary *)fields {
    if (!_task) return;
    if (_outbox.count >= 256 || _sequence == std::numeric_limits<uint32_t>::max()) {
        [self failOnQueue:@"ESP32 input queue full"]; return;
    }
    if ([type isEqualToString:@"exclusive_macro"] && !_exclusiveSupported) {
        ESP32Log(@"[macro] blocked reason=firmware_missing_configurable_key request=%@", fields[@"request_id"]);
        [self setStatusOnQueue:@"ESP32 firmware needs macro update"];
        return;
    }
    NSMutableDictionary *message = fields.mutableCopy;
    message[@"type"] = type;
    message[@"seq"] = @(++_sequence);
    NSUInteger kind = [type isEqualToString:@"state"] ? 1 :
        ([type isEqualToString:@"mouse_state"] ? 2 : ([type isEqualToString:@"exclusive_macro"] ? 3 : 0));
    @synchronized (self) {
        uint64_t generation = kind == 2 ? _mouseGeneration : _keyboardGeneration;
        [_outbox addObject:@{@"payload": message, @"kind": @(kind), @"epoch": @(_epoch), @"generation": @(generation)}];
    }
    if ([type isEqual:@"exclusive_macro"]) ESP32Log(@"[macro] queued request=%@ seq=%u pending=%lu", fields[@"request_id"], _sequence, (unsigned long)_outbox.count);
    [self pumpOnQueue];
}

- (void)pumpOnQueue {
    if (_sending || !_task) return;
    NSDictionary *fields = nil;
    while (_outbox.count) {
        NSDictionary *entry = _outbox.firstObject;
        [_outbox removeObjectAtIndex:0];
        NSUInteger kind = [entry[@"kind"] unsignedIntegerValue];
        @synchronized (self) {
            if (kind == 3 && _paused) { ESP32Log(@"[macro] dropped reason=paused request=%@", entry[@"payload"][@"request_id"]); continue; }
            if (kind && (_stopped || !_epoch || [entry[@"epoch"] unsignedLongLongValue] != _epoch ||
                [entry[@"generation"] unsignedLongLongValue] != (kind == 2 ? _mouseGeneration : _keyboardGeneration))) {
                if(kind==3) ESP32Log(@"[macro] dropped reason=stale_queue_entry request=%@",entry[@"payload"][@"request_id"]);
                continue;
            }
        }
        fields = entry[@"payload"];
        break;
    }
    if (!fields) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:nullptr];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    _sending = YES;
    NSURLSessionWebSocketTask *task = _task;
    __weak ESP32InputBridge *weakSelf = self;
    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError *error) {
        ESP32InputBridge *bridge = weakSelf;
        if (!bridge) return;
        dispatch_async(bridge->_queue, ^{
            if (bridge->_task != task) return;
            bridge->_sending = NO;
            if ([fields[@"type"] isEqual:@"exclusive_macro"]) ESP32Log(@"[macro] transport_%@ request=%@ seq=%@ error_code=%ld (USB output not confirmed)", error ? @"failed" : @"sent", fields[@"request_id"], fields[@"seq"], (long)error.code);
            if (error) [bridge failOnQueue:@"ESP32 disconnected"];
            else [bridge pumpOnQueue];
        });
    }];
}

// Called with @synchronized(self) held. Mark reports at input time, so a queued
// down cannot reappear after a release, pause, disconnect, or reconnect.
- (void)enqueueInput:(NSString *)type fields:(NSDictionary *)fields keyboard:(BOOL)keyboard {
    if (!_epoch || _stopped) return;
    const uint64_t epoch = _epoch;
    const uint64_t generation = keyboard ? _keyboardGeneration : _mouseGeneration;
    if (_pendingReports >= 256) {
        _epoch = 0;
        dispatch_async(_queue, ^{ [self failOnQueue:@"ESP32 input queue full"]; });
        return;
    }
    ++_pendingReports;
    dispatch_async(_queue, ^{
        @synchronized (self) {
            --self->_pendingReports;
            if (self->_stopped || self->_epoch != epoch ||
                generation != (keyboard ? self->_keyboardGeneration : self->_mouseGeneration)) {
                if ([type isEqual:@"exclusive_macro"]) ESP32Log(@"[macro] dropped reason=cancelled_or_connection_changed request=%@", fields[@"request_id"]);
                return;
            }
            [self appendOnQueue:type fields:fields];
        }
    });
}

- (BOOL)handleMacKeyCode:(unsigned short)keyCode pressed:(BOOL)pressed {
    if (!_exclusive) return NO;
    @synchronized (self) {
        unsigned usage = esp32MacKeyUsage(keyCode);
        NSString *code = ESP32Code(usage);
        if (code && [_excluded containsObject:code]) return YES;
        auto report = _keyboard.handle(usage, pressed, _paused ? 0 : _epoch);
        if (report.send) [self enqueueKeyboardReport:report];
    }
    // Includes unsupported keys, offline and paused input. Never native fallback.
    return YES;
}

- (void)enqueueKeyboardReport:(const Esp32KeyboardRouter::Report &)report {
    NSMutableArray *keys = [NSMutableArray array];
    NSMutableArray *modifiers = [NSMutableArray array];
    for (unsigned usage : report.keys) if (usage && ESP32Code(usage)) [keys addObject:ESP32Code(usage)];
    for (unsigned i = 0; i < 8; ++i) if (report.modifiers & (1u << i)) [modifiers addObject:ESP32Code(224 + i)];
    [self enqueueInput:@"state" fields:@{@"keys": keys, @"modifiers": modifiers} keyboard:YES];
}

- (void)handlePhysicalModifierMask:(NSUInteger)mask {
    if (!_exclusive) return;
    static const unsigned usages[] = {225, 229, 224, 228, 226, 230, 227, 231};
    @synchronized (self) {
        for (unsigned i = 0; i < 8; ++i) {
            if ([_excluded containsObject:ESP32Code(usages[i])]) continue;
            auto report = _keyboard.handle(usages[i], (mask & (1u << i)) != 0, _paused ? 0 : _epoch);
            if (report.send) [self enqueueKeyboardReport:report];
        }
    }
}

- (BOOL)handleMouseButton:(int)button pressed:(BOOL)pressed {
    if (!_enabled || !_endpoint) return NO;
    static const unsigned map[] = {99, 0, 2, 1, 3, 4};
    unsigned index = button >= 1 && button <= 5 ? map[button] : 99;
    @synchronized (self) {
        auto result = _mouse.handle(index, pressed, _paused ? 0 : _epoch, _selected, _paused);
        if (result.sendUsb) {
            NSMutableArray *buttons = [NSMutableArray array];
            for (unsigned i = 0; i < 5; ++i) if (result.usbButtons & (1u << i)) [buttons addObject:ESP32ButtonNames()[i]];
            [self enqueueInput:@"mouse_state" fields:@{@"buttons": buttons} keyboard:NO];
        }
        return result.consume;
    }
}

- (uint8_t)releaseMouseButtons {
    @synchronized (self) {
        uint8_t native = _mouse.cancel();
        ++_mouseGeneration;
        if (_endpoint) [self enqueueInput:@"mouse_state" fields:@{@"buttons": @[]} keyboard:NO];
        return native;
    }
}
- (void)releaseKeyboard {
    @synchronized (self) {
        _keyboard.cancel();
        ++_keyboardGeneration;
        if (_exclusive && _endpoint) [self enqueueInput:@"state" fields:@{@"keys": @[], @"modifiers": @[]} keyboard:YES];
    }
}
- (void)releaseAll {
    @synchronized(self) { ++_visionGeneration; }
    @synchronized (self) {
        _keyboard.cancel(); _mouse.cancel();
        ++_keyboardGeneration; ++_mouseGeneration;
        if (_epoch && !_stopped) {
            const uint64_t epoch = _epoch;
            dispatch_async(_queue, ^{
                @synchronized (self) {
                    if (self->_epoch == epoch && !self->_stopped)
                        [self appendOnQueue:@"release_all" fields:@{}];
                }
            });
        }
    }
}
- (BOOL)isExclusiveMacroKeyCode:(unsigned short)keyCode {
    unsigned function = [_settings[@"shortcut_macro"] unsignedIntValue];
    return _exclusive && function >= 1 && function <= 12 &&
           !(function >= 9 && function <= 11) && esp32MacKeyUsage(keyCode) == 57 + function;
}
- (void)triggerExclusiveMacro {
    @synchronized (self) {
        unsigned long long request=++_macroRequests;
        if (!_exclusive || _paused || !_epoch || _stopped) {
            ESP32Log(@"[macro] blocked request=%llu keyboard=%d paused=%d ready=%d stopped=%d", request, _exclusive, _paused, _epoch!=0, _stopped); return;
        }
        ESP32Log(@"[macro] requested request=%llu output=%@ repeats=%@ hold_ms=%@ interval_ms=%@", request, _settings[@"macro_key"], _settings[@"macro_repeats"], _settings[@"macro_hold_ms"], _settings[@"macro_interval_ms"]);
        [self enqueueInput:@"exclusive_macro" fields:@{
            @"request_id": @(request),
            @"key": ESP32MacroCode(_settings[@"macro_key"] ?: @"KeyE"),
            @"repeats": _settings[@"macro_repeats"] ?: @3,
            @"hold_ms": _settings[@"macro_hold_ms"] ?: @2,
            @"interval_ms": _settings[@"macro_interval_ms"] ?: @2
        } keyboard:YES];
    }
}
- (void)logDiagnostics {
    @synchronized(self) {
        uint64_t epoch=_epoch;
        if(epoch && !_stopped) dispatch_async(_queue, ^{
            @synchronized(self) { if(epoch==self->_epoch && !self->_stopped) {
                ESP32Log(@"[device-status] querying current macro state");[self appendOnQueue:@"macro_status" fields:@{}];
            } }
        });
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        ESP32Log(@"[snapshot] keyboard=%d vision=%d ready=%d paused=%d stopped=%d path=%@ frames=%llu samples=%llu skipped=%llu frame_age_ms=%.1f format=0x%08x size=%zux%zu reason=%@", _exclusive, [_settings[@"vision_enabled"] boolValue], _epoch!=0, _paused, _stopped, _videoPath ?: @"observer_not_attached", _visionFrames, _visionSamples, _visionSkipped, _visionLastFrame ? (now-_visionLastFrame)*1000 : -1, (unsigned)_visionFormat, _visionWidth, _visionHeight, _visionReason ?: @"waiting_for_frame");
    }
}
- (void)noteVideoPath:(NSString *)path captureActive:(BOOL)active {
    @synchronized(self) {
        BOOL changed=![_videoPath isEqual:path]; _videoPath=[path copy];
        BOOL missing=[_settings[@"vision_enabled"] boolValue] && _exclusive && (!_visionLastFrame || NSProcessInfo.processInfo.systemUptime-_visionLastFrame>3);
        BOOL periodic=NSProcessInfo.processInfo.systemUptime-_visionLastWatchdog>=2;
        if (changed || (missing && periodic)) { _visionLastWatchdog=NSProcessInfo.processInfo.systemUptime; ESP32Log(@"[video-path] path=%@ capture=%d observer_frames=%llu problem=%@",path,active,_visionFrames,missing ? @"no_decoded_frames_check_renderer_or_video_paused" : @"none"); }
    }
}
- (void)observeVideoFrame:(CVPixelBufferRef)frame active:(BOOL)active {
    if (!_enabled) return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    uint64_t generation,epoch;BOOL summary;
    size_t width=CVPixelBufferGetWidth(frame),height=CVPixelBufferGetHeight(frame);
    OSType format=CVPixelBufferGetPixelFormatType(frame);
    @synchronized(self) {
        ++_visionFrames;_visionLastFrame=now;
        if (_visionFormat!=format || _visionWidth!=width || _visionHeight!=height) {
            _visionFormat=format;_visionWidth=width;_visionHeight=height;
            ESP32Log(@"[frame] size=%zux%zu format=0x%08x planes=%zu reference=2560x1440 slots=3 search_roi=(684,1210,200,84) scaled_roi=(%.1f,%.1f,%.1f,%.1f)",width,height,(unsigned)format,CVPixelBufferGetPlaneCount(frame),684.0*width/2560,1210.0*height/1440,200.0*width/2560,84.0*height/1440);
        }
        NSString *reason=![_settings[@"vision_enabled"] boolValue] ? @"auto_disabled" : !_exclusive ? @"keyboard_not_owned" : !active ? @"input_not_captured" : _paused ? @"paused" : !_epoch ? @"esp_offline" : _stopped ? @"stopped" : @"sampling";
        summary=now-_visionLastSummary>=1;
        if (![_visionReason isEqual:reason] || summary) {
            ESP32Log(@"[vision-gate] reason=%@ ready=%d capture=%d frames=%llu samples=%llu skipped=%llu",reason,_epoch!=0,active,_visionFrames,_visionSamples,_visionSkipped);
            _visionReason=reason;
            if(summary)_visionLastSummary=now;
        }
        if (![reason isEqual:@"sampling"]) {if(_visionWasActive)++_visionGeneration;_visionWasActive=NO;return;}
        _visionWasActive=YES;
        if (_visionBusy || now-_visionSampled<0.025) {++_visionSkipped;return;}
        _visionBusy=YES;_visionSampled=now;generation=_visionGeneration;epoch=_epoch;
    }
    CVPixelBufferRetain(frame);
    dispatch_async(_visionQueue, ^{
        FiveVision::Patch patch;bool valid=false;
        NSString *failure=@"unsupported_pixel_format";
        OSStatus conversionStatus=noErr;
        BOOL compressed=ESP32PixelBufferReader::compressed420(format);
        CVPixelBufferRef readable=compressed ? self->_pixelReader.convert(frame,conversionStatus) : frame;
        OSType readableFormat=readable ? CVPixelBufferGetPixelFormatType(readable) : 0;
        if(compressed && (!readable || summary)) ESP32Log(@"[pixel-convert] source=0x%08x output=0x%08x status=%d elapsed_ms=%.2f",(unsigned)format,(unsigned)readableFormat,(int)conversionStatus,(NSProcessInfo.processInfo.systemUptime-now)*1000);
        if(compressed && !readable)failure=@"pixel_format_conversion_failed";
        bool ten = readableFormat==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || readableFormat==kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
        bool eight = readableFormat==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || readableFormat==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        if(eight || ten) {
            CVReturn lock=CVPixelBufferLockBaseAddress(readable,kCVPixelBufferLock_ReadOnly);
            if(lock==kCVReturnSuccess) {
                const uint8_t *base=(const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(readable,0);
                size_t stride=CVPixelBufferGetBytesPerRowOfPlane(readable,0);
                failure=base ? @"unsupported_resolution_or_aspect" : @"missing_luma_plane";
                if(base)valid=FiveVision::extract((int)width,(int)height,[&](int x,int y){
                    const uint8_t *p=base+y*stride+x*(ten?2:1);return ten ? int((p[0]|(p[1]<<8))>>8) : int(*p);
                },patch);
                CVPixelBufferUnlockBaseAddress(readable,kCVPixelBufferLock_ReadOnly);
            } else failure=@"pixel_buffer_lock_failed";
        }
        CVPixelBufferRelease(frame);
        auto result=valid ? FiveVision::detect(patch) : FiveVision::Result{};
        @synchronized(self) {
            ++self->_visionSamples;
            NSTimeInterval finished=NSProcessInfo.processInfo.systemUptime;
            BOOL current=generation==self->_visionGeneration && epoch==self->_epoch && !self->_stopped && !self->_paused;
            BOOL fresh=finished-now<0.1;
            BOOL fire=NO;
            if(current && fresh && valid) fire=self->_visionEdge.update(result.digit,(uint64_t)(finished*1000));
            else if(!current) self->_visionEdge.reset();
            else self->_visionEdge.update(-1,(uint64_t)(finished*1000));
            NSString *outcome=valid ? (result.digit==0 ? @"icon_absent" : result.digit==1 ? @"one_without_count" : result.digit==2 ? @"two" : result.digit==3 ? @"three" : result.digit==4 ? @"four" : result.digit==5 ? @"five" : @"below_threshold_or_unknown_digit") : failure;
            if(summary || result.digit!=self->_visionLastDigit || fire || ![self->_visionFailure isEqual:outcome]) {
                ESP32Log(@"[recognition] valid=%d reason=%@ digit=%d slot=%d icon=%.4f one=%.4f two=%.4f three=%.4f four=%.4f five=%.4f margin=%.4f thresholds=(icon>=0.80 digit>=0.78 margin>=0.065) age_ms=%.2f current=%d fresh=%d trigger=%d confirmations=%d latched=%d",valid,outcome,result.digit,result.slot+1,result.icon,result.scores[1],result.scores[2],result.three,result.scores[4],result.five,result.margin,(finished-now)*1000,current,fresh,fire,self->_visionEdge.positiveCount(),self->_visionEdge.isLatched());
                self->_visionLastDigit=result.digit;self->_visionFailure=outcome;
            }
            if(fire) {ESP32Log(@"[vision-trigger] confirmed_five output=%@",self->_settings[@"macro_key"]);[self triggerExclusiveMacro];}
            self->_visionBusy=NO;
        }
    });
}
- (void)togglePaused {
    @synchronized (self) { _paused = !_paused; [self releaseAll]; }
}
- (void)reconnect {
    @synchronized (self) {
        [self releaseAll];
        _epoch = 0;
    }
    dispatch_async(_queue, ^{ [self failOnQueue:@"ESP32 reconnecting"]; self->_retryAt = 0; });
}
- (void)stop {
    @synchronized (self) {
        if (_stopped) return;
        _stopped = YES;
        _epoch = 0;
        ++_keyboardGeneration; ++_mouseGeneration;
    }
    dispatch_async(_queue, ^{
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        // A best-effort final release, with a short close deadline. Unexpected
        // network loss still relies on the firmware's existing watchdog.
        [self->_outbox removeAllObjects];
        [self appendOnQueue:@"release_all" fields:@{}];
        NSURLSessionWebSocketTask *task = self->_task;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), self->_queue, ^{
            if (self->_task == task) {
                self->_task = nil;
                [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            }
        });
    });
}
@end
