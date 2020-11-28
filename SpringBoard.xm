#include "common.h"

/*
Injected into SpringBoard.
*/
%group SPRINGBOARD

id currentlyHostedAppController = nil;
int (*orig_BKSDisplayServicesSetScreenBlanked)(int);

/*
Find the CADisplay handling the CarPlay stuff
*/
id getCarplayCADisplay(void)
{
    id carplayAVDisplay = objcInvoke(objc_getClass("AVExternalDevice"), @"currentCarPlayExternalDevice");
    if (!carplayAVDisplay)
    {
        return nil;
    }

    NSString *carplayDisplayUniqueID = objcInvoke(carplayAVDisplay, @"screenIDs")[0];
    for (id display in objcInvoke(objc_getClass("CADisplay"), @"displays"))
    {
        if ([carplayDisplayUniqueID isEqualToString:objcInvoke(display, @"uniqueId")])
        {
            return display;
        }
    }
    return nil;
}

/*
Prevent app from dying when the device locks
*/
%hook SBSuspendedUnderLockManager

/*
Invoked when the device is being locked while applications are running/active
*/
- (int)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    BOOL shouldBackground  = %orig;
    if (shouldBackground)
    {
        // This app is going to be backgrounded, If there is an active lock-prevention assertion for it, prevent the backgrounding.
        // This keeps CarPlay apps interactive when the device locks
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(arg2, @"client"), @"process"), @"bundleIdentifier");
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        if ([lockAssertions containsObject:sceneAppBundleID])
        {
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
    @try
    {
        NSString *identifier = [notification userInfo][@"identifier"];
        id targetApp = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
        assertGotExpectedObject(targetApp, @"SBApplication");

        id carplayExternalDisplay = getCarplayCADisplay();
        assertGotExpectedObject(carplayExternalDisplay, @"CADisplay");

        NSMutableArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        [lockAssertions addObject:identifier];

        id displayConfiguration = objcInvoke_2([objc_getClass("FBSDisplayConfiguration") alloc], @"initWithCADisplay:isMainDisplay:", carplayExternalDisplay, 0);
        assertGotExpectedObject(displayConfiguration, @"FBSDisplayConfiguration");

        id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
        assertGotExpectedObject(displaySceneManager, @"SBMainDisplaySceneManager");

        id sceneLayoutManager = objcInvoke(displaySceneManager, @"_layoutStateManager");
        assertGotExpectedObject(sceneLayoutManager, @"SBMainDisplayLayoutStateManager");

        id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");
        assertGotExpectedObject(mainScreenIdentity, @"FBSDisplayIdentity");

        id sceneIdentity = objcInvoke_2(displaySceneManager, @"_sceneIdentityForApplication:createPrimaryIfRequired:", targetApp, 1);
        assertGotExpectedObject(sceneIdentity, @"FBSSceneIdentity");

        id sceneHandleRequest = objcInvoke_3(objc_getClass("SBApplicationSceneHandleRequest"), @"defaultRequestForApplication:sceneIdentity:displayIdentity:", targetApp, sceneIdentity, mainScreenIdentity);
        assertGotExpectedObject(sceneHandleRequest, @"SBApplicationSceneHandleRequest");

        id sceneHandle = objcInvoke_1(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
        assertGotExpectedObject(sceneHandle, @"SBDeviceApplicationSceneHandle");

        id appSceneEntity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
        assertGotExpectedObject(appSceneEntity, @"SBDeviceApplicationSceneEntity");

        id appViewController = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", identifier, appSceneEntity);
        assertGotExpectedObject(appViewController, @"SBAppViewController");
        objcInvoke_1(appViewController, @"setIgnoresOcclusions:", 0);
        setIvar(appViewController, @"_currentMode", @(2));
        objcInvoke(getIvar(appViewController, @"_activationSettings"), @"clearActivationSettings");

        id sceneUpdateTransaction = objcInvoke_2(appViewController, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", appSceneEntity, 1);
        assertGotExpectedObject(sceneUpdateTransaction, @"SBApplicationSceneUpdateTransaction");

        __block UIImageView *launchImageView = nil;
        __block NSMutableArray *transactions = getIvar(appViewController, @"_activeTransitions");
        objcInvoke_1(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {

            [transactions removeObject:sceneUpdateTransaction];

            id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
            assertGotExpectedObject(processLaunchTransaction, @"FBApplicationProcessLaunchTransaction");

            id appProcess = objcInvoke(processLaunchTransaction, @"process");
            assertGotExpectedObject(appProcess, @"FBProcess");

            objcInvoke_1(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
                // Ask the app to rotate to landscape
                [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:identifier userInfo:@{@"orientation": @(3)}];

                // Wait a sec then remove the splashscreen image. It should already be hidden/covered by the live app view, but it needs to be removed
                // so it doesn't poke through if the App's orientation changes to portait
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [launchImageView removeFromSuperview];
                });
            });
        });

        [transactions addObject:sceneUpdateTransaction];
        objcInvoke(sceneUpdateTransaction, @"begin");
        objcInvoke(appViewController, @"_createSceneViewController");

        id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
        assertGotExpectedObject(animationFactory, @"BSUIAnimationFactory");

        id appView = objcInvoke(appViewController, @"appView");
        objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, animationFactory, 0);
        [[appViewController view] setBackgroundColor:[UIColor clearColor]];

        // Create a scene monitor to watch for the app process dying. The carplay window will dismiss itself
        NSString *sceneID = objcInvoke_1(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:", identifier);
        id sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
        [sceneMonitor setDelegate:appViewController];
        objc_setAssociatedObject(appViewController, &kPropertyKey_sceneMonitor, sceneMonitor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIWindow *rootWindow = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);
        CGRect rootWindowFrame = [rootWindow frame];

        // Add the user's wallpaper to the window. It will be visible when the app is in portrait mode
        UIImageView *wallpaperImageView = [[UIImageView alloc] initWithFrame:rootWindowFrame];
        id defaultWallpaper = objcInvoke(objc_getClass("CRSUIWallpaperPreferences"), @"defaultWallpaper");
        assertGotExpectedObject(defaultWallpaper, @"CRSUIWallpaper");

        UIImage *wallpaperImage = objcInvoke_1(defaultWallpaper, @"wallpaperImageCompatibleWithTraitCollection:", nil);
        [wallpaperImageView setImage:wallpaperImage];
        [rootWindow addSubview:wallpaperImageView];

        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(40, rootWindowFrame.origin.y, rootWindowFrame.size.width - 40, rootWindowFrame.size.height)];
        [container setBackgroundColor:[UIColor clearColor]];
        [rootWindow addSubview:container];

        // The scene does not show a launch image, it needs to be created manually.
        // Fetch a snapshot to use
        id launchImageSnapshotManifest = objcInvoke_1([objc_getClass("XBApplicationSnapshotManifest") alloc], @"initWithApplicationInfo:", objcInvoke(targetApp, @"info"));
        NSString *defaultGroupID = objcInvoke(launchImageSnapshotManifest, @"defaultGroupIdentifier");
        // There's a few variants of snapshots offered: portait/landscape, dark/light.
        // For now just try to find a landscape snapshot. If no landscape, fallback to portait.
        // TODO: generate a landscape snapshot after first carplay launch to use on next cold-launch
        NSArray *snapshots = objcInvoke_1(launchImageSnapshotManifest, @"snapshotsForGroupID:", defaultGroupID);
        id appSnapshot = nil;
        for (id snapshotCandidate in snapshots)
        {
            int snapshotOrientation = objcInvokeT(snapshotCandidate, @"interfaceOrientation", int);
            if (UIInterfaceOrientationIsLandscape(snapshotOrientation))
            {
                // Prefer a landscape image, but not all apps will have one available
                appSnapshot = snapshotCandidate;
                break;
            }
            // Not landscape but better than nothing
            appSnapshot = snapshotCandidate;
        }
        // Get the image from the chosen snapshot
        id appSnapshotImage = objcInvoke_1(appSnapshot, @"imageForInterfaceOrientation:", 1);

        // Build an imageview to contain the launch image.
        // The processLaunched handler defined above is responsible for cleaning this up
        launchImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, [container frame].size.width, [container frame].size.height)];
        [launchImageView setImage:appSnapshotImage];
        [container addSubview:launchImageView];

        // Add the live app view
        [container addSubview:objcInvoke(appViewController, @"view")];

        UIView *sidebarView = [[UIView alloc] initWithFrame:CGRectMake(0, rootWindowFrame.origin.y, 40, rootWindowFrame.size.height)];
        [sidebarView setBackgroundColor:[UIColor lightGrayColor]];
        [rootWindow addSubview:sidebarView];

        id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40];

        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
        [closeButton addTarget:appViewController action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
        [closeButton setFrame:CGRectMake(0, 10, 35.0, 35.0)];
        [closeButton setTintColor:[UIColor blackColor]];
        [sidebarView addSubview:closeButton];

        UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
        [rotateButton addTarget:appViewController action:@selector(handleRotate) forControlEvents:UIControlEventTouchUpInside];
        [rotateButton setFrame:CGRectMake(0, rootWindowFrame.size.height - 45, 35.0, 35.0)];
        [rotateButton setTintColor:[UIColor blackColor]];
        [sidebarView addSubview:rotateButton];

        objcInvoke_1(appViewController, @"resizeHostedAppForCarplayDisplay:", 3);
        [rootWindow setAlpha:0];
        [rootWindow setHidden:0];

        // "unblank" the screen. This is necessary for animations/video to render when the device is locked.
        // This does not cause the screen to actually light up
        orig_BKSDisplayServicesSetScreenBlanked(0);

        [UIView animateWithDuration:1.0 animations:^(void)
        {
            [rootWindow setAlpha:1];
        } completion:nil];

        // Add a placeholder "this app is on the carplay screen" view onto the app on the main screen
        id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
        id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
        for (id appSceneLayoutController in liveAppSceneControllers)
        {
            id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
            id appSceneView = objcInvoke(appSceneController, @"_sceneView");
            id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
            if ([appSceneHandle isEqual:sceneHandle])
            {
                objcInvoke(appSceneView, @"drawCarplayPlaceholder");
            }
        }

        currentlyHostedAppController = appViewController;
    }
    @catch (NSException *exception)
    {
        NSLog(@"failed! %@", exception);
    }
}

/*
Invoked when SpringBoard finishes launching
*/
- (void)applicationDidFinishLaunching:(id)arg1
{
    // Setup to receive App Launch notifications from the CarPlay process
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.ethanarbuckle.carplayenable" object:nil];

    NSMutableArray *appIdentifiersToIgnoreLockAssertions = [[NSMutableArray alloc] init];
    objc_setAssociatedObject(self, &kPropertyKey_lockAssertionIdentifiers, appIdentifiersToIgnoreLockAssertions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig;
}

%end


%hook SBAppViewController

/*
FBSceneMonitor delegate method, invoked when the app process dies.
Use this to close the window on the CarPlay screen if the app crashes or is killed via the App Switcher on main screen
*/
%new
- (void)sceneMonitor:(id)arg1 sceneWasDestroyed:(id)arg2
{
    // Close the window
    objcInvoke(self, @"dismiss");
}

/*
When a CarPlay App is closed
*/
%new
- (void)dismiss
{
    // Invalidate the scene monitor
    id sceneMonitor = objc_getAssociatedObject(currentlyHostedAppController, &kPropertyKey_sceneMonitor);
    [sceneMonitor invalidate];

    currentlyHostedAppController = nil;
    __block id rootWindow = [[[self view] superview] superview];

    void (^cleanupAfterCarplay)() = ^() {
        int resetOrientationLock = -1;
        NSString *hostedIdentifier = getIvar(self, @"_identifier");
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:hostedIdentifier userInfo:@{@"orientation": @(resetOrientationLock)}];

        objcInvoke_1(rootWindow, @"setHidden:", 1);
        objcInvoke_1(self, @"_setCurrentMode:", 0);
        [[self view] removeFromSuperview];

        id currentSceneHandle = objcInvoke(self, @"sceneHandle");
        id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
        id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
        for (id appSceneLayoutController in liveAppSceneControllers)
        {
            id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
            id appSceneView = objcInvoke(appSceneController, @"_sceneView");
            id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
            if ([appSceneHandle isEqual:currentSceneHandle])
            {
                objcInvoke_3(appSceneView, @"setDisplayMode:animationFactory:completion:", 4, nil, nil);
            }
        }

        id sharedApp = [UIApplication sharedApplication];

        // After the scene returns to the device, release the assertion that prevents suspension
        NSMutableArray *lockAssertions = objc_getAssociatedObject(sharedApp, &kPropertyKey_lockAssertionIdentifiers);
        id appScene = objcInvoke(objcInvoke(self, @"sceneHandle"), @"sceneIfExists");
        if (appScene != nil)
        {
            NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
            [lockAssertions removeObject:sceneAppBundleID];

            // Send the app to the background *if it is not on the main screen*
            id frontmostApp = objcInvoke(sharedApp, @"_accessibilityFrontMostApplication");
            BOOL isAppOnMainScreen = frontmostApp && [objcInvoke(frontmostApp, @"bundleIdentifier") isEqualToString:sceneAppBundleID];
            if (!isAppOnMainScreen)
            {
                id sceneSettings = objcInvoke(appScene, @"mutableSettings");
                objcInvoke_1(sceneSettings, @"setBackgrounded:", 1);
                objcInvoke_1(sceneSettings, @"setForeground:", 0);
                ((void (*)(id, SEL, id, id, void *))objc_msgSend)(appScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), sceneSettings, nil, 0);
            }
        }

        // If the device is locked, set the screen state to off
        if (objcInvokeT(sharedApp, @"isLocked", BOOL) == YES)
        {
            orig_BKSDisplayServicesSetScreenBlanked(1);
        }

        rootWindow = nil;
        // todo: resign first responder (kb causes glitches on return)
    };

    [UIView animateWithDuration:0.2 animations:^(void)
    {
        [rootWindow setAlpha:0];
    } completion:^(BOOL a)
    {
        cleanupAfterCarplay();
    }];
}

/*
When the "rotate orientation" button is pressed on a CarplayEnabled app window
*/
%new
- (void)handleRotate
{
    id _lastOrientation = objc_getAssociatedObject(self, &kPropertyKey_lastKnownOrientation);
    int lastOrientation = (_lastOrientation) ? [_lastOrientation intValue] : -1;
    int desiredOrientation = (UIInterfaceOrientationIsLandscape(lastOrientation)) ? 1 : 3;

    id appScene = objcInvoke(objcInvoke(currentlyHostedAppController, @"sceneHandle"), @"sceneIfExists");
    NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:sceneAppBundleID userInfo:@{@"orientation": @(desiredOrientation)}];
    objcInvoke_1(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay:", desiredOrientation);
}

/*
Handle resizing the Carplay App window. Called anytime the app orientation changes (including first appearance)
*/
%new
- (void)resizeHostedAppForCarplayDisplay:(int)desiredOrientation
{
    id _lastOrientation = objc_getAssociatedObject(self, &kPropertyKey_lastKnownOrientation);
    int lastOrientation = (_lastOrientation) ? [_lastOrientation intValue] : -1;
    if (desiredOrientation == lastOrientation)
    {
        return;
    }

    id appSceneView = getIvar(getIvar(self, @"_deviceAppViewController"), @"_sceneView");
    assertGotExpectedObject(appSceneView, @"SBSceneView");
    UIView *hostingContentView = getIvar(appSceneView, @"_sceneContentContainerView");

    UIScreen *carplayScreen = [[UIScreen screens] lastObject];
    if (objcInvokeT(carplayScreen, @"_isCarScreen", BOOL) == NO)
    {
        return;
    }
    CGRect carplayDisplayBounds = [carplayScreen bounds];
    CGSize carplayDisplaySize = CGSizeMake(carplayDisplayBounds.size.width - 40, carplayDisplayBounds.size.height);

    CGSize mainScreenSize = ((CGRect (*)(id, SEL, int))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"boundsForOrientation:"), desiredOrientation).size;

    id rootWindow = [[[self view] superview] superview];

    CGFloat widthScale = carplayDisplaySize.width / mainScreenSize.width;
    CGFloat heightScale = carplayDisplaySize.height / mainScreenSize.height;
    CGFloat xOrigin = [rootWindow frame].origin.x;

    // Special scaling when in portrait mode (because the carplay screen is always physically landscape)
    if (UIInterfaceOrientationIsPortrait(desiredOrientation))
    {
        // Use half the display's width
        widthScale = (carplayDisplaySize.width / 2) / mainScreenSize.width;
        // Center it
        CGFloat scaledDisplayWidth = carplayDisplaySize.width * widthScale;
        xOrigin = (carplayDisplaySize.width / 2) - (scaledDisplayWidth / 2);
    }

    [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
    [[self view] setFrame:CGRectMake(xOrigin, [[self view] frame].origin.y, carplayDisplaySize.width, carplayDisplaySize.height)];

    // Update last known orientation
    objc_setAssociatedObject(self, &kPropertyKey_lastKnownOrientation, @(desiredOrientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    if ([sceneClient respondsToSelector:NSSelectorFromString(@"process")]) {
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


%hook SBDeviceApplicationSceneView

/*
Is this a main-screen scene view for an application that is being hosted on the Carplay screen?
*/
%new
- (BOOL)isMainScreenCounterpartToLiveCarplayApp
{
    if (currentlyHostedAppController != nil)
    {
        id currentSceneHandle = objcInvoke(self, @"sceneHandle");
        id carplaySceneHandle = objcInvoke(currentlyHostedAppController, @"sceneHandle");
        if ([currentSceneHandle isEqual:carplaySceneHandle])
        {
            id carplayAppViewController = getIvar(currentlyHostedAppController, @"_deviceAppViewController");
            id carplayAppSceneView = objcInvoke(carplayAppViewController, @"_sceneView");
            return [self isEqual:carplayAppSceneView] == NO;
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
    if (arg1 == 1 && currentlyHostedAppController != nil)
    {
        // The device's screen is turning off while an app is hosted on the carplay display
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        id appScene = objcInvoke(objcInvoke(currentlyHostedAppController, @"sceneHandle"), @"sceneIfExists");
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

    return orig_BKSDisplayServicesSetScreenBlanked(arg1);
}

%end

%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"])
    {
        %init(SPRINGBOARD);
        // Hook BKSDisplayServicesSetScreenBlanked() - necessary for allowing animations/video when the screen is off
        void *_BKSDisplayServicesSetScreenBlanked = dlsym(dlopen(NULL, 0), "BKSDisplayServicesSetScreenBlanked");
        MSHookFunction(_BKSDisplayServicesSetScreenBlanked, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    }
}