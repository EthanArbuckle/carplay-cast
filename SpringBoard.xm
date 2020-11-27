#include "common.h"

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
Injected into SpringBoard.
*/
%group SPRINGBOARD

id currentlyHostedAppController = nil;
id carplayExternalDisplay = nil;
int lastOrientation = -1;
NSMutableArray *appIdentifiersToIgnoreLockAssertions = nil;
int (*orig_BKSDisplayServicesSetScreenBlanked)(int);
id sceneMonitor = nil;

/*
Prevent app from dying when the device locks
*/
%hook SBSuspendedUnderLockManager

- (int)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    BOOL shouldBackground  = %orig;
    NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(arg2, @"client"), @"process"), @"bundleIdentifier");
    if ([appIdentifiersToIgnoreLockAssertions containsObject:sceneAppBundleID] && shouldBackground)
    {
        shouldBackground = NO;
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

        carplayExternalDisplay = getCarplayCADisplay();
        assertGotExpectedObject(carplayExternalDisplay, @"CADisplay");

        [appIdentifiersToIgnoreLockAssertions addObject:identifier];

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
        sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
        [sceneMonitor setDelegate:appViewController];

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
    appIdentifiersToIgnoreLockAssertions = [[NSMutableArray alloc] init];

    %orig;
}

%end


%hook SBAppViewController

%new
- (void)sceneMonitor:(id)arg1 sceneWasDestroyed:(id)arg2{
    objcInvoke(self, @"dismiss");
}

/*
When a CarPlay App is closed
*/
%new
- (void)dismiss
{
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
        id appScene = objcInvoke(objcInvoke(self, @"sceneHandle"), @"sceneIfExists");
        if (appScene != nil)
        {
            NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
            [appIdentifiersToIgnoreLockAssertions removeObject:sceneAppBundleID];

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

        lastOrientation = resetOrientationLock;
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
    BOOL wasLandscape = lastOrientation >= 3;
    int desiredOrientation = (wasLandscape) ? 1 : 3;

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
    if (desiredOrientation == lastOrientation)
    {
        return;
    }
    lastOrientation = desiredOrientation;

    id appSceneView = getIvar(getIvar(self, @"_deviceAppViewController"), @"_sceneView");
    assertGotExpectedObject(appSceneView, @"SBSceneView");

    UIView *hostingContentView = getIvar(appSceneView, @"_sceneContentContainerView");

    CGRect displayFrame = objcInvokeT(carplayExternalDisplay, @"frame", CGRect);

    CGSize carplayDisplaySize = CGSizeMake(displayFrame.size.width - 80, displayFrame.size.height);
    CGSize mainScreenSize = [[UIScreen mainScreen] bounds].size;

    CGFloat widthScale;
    CGFloat heightScale;
    CGFloat xOrigin;

    id rootWindow = [[[self view] superview] superview];

    if (desiredOrientation == 1 || desiredOrientation == 2)
    {
        // half width, full height
        CGSize adjustedMainSize = CGSizeMake(MIN(mainScreenSize.width, mainScreenSize.height), MAX(mainScreenSize.width, mainScreenSize.height));
        widthScale = (carplayDisplaySize.width / 1.5) / (adjustedMainSize.width * 2);
        heightScale = carplayDisplaySize.height / (adjustedMainSize.height * 2);
        xOrigin = (([rootWindow frame].size.width * widthScale) / 4) + [rootWindow frame].origin.x;
    }
    else
    {
        // full width and height
        CGSize adjustedMainSize = CGSizeMake(MAX(mainScreenSize.width, mainScreenSize.height), MIN(mainScreenSize.width, mainScreenSize.height));
        widthScale = carplayDisplaySize.width / (adjustedMainSize.width * 2);
        heightScale = carplayDisplaySize.height / (adjustedMainSize.height * 2);
        xOrigin = [rootWindow frame].origin.x;
    }

    [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
    CGRect frame = [[self view] frame];
    [[self view] setFrame:CGRectMake(xOrigin, frame.origin.y, carplayDisplaySize.width, carplayDisplaySize.height)];
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
Use this to prevent the App from going to sleep when other application's are launched on the main screen.
*/
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(void *)arg3
{
    id sceneClient = objcInvoke(self, @"client");
    if ([sceneClient respondsToSelector:NSSelectorFromString(@"process")]) {
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(sceneClient, @"process"), @"bundleIdentifier");
        if ([appIdentifiersToIgnoreLockAssertions containsObject:sceneAppBundleID])
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

static char *kCarplayPlaceholderDrawnKey;

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
    // The background view may have already been drawn on. Use an associated object to determine if its already been handled
    UIView *backgroundView = objcInvoke(self, @"backgroundView");
    id hasDrawn = objc_getAssociatedObject(backgroundView, &kCarplayPlaceholderDrawnKey);
    if (!hasDrawn)
    {
        // Not yet drawn. Set associated object to avoid redrawing
        objc_setAssociatedObject(backgroundView, &kCarplayPlaceholderDrawnKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // [[UIScreen mainscreen] bounds] may not be using the correct orientation. Get screen bounds for explicit orientation
        int deviceOrientation = [[UIDevice currentDevice] orientation];
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
        id appScene = objcInvoke(objcInvoke(currentlyHostedAppController, @"sceneHandle"), @"sceneIfExists");
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
        if ([appIdentifiersToIgnoreLockAssertions containsObject:sceneAppBundleID])
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