#include "../common.h"
#include "../CRCarplayWindow.h"
#include "../crash_reporting/reporting.h"


/*
Injected into SpringBoard.
*/
%group SPRINGBOARD

int (*orig_BKSDisplayServicesSetScreenBlanked)(int);

/*
Prevent app from dying when the device locks
*/
%hook SBSuspendedUnderLockManager

/*
Invoked when the device is being locked while applications are running/active
*/
- (int)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    BOOL shouldBackground = %orig;
    if (shouldBackground)
    {
        // This app is going to be backgrounded, If there is an active lock-prevention assertion for it, prevent the backgrounding.
        // This keeps CarPlay apps interactive when the device locks
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(arg2, @"client"), @"process"), @"bundleIdentifier");
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        if ([lockAssertions containsObject:sceneAppBundleID])
        {
            LOG_LIFECYCLE_EVENT;
            shouldBackground = NO;
        }
    }

    return shouldBackground;
}

%end


%hook SpringBoard

/*
When an app icon is tapped on the Carplay dashboard
*/
%new
- (void)handleCarPlayLaunchNotification:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    NSString *identifier = [notification userInfo][@"identifier"];
    objcInvoke_1(self, @"launchAppOnCarplay:", identifier);
}

%new
- (void)launchAppOnCarplay:(NSString *)identifier
{
    LOG_LIFECYCLE_EVENT;
    @try
    {
        // Dismiss any apps that are already being hosted on Carplay
        id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
        if (liveCarplayWindow != nil)
        {
            objcInvoke(liveCarplayWindow, @"dismiss");
        }

        // Launch the requested app
        liveCarplayWindow = [[CRCarPlayWindow alloc] initWithBundleIdentifier:identifier];
        objc_setAssociatedObject(self, &kPropertyKey_liveCarplayWindow, liveCarplayWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @catch (NSException *exception)
    {
        NSLog(@"carplay window launch failed! %@", exception);
    }
}

/*
Invoked when SpringBoard finishes launching
*/
- (void)applicationDidFinishLaunching:(id)arg1
{
    LOG_LIFECYCLE_EVENT;
    // Setup to receive App Launch notifications from the CarPlay process
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.carplayenable" object:nil];

    // Receive notifications for Carplay connect/disconnect events. When a Carplay screen becomes unavailable while an app is being hosted on it, that app window needs to be closed
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(carplayIsConnectedChanged) name:@"CarPlayIsConnectedDidChange" object:nil];

    NSMutableArray *appIdentifiersToIgnoreLockAssertions = [[NSMutableArray alloc] init];
    objc_setAssociatedObject(self, &kPropertyKey_lockAssertionIdentifiers, appIdentifiersToIgnoreLockAssertions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig;

    NSOperationQueue *notificationQueue = [[NSOperationQueue alloc] init];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataRequesting queue:notificationQueue usingBlock:^(NSNotification * _Nonnull note) {
        // The Preference pane is requesting a list of installed apps + icons. Gather the info
        id appController = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
        NSMutableArray *appList = [[NSMutableArray alloc] init];
        for (id appInfo in objcInvoke(appController, @"allInstalledApplications"))
        {
            NSString *identifier = objcInvoke(appInfo, @"bundleIdentifier");
            // Skip stock apps
            if (![objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] && [identifier containsString:@"com.apple."])
            {
                continue;
            }
            // Skip native-carplay apps
            if (getIvar(appInfo, @"_carPlayDeclaration") != nil)
            {
                continue;
            }

            // Grab icon data
            UIImage *appIconImage = objcInvoke_3(objc_getClass("UIImage"), @"_applicationIconImageForBundleIdentifier:format:scale:", identifier, 0, [UIScreen mainScreen].scale);
            NSData *iconImageData = UIImagePNGRepresentation(appIconImage);

            NSDictionary *appInfoDict = @{
                @"name": objcInvoke(appInfo, @"displayName"),
                @"bundleID": identifier,
                @"iconImage": iconImageData
            };
            [appList addObject:appInfoDict];

        }
        NSDictionary *replyDict = @{@"appList": appList};
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataReceiving userInfo:replyDict]];
    }];

    // Upload any relevant crashlogs
    symbolicateAndUploadCrashlogs();
}

%new
- (id)liveCarplayWindow
{
    return objc_getAssociatedObject(self, &kPropertyKey_liveCarplayWindow);
}

/*
A Carplay connected/disconnected event
*/
%new
- (void)carplayIsConnectedChanged
{
    LOG_LIFECYCLE_EVENT;
    // If a window is being hosted, and the carplay radio disconnected, close the window
    id liveCarplayWindow = objcInvoke(self, @"liveCarplayWindow");
    if (liveCarplayWindow && !getCarplayCADisplay())
    {
        dispatch_sync(dispatch_get_main_queue(), ^(void) {
            objcInvoke(liveCarplayWindow, @"dismiss");
        });
    }
}

%end

%hook SBSceneView

/*
This is invoked when transformations are applied to a Carplay Hosted window. It crashes if those transformations
happen while the device is in a faceup/facedown orientation.
*/
- (void)_updateReferenceSize:(struct CGSize)arg1 andOrientation:(long long)arg2
{
    // Scene views do not support Face-Up/Face-Down orientations - it will raise an exception if attempted.
    // If the device is in a restricted orientation, override to landscape (3). This doesn't really matter because
    // the app's content will be unconditionally forced to landscape when it becomes live.
    if (arg2 > 4)
    {
        return %orig(arg1, 3);
    }
    %orig;
}

%end

%hook FBScene

/*
Called when something is trying to change a scene's settings (including sending it to background/foreground).
Use this to prevent the App from going to sleep when other applications are launched on the main screen.
*/
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(void *)arg3
{
    id sceneClient = objcInvoke(self, @"client");
    if ([sceneClient respondsToSelector:NSSelectorFromString(@"process")])
    {
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(sceneClient, @"process"), @"bundleIdentifier");
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        if ([lockAssertions containsObject:sceneAppBundleID])
        {
            if (objcInvokeT(arg1, @"isForeground", BOOL) == NO)
            {
                return;
            }
        }
    }

    %orig;
}

%end

%hook SBMainSwitcherViewController

/*
The app switcher matches the orientation of the frontmost app. When an app is on Carplay, this could be different
than the device orientation. Force the switcher to use the device's physical orientation when a Carplay-hosted app is frontmost
*/
- (void)_updateContentViewInterfaceOrientation:(int)arg1
{
    if (objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow") != nil)
    {
        LOG_LIFECYCLE_EVENT;
        // Match the device orientation instead of app orientation
        int deviceOrientation = [[UIDevice currentDevice] orientation];
        return %orig(deviceOrientation);
    }

    return %orig;
}

%end

%hook SBDeviceApplicationSceneView

/*
Is this a main-screen scene view for an application that is being hosted on the Carplay screen?
*/
%new
- (BOOL)isMainScreenCounterpartToLiveCarplayApp
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow != nil)
    {
        id liveAppViewController = [liveCarplayWindow appViewController];
        id carplaySceneHandle = objcInvoke(liveAppViewController, @"sceneHandle");
        if ([carplaySceneHandle isEqual:objcInvoke(self, @"sceneHandle")])
        {
            LOG_LIFECYCLE_EVENT;
            id carplayAppViewController = getIvar(liveAppViewController, @"_deviceAppViewController");
            id carplayAppSceneView = objcInvoke(carplayAppViewController, @"_sceneView");
            return carplayAppSceneView && [self isEqual:carplayAppSceneView] == NO;
        }
    }

    return NO;
}

- (void)layoutSubviews
{
    %orig;
    BOOL isCarplayCounterpart = objcInvokeT(self, @"isMainScreenCounterpartToLiveCarplayApp", BOOL);
    if (isCarplayCounterpart)
    {
        LOG_LIFECYCLE_EVENT;
        int currentDisplayMode = objcInvokeT(self, @"displayMode", int);
        BOOL isHostingAnApp = currentDisplayMode == 4;
        if (isHostingAnApp)
        {
            // Only interested in forcing the layout when this scene is in CustomContent/Placeholder mode
            return;
        }

        // The placeholder view will try to match the orientation of the application, which if running on Carplay may not match the orientation of the main screen.
        // Force the UI to match the main screens orientation. This will end up calling -layoutSubviews again
        objcInvoke(self, @"rotateToDeviceOrientation");

        UIView *backgroundView = objcInvoke(self, @"backgroundView");
        int deviceOrientation = [[UIDevice currentDevice] orientation];
        // Draw the Carplay placeholder UI, but only if this view is being layed out in the correct orientation.
        // It is expected that this method will be called at least once while the view is in the wrong orientation
        BOOL bgIsLandscape = [backgroundView frame].size.width > [backgroundView frame].size.height;
        BOOL deviceIsLandscape = UIInterfaceOrientationIsLandscape(deviceOrientation);
        if (bgIsLandscape == deviceIsLandscape)
        {
            // Orientation expectation satisfied
            objcInvoke(self, @"drawCarplayPlaceholder");
        }
    }
}

/*
This scene view (and its background view, which the custom ui is drawn on) rotates automatically with the app's orientation changes.
Because the app's orientation may not match the device's real orientation, this view may be layed out incorrectly for the main screen.
Walk superviews looking for the view that handles orientation changes, and force it to match the physical device orientation
*/
%new
- (void)rotateToDeviceOrientation
{
    UIView *backgroundView = objcInvoke(self, @"backgroundView");

    id orientationTransformedView = nil;
    id _candidate = [backgroundView superview];
    while (_candidate != nil)
    {
        if (_candidate && [_candidate isKindOfClass:objc_getClass("SBOrientationTransformWrapperView")])
        {
            orientationTransformedView = _candidate;
            break;
        }

        _candidate = [_candidate superview];
    }

    if (orientationTransformedView != nil)
    {
        int deviceOrientation = [[UIDevice currentDevice] orientation];
        objcInvoke_1(orientationTransformedView, @"setContentOrientation:", deviceOrientation);
    }
}

/*
An app can only run on 1 screen at a time. If an App is launched on the main screen while also being hosted on
the carplay screen, the mainscreen will show a blurred background with a label.
*/
%new
- (void)drawCarplayPlaceholder
{
    LOG_LIFECYCLE_EVENT;
    int deviceOrientation = [[UIDevice currentDevice] orientation];
    // The background view may have already been drawn on. Use an associated object to determine if its already been handled for this orientation
    // If it was drawn for a different orientation, start fresh
    UIView *backgroundView = objcInvoke(self, @"backgroundView");
    id _drawnForOrientation = objc_getAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder);
    int drawnForOrientation = (_drawnForOrientation) ? [_drawnForOrientation intValue] : -1;
    if (drawnForOrientation != deviceOrientation)
    {
        // Needs to be created. If it was already made, remove the label subview
        if (drawnForOrientation > 0)
        {
            for (UIView *subview in [backgroundView subviews])
            {
                if ([subview isKindOfClass:objc_getClass("UILabel")])
                {
                    [subview removeFromSuperview];
                }
            }
        }

        // Set associated object to avoid redrawing if no orientation changes have happened
        objc_setAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder, @(deviceOrientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // [[UIScreen mainscreen] bounds] may not be using the correct orientation. Get screen bounds for explicit orientation
        CGRect screenBounds = ((CGRect (*)(id, SEL, int))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"boundsForOrientation:"), deviceOrientation);

        UILabel *hostedOnCarplayLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 300, screenBounds.size.width, 50)];
        [hostedOnCarplayLabel setText:@"Running on CarPlay Screen"];
        [hostedOnCarplayLabel setTextAlignment:NSTextAlignmentCenter];
        [hostedOnCarplayLabel setFont:[UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]];
        [hostedOnCarplayLabel setCenter:[backgroundView center]];
        [backgroundView addSubview:hostedOnCarplayLabel];
    }

    // Wallpaper style to a nice blur
    objcInvoke_1(backgroundView, @"setWallpaperStyle:", 18);

    // Set mode to Placeholder (makes the backgroundView become visible)
    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    objcInvoke_3(self, @"setDisplayMode:animationFactory:completion:", 1, animationFactory, nil);
}

/*
Display mode is being changed.
The relevant modes for this tweak are LiveContent (interactive app) and Placeholder (usually a blackscreen, but we'll pretty it up)
*/
- (void)setDisplayMode:(int)arg1 animationFactory:(id)arg2 completion:(void *)arg3
{
    BOOL isCarplayCounterpart = objcInvokeT(self, @"isMainScreenCounterpartToLiveCarplayApp", BOOL);
    BOOL requestingLiveContent = arg1 == 4;
    if (requestingLiveContent && isCarplayCounterpart)
    {
        LOG_LIFECYCLE_EVENT;
        // An app is being opened on the mainscreen while already running on the carplay screen.
        // Force the display mode to Placeholder instead of LiveContent
        %orig(1, arg2, arg3);
        return;
    }

    %orig;
}

%end

%hook UIScreen

%new
- (CGRect)boundsForOrientation:(int)orientation
{
    CGFloat width = [self bounds].size.width;
    CGFloat height = [self bounds].size.height;

    CGRect bounds = CGRectZero;
    if (UIInterfaceOrientationIsLandscape(orientation))
    {
        bounds.size = CGSizeMake(MAX(width, height), MIN(width, height));
    }
    else
    {
        bounds.size = CGSizeMake(MIN(width, height), MAX(width, height));
    }

    return bounds;
}

%end

/*
Called when the device's main screen is turning on or off
*/
int hook_BKSDisplayServicesSetScreenBlanked(int arg1)
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (arg1 == 1 && liveCarplayWindow != nil)
    {
        LOG_LIFECYCLE_EVENT;
        // The device's screen is turning off while an app is hosted on the carplay display
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);

        id sceneHandle = objcInvoke([liveCarplayWindow appViewController], @"sceneHandle");
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        if (appScene)
        {
            NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
            if ([lockAssertions containsObject:sceneAppBundleID])
            {
                // Turn the screen off as originally intended
                orig_BKSDisplayServicesSetScreenBlanked(1);

                // Wait for the events to propagate through the system, then undo it (doing this too early doesn't work).
                // This does not actually turn the display on
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    orig_BKSDisplayServicesSetScreenBlanked(0);
                });
                return 0;
            }
        }
    }

    return orig_BKSDisplayServicesSetScreenBlanked(arg1);
}

%end

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
    {
        %init(SPRINGBOARD);
        // Hook BKSDisplayServicesSetScreenBlanked() - necessary for allowing animations/video when the screen is off
        void *_BKSDisplayServicesSetScreenBlanked = dlsym(dlopen(NULL, 0), "BKSDisplayServicesSetScreenBlanked");
        MSHookFunction(_BKSDisplayServicesSetScreenBlanked, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    }
}