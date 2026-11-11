#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper over the private CoreBrightness framework.
///
/// CoreBrightness is loaded at run time with dlopen; nothing links against it, so a macOS
/// release that drops a class just makes `init` return nil.
///
/// Read docs/HARDWARE.md before writing any property. Never write `DisplayPowerStateEvent`.
@interface LLCoreBrightness : NSObject

/// YES if CoreBrightness and its BrightnessSystemClient class can be loaded.
+ (BOOL)isAvailable;

/// Returns nil when CoreBrightness or BrightnessSystemClient is unavailable.
+ (nullable instancetype)connect;
- (instancetype)init NS_UNAVAILABLE;

/// Reads a BrightnessSystemClient property (synchronous XPC to corebrightnessd).
- (nullable id)propertyForKey:(NSString *)key;

/// Writes a BrightnessSystemClient property. Returns corebrightnessd's acceptance flag.
- (BOOL)setProperty:(id)value forKey:(NSString *)key;

#pragma mark Keyboard backlight (read-only)

/// IDs of keyboard backlights (the built-in keyboard and, on some Macs, extra key lights).
- (NSArray<NSNumber *> *)keyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboardID;
- (BOOL)isKeyboardBacklightDimmed:(uint64_t)keyboardID;
/// YES when the room is too bright for the keyboard backlight (ambient saturation).
- (BOOL)isKeyboardBacklightSaturated:(uint64_t)keyboardID;

@end

NS_ASSUME_NONNULL_END
