#include "common.h"

/*
Injected into User Applications
*/
%group APPS

static int orientationOverride = -1;

%hook UIApplication

/*
When the app is launched
*/
- (id)init
{
    id _self = %orig;
    // Register for "orientation change" notifications
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleRotationRequest:") name:@"com.ethanarbuckle.carplayenable.orientation" object:[[NSBundle mainBundle] bundleIdentifier]];
    return _self;
}

/*
When Carplay window is requesting the app to rotate
*/
%new
- (void)handleRotationRequest:(id)notification
{
    orientationOverride = [objcInvoke(notification, @"userInfo")[@"orientation"] intValue];

    int orientationToRequest = orientationOverride;
    if (orientationToRequest == -1)
    {
        orientationToRequest = [[UIDevice currentDevice] orientation];
        // sometimes 0?
        orientationToRequest = MAX(1, orientationToRequest);
    }

    // might not be created yet...
    UIWindow *keyWindow = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    objcInvoke_3(keyWindow, @"_setRotatableViewOrientation:duration:force:", orientationToRequest, 0, 1);
}

%end

/*
Called when a window intends to rotate to a new orientation. Used to force landscape/portrait
*/
%hook UIWindow

- (void)_setRotatableViewOrientation:(int)orientation duration:(float)duration force:(int)force
{
    if (orientationOverride > 0)
    {
        return %orig(orientationOverride, duration, force);
    }
    %orig;
}

%end

%end

%ctor {
    // Only need to inject into Apps, not daemons
    if ([[[NSBundle mainBundle] bundlePath] containsString:@".app"])
    {
        // Ignore system apps (carplay and springboard)
        if (objcInvokeT([UIApplication sharedApplication], @"isFrontBoard", BOOL) == NO)
        {
            %init(APPS);
        }
    }
}