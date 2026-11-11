#import "CoreBrightnessBridge.h"
#import <dlfcn.h>

// Private interfaces, declared here only so ARC knows the ownership rules
// (`copy…` methods return +1 objects). Verified against macOS 27.2 (Mac17,12).
@interface BrightnessSystemClient : NSObject
- (nullable id)copyPropertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
@end

@interface KeyboardBrightnessClient : NSObject
- (nullable NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)keyboardID;
- (BOOL)isBacklightDimmedOnKeyboard:(unsigned long long)keyboardID;
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

+ (instancetype)connect {
    if (![LLCoreBrightness isAvailable]) return nil;
    BrightnessSystemClient *client = [[NSClassFromString(@"BrightnessSystemClient") alloc] init];
    if (!client) return nil;
    LLCoreBrightness *bridge = [[LLCoreBrightness alloc] initPrivate];
    bridge->_client = client;
    bridge->_keyboard = [[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
    return bridge;
}

- (instancetype)initPrivate {
    return [super init];
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

- (BOOL)isKeyboardBacklightDimmed:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isBacklightDimmedOnKeyboard:)]) return NO;
    return [_keyboard isBacklightDimmedOnKeyboard:keyboardID];
}

- (BOOL)isKeyboardBacklightSaturated:(uint64_t)keyboardID {
    if (![_keyboard respondsToSelector:@selector(isBacklightSaturatedOnKeyboard:)]) return NO;
    return [_keyboard isBacklightSaturatedOnKeyboard:keyboardID];
}

@end
