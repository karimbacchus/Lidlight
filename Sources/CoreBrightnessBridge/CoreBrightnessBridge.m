#import "CoreBrightnessBridge.h"
#import <dlfcn.h>

// Private interfaces, declared here only so ARC knows the ownership rules
// (`copy…` methods return +1 objects). Verified against macOS 27.2 (Mac17,12).
@interface BrightnessSystemClient : NSObject
- (nullable id)copyPropertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
- (void)registerNotificationBlock:(void (^)(id key, id value))block forProperties:(NSArray *)keys;
@end

@interface KeyboardBrightnessClient : NSObject
- (nullable NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)keyboardID;
- (float)brightnessForKeyboard:(unsigned long long)keyboardID;
- (float)backlightLevelForKeyboard:(unsigned long long)keyboardID;
- (BOOL)isBacklightDimmedOnKeyboard:(unsigned long long)keyboardID;
- (BOOL)isBacklightSuppressedOnKeyboard:(unsigned long long)keyboardID;
- (BOOL)isBacklightSaturatedOnKeyboard:(unsigned long long)keyboardID;
@end

static NSString *const kCoreBrightnessPath =
    @"/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness";

static BOOL LLLoadCoreBrightness(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen(kCoreBrightnessPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) != NULL;
    });
    return loaded;
}

@implementation LLCoreBrightness {
    BrightnessSystemClient *_client;
    KeyboardBrightnessClient *_keyboard;
}

+ (BOOL)isAvailable {
    return LLLoadCoreBrightness() && NSClassFromString(@"BrightnessSystemClient") != Nil;
}

- (instancetype)init {
    if (![LLCoreBrightness isAvailable]) return nil;
    self = [super init];
    if (!self) return nil;
    Class clientClass = NSClassFromString(@"BrightnessSystemClient");
    _client = [[clientClass alloc] init];
    if (!_client) return nil;
    Class keyboardClass = NSClassFromString(@"KeyboardBrightnessClient");
    if (keyboardClass) _keyboard = [[keyboardClass alloc] init];
    return self;
}

- (id)propertyForKey:(NSString *)key {
    if (![_client respondsToSelector:@selector(copyPropertyForKey:)]) return nil;
    return [_client copyPropertyForKey:key];
}

- (BOOL)setProperty:(id)value forKey:(NSString *)key {
    // Hard stop: this key makes the display module blank the built-in display.
    if ([key isEqualToString:@"DisplayPowerStateEvent"]) return NO;
    if (![_client respondsToSelector:@selector(setProperty:forKey:)]) return NO;
    return [_client setProperty:value forKey:key];
}

- (void)observeKeys:(NSArray<NSString *> *)keys handler:(void (^)(NSString *, id))handler {
    if (![_client respondsToSelector:@selector(registerNotificationBlock:forProperties:)]) return;
    [_client registerNotificationBlock:^(id key, id value) {
        handler([key description], value);
    } forProperties:keys];
}

#pragma mark Keyboard

- (NSArray<NSNumber *> *)keyboardBacklightIDs {
    if (![_keyboard respondsToSelector:@selector(copyKeyboardBacklightIDs)]) return @[];
    NSArray *ids = [_keyboard copyKeyboardBacklightIDs];
    return ids ?: @[];
}

- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isKeyboardBuiltIn:)]) return NO;
    return [_keyboard isKeyboardBuiltIn:keyboardID];
}

- (float)keyboardBrightness:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(brightnessForKeyboard:)]) return 0;
    return [_keyboard brightnessForKeyboard:keyboardID];
}

- (float)keyboardBacklightLevel:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(backlightLevelForKeyboard:)]) return 0;
    return [_keyboard backlightLevelForKeyboard:keyboardID];
}

- (BOOL)isKeyboardBacklightDimmed:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isBacklightDimmedOnKeyboard:)]) return NO;
    return [_keyboard isBacklightDimmedOnKeyboard:keyboardID];
}

- (BOOL)isKeyboardBacklightSuppressed:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isBacklightSuppressedOnKeyboard:)]) return NO;
    return [_keyboard isBacklightSuppressedOnKeyboard:keyboardID];
}

- (BOOL)isKeyboardBacklightSaturated:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isBacklightSaturatedOnKeyboard:)]) return NO;
    return [_keyboard isBacklightSaturatedOnKeyboard:keyboardID];
}

@end
