#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "CRPreferences.h"
#include <substrate.h>

#define MIN_SUPPORTED_IOS_MAJOR 16
#define MAX_SUPPORTED_IOS_MAJOR 16

#define BAIL_IF_UNSUPPORTED_IOS { \
    NSInteger majorVersion = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion; \
    if (majorVersion < MIN_SUPPORTED_IOS_MAJOR || majorVersion > MAX_SUPPORTED_IOS_MAJOR) { \
        NSLog(@"Unsupported iOS version: %ld.x (supported: %d.x-%d.x)", (long)majorVersion, MIN_SUPPORTED_IOS_MAJOR, MAX_SUPPORTED_IOS_MAJOR); \
        return; \
    } \
}

#define LOG_LIFECYCLE_EVENT { \
    NSString *func = [NSString stringWithFormat:@"%s", __func__]; \
    if ([func containsString:@"_method$"]) \
    { \
        NSArray *components = [func componentsSeparatedByString:@"$"]; \
        NSString *className = components[2]; \
        NSMutableArray *methodComponents = [NSMutableArray array]; \
        for (NSUInteger i = 3; i < components.count; i++) { \
            [methodComponents addObject:components[i]]; \
            if (i < components.count - 1) { \
                [methodComponents addObject:@":"]; \
            } \
        } \
        NSString *formattedMethod = [methodComponents componentsJoinedByString:@""]; \
        func = [NSString stringWithFormat:@"[%@ %@]", className, formattedMethod]; \
    } \
    NSLog(@"[carplayenable] %@", func); \
}

#define getIvar(object, ivar) [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]

__unused static void LogSelectorError(id object, SEL selector) {
    NSLog(@"carplayenable error: %@ does not respond to selector %@", object, NSStringFromSelector(selector));
}

#define objcInvokeT(_obj, s, t)                                                       \
({                                                                                \
    SEL         _sel = NSSelectorFromString(s);                                   \
    Method      _m   = _obj ? class_getInstanceMethod(object_getClass(_obj), _sel) : NULL; \
    _m ? ((t (*)(id, SEL))objc_msgSend)(_obj, _sel) : (LogSelectorError(_obj, _sel), (t)0); \
})

#define objcInvoke(a, b) objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

#define assertGotExpectedObject(obj, type) if (!obj || ![obj isKindOfClass:NSClassFromString(type)]) [NSException raise:@"UnexpectedObjectException" format:@"Expected %@ but got %@", type, obj]

#define kPropertyKey_liveCarplayWindow *NSSelectorFromString(@"liveCarplayWindow")
#define kPropertyKey_lockAssertionIdentifiers *NSSelectorFromString(@"lockAssertions")
static char *kPropertyKey_didDrawPlaceholder;

// Preferences
#define PREFERENCES_PLIST_PATH @"/var/jb/Library/Preferences/com.carplayenable.preferences.plist"
#define PREFERENCES_CHANGED_NOTIFICATION @"com.carplay.preferences.changed"
#define PREFERENCES_APP_DATA_NOTIFICATION @"com.carplay.prefs.app_data"
#define kPrefsAppDataRequesting @"Requesting"
#define kPrefsAppDataReceiving @"Receiving"
#define kPrefsAppLibraryChanged @"appLibrary"
#define kPrefsDockAlignmentChanged @"dockAlignment"
#define kPrefsIconLayoutChanged @"iconLayout"

#define CARPLAY_DOCK_WIDTH 40

extern int (*orig_BKSDisplayServicesSetScreenBlanked)(int);