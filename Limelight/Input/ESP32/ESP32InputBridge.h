#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// Each stream owns one bridge. Calls are thread safe; WebSocket work never runs
// on the caller's input thread. Mouse movement and scrolling do not enter here.
@interface ESP32InputBridge : NSObject
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) BOOL configured;
@property(nonatomic, readonly) BOOL keyboardExclusive;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL paused;
@property(nonatomic, readonly, copy) NSString *statusText;
+ (NSDictionary *)settingsForHost:(NSString *)hostUUID NS_SWIFT_NAME(settings(for:));
+ (nullable NSString *)validationErrorForSettings:(NSDictionary *)settings NS_SWIFT_NAME(validationError(for:));
+ (BOOL)saveSettings:(NSDictionary *)settings forHost:(NSString *)hostUUID NS_SWIFT_NAME(save(_:for:));
- (instancetype)initWithHostUUID:(NSString *)hostUUID;
- (BOOL)handleMacKeyCode:(unsigned short)keyCode pressed:(BOOL)pressed;
- (void)handlePhysicalModifierMask:(NSUInteger)mask;
// Moonlight button numbering: left=1, middle=2, right=3, back=4, forward=5.
- (BOOL)handleMouseButton:(int)button pressed:(BOOL)pressed;
// Returns HID bit mask of native buttons that the caller must release.
- (uint8_t)releaseMouseButtons;
- (void)releaseKeyboard;
- (void)releaseAll;
- (BOOL)isExclusiveMacroKeyCode:(unsigned short)keyCode;
- (void)triggerExclusiveMacro;
- (void)logDiagnostics;
- (void)noteVideoPath:(NSString *)path captureActive:(BOOL)active;
- (void)observeVideoFrame:(CVPixelBufferRef)frame active:(BOOL)active;
- (void)togglePaused;
- (void)reconnect;
// Coherent, thread-safe snapshot of basic input connection state.
- (NSDictionary *)monitorSnapshot;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
