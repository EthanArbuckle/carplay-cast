#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "CRPreferences.h"

#define BAIL_IF_UNSUPPORTED_IOS { \
    if ([[[UIDevice currentDevice] systemVersion] compare:@"14.0" options:NSNumericSearch] == NSOrderedAscending) \
    { \
        return; \
    } \
}

#define LOG_LIFECYCLE_EVENT { \
    NSString *func = [NSString stringWithFormat:@"%s", __func__]; \
    if ([func containsString:@"_method$"]) \
    { \
        NSArray *components = [func componentsSeparatedByString:@"$"]; \
        func = [NSString stringWithFormat:@"[%@ %@]", components[2], components[3]]; \
    } \
    NSLog(@"LOG_LIFECYCLE_EVENT %@", func); \
}

#define getIvar(object, ivar) [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]

#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke(a, b) objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

#define assertGotExpectedObject(obj, type) if (!obj || ![obj isKindOfClass:NSClassFromString(type)]) [NSException raise:@"UnexpectedObjectException" format:@"Expected %@ but got %@", type, obj]

#define kPropertyKey_liveCarplayWindow *NSSelectorFromString(@"liveCarplayWindow")
#define kPropertyKey_lockAssertionIdentifiers *NSSelectorFromString(@"lockAssertions")
static char *kPropertyKey_didDrawPlaceholder;

// Preferences
#define PREFERENCES_PLIST_PATH @"/var/mobile/Library/Preferences/com.carplayenable.preferences.plist"
#define PREFERENCES_CHANGED_NOTIFICATION @"com.carplay.preferences.changed"
#define PREFERENCES_APP_DATA_NOTIFICATION @"com.carplay.prefs.app_data"
#define kPrefsAppDataRequesting @"Requesting"
#define kPrefsAppDataReceiving @"Receiving"
#define kPrefsAppLibraryChanged @"appLibrary"
#define kPrefsDockAlignmentChanged @"dockAlignment"
#define kPrefsIconLayoutChanged @"iconLayout"

#define CARPLAY_DOCK_WIDTH 40

extern int (*orig_BKSDisplayServicesSetScreenBlanked)(int);