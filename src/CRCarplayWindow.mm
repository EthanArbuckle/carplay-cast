#include "common.h"
#include "CRCarplayWindow.h"

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

@implementation CRCarPlayWindow

- (id)initWithBundleIdentifier:(id)identifier
{
    if ((self = [super init]))
    {
        _observers = [[NSMutableArray alloc] init];
        // Update this processes' preference cache
        [[CRPreferences sharedInstance] reloadPreferences];

        // Start in landscape
        self.orientation = 3;

        self.sessionStatus = objcInvoke([objc_getClass("CARSessionStatus") alloc], @"initForCarPlayShell");

        self.application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
        assertGotExpectedObject(self.application, @"SBApplication");

        if (_drawOnMainScreen)
        {
            self.rootWindow = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
            ((void (*)(id, SEL, int, int, int, int))objc_msgSend)(self.rootWindow, NSSelectorFromString(@"_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:"), 3, 1, 0, 0);
        }
        else
        {
            id carplayExternalDisplay = getCarplayCADisplay();
            assertGotExpectedObject(carplayExternalDisplay, @"CADisplay");

            id displayConfiguration = objcInvoke_2([objc_getClass("FBSDisplayConfiguration") alloc], @"initWithCADisplay:isMainDisplay:", carplayExternalDisplay, 0);
            assertGotExpectedObject(displayConfiguration, @"FBSDisplayConfiguration");

            // Create window on the Carplay screen
            self.rootWindow = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);
        }

        [self.rootWindow.layer setCornerRadius:13.0f];
        [self.rootWindow.layer setMasksToBounds:YES];
        [self setupWallpaperBackground];
        [self setupDock];

        [self setupLiveAppView];

        // Add the user's wallpaper to the window. It will be visible when the app is in portrait mode
        CGRect rootWindowFrame = [[self rootWindow] frame];

        self.appContainerView = [[UIView alloc] initWithFrame:CGRectMake(CARPLAY_DOCK_WIDTH, rootWindowFrame.origin.y, rootWindowFrame.size.width - CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];
        [[self appContainerView] setBackgroundColor:[UIColor clearColor]];
        [[self rootWindow] addSubview:[self appContainerView]];

        // The scene does not show a launch image, it needs to be created manually.
        [self setupLaunchImage];

        // Add the live app view
        [[self appContainerView] addSubview:objcInvoke(self.appViewController, @"view")];
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:YES];

        [[self rootWindow] setAlpha:0];
        [[self rootWindow] setHidden:0];

        // "unblank" the screen. This is necessary for animations/video to render when the device is locked.
        // This does not cause the screen to actually light up
        orig_BKSDisplayServicesSetScreenBlanked(0);

        [UIView animateWithDuration:1.0 animations:^(void)
        {
            [[self rootWindow] setAlpha:1];
        } completion:nil];

        // Add a placeholder "this app is on the carplay screen" view onto the app on the main screen
        id currentSceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
        id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
        id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
        for (id appSceneLayoutController in liveAppSceneControllers)
        {
            id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
            id appSceneView = objcInvoke(appSceneController, @"_sceneView");
            id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
            if ([appSceneHandle isEqual:currentSceneHandle])
            {
                objcInvoke(appSceneView, @"drawCarplayPlaceholder");
            }
        }

        // Add observer the user changing the Dock's Alignment via preferences
        id observer = [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockAlignmentChanged queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            // Update this processes' preference cache
            [[CRPreferences sharedInstance] reloadPreferences];
            // Redraw the dock
            [self setupDock];
            // Relayout the app view
            [self resizeAppViewForOrientation:_orientation fullscreen:_isFullscreen forceUpdate:YES];
        }];
        [_observers addObject:observer];
    }

    return self;
}

- (void)setupWallpaperBackground
{
    CGRect rootWindowFrame = [[self rootWindow] frame];

    UIImageView *wallpaperImageView = [[UIImageView alloc] initWithFrame:rootWindowFrame];
    id defaultWallpaper = objcInvoke(objc_getClass("CRSUIWallpaperPreferences"), @"defaultWallpaper");
    assertGotExpectedObject(defaultWallpaper, @"CRSUIWallpaper");

    UIImage *wallpaperImage = objcInvoke_1(defaultWallpaper, @"wallpaperImageCompatibleWithTraitCollection:", nil);
    [wallpaperImageView setImage:wallpaperImage];
    UIVisualEffectView *wallpaperBlurView = [[UIVisualEffectView alloc] initWithEffect:objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 10.0)];
    [wallpaperBlurView setFrame:rootWindowFrame];
    [wallpaperImageView addSubview:wallpaperBlurView];
    [[self rootWindow] addSubview:wallpaperImageView];
}

- (void)setupDock
{
    // If the dock already exists, remove it. This allows the dock to be redrawn easily if the user switches the alignment
    if (_dockView)
    {
        [_dockView removeFromSuperview];
    }

    CGRect rootWindowFrame = [[self rootWindow] frame];
    BOOL rightHandDock = [self shouldUseRightHandDock];

    CGFloat dockXOrigin = (rightHandDock) ? rootWindowFrame.size.width - CARPLAY_DOCK_WIDTH : 0;
    self.dockView = [[UIView alloc] initWithFrame:CGRectMake(dockXOrigin, rootWindowFrame.origin.y, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];

    // Setup dock visual effects
    id blurEffect = objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 20.0);
    UIVisualEffectView *effectsView = [[UIVisualEffectView alloc] init];
    [effectsView setFrame:CGRectMake(0, 0, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];
    id colorEffect = objcInvoke_1(objc_getClass("UIColorEffect"), @"colorEffectSaturate:", 2.0);
    id darkEffect = objcInvoke_3(objc_getClass("UIVisualEffect"), @"effectCompositingColor:withMode:alpha:", [UIColor blackColor], 7, 0.6);
    NSArray *effects = @[darkEffect, colorEffect, blurEffect];
    objcInvoke_1(effectsView, @"setBackgroundEffects:", effects);
    [self.dockView addSubview:effectsView];

    [[self rootWindow] addSubview:self.dockView];

    NSBundle *carplayBundle = [NSBundle bundleWithPath:@"/System/Library/CoreServices/CarPlay.app"];
    UITraitCollection *carplayTrait = [UITraitCollection traitCollectionWithUserInterfaceIdiom:3];
    UITraitCollection *interfaceStyleTrait = [UITraitCollection traitCollectionWithUserInterfaceStyle:1];
    UITraitCollection *traitCollection = [UITraitCollection traitCollectionWithTraitsFromCollections:@[carplayTrait, interfaceStyleTrait]];

    CGFloat buttonSize = 35;
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *homeButtonLightImage = [[UIImage imageNamed:@"CarStatusBarIconsHomeButton" inBundle:carplayBundle compatibleWithTraitCollection:traitCollection] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [closeButton setImage:homeButtonLightImage forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [closeButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, rootWindowFrame.size.height - buttonSize, buttonSize, buttonSize)];
    [closeButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:closeButton];

    id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightLight];

    buttonSize = 30;

    UIButton *fullscreenButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [fullscreenButton setImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [fullscreenButton addTarget:self action:@selector(enterFullscreen) forControlEvents:UIControlEventTouchUpInside];
    [fullscreenButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, 10, buttonSize, buttonSize)];
    [fullscreenButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:fullscreenButton];

    UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [rotateButton addTarget:self action:@selector(handleRotate) forControlEvents:UIControlEventTouchUpInside];
    [rotateButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, fullscreenButton.frame.origin.y + 10 + buttonSize, buttonSize, buttonSize)];
    [rotateButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:rotateButton];
}

- (void)setupLaunchImage
{
    LOG_LIFECYCLE_EVENT;
    // Fetch a snapshot to use
    id launchImageSnapshotManifest = objcInvoke_1([objc_getClass("XBApplicationSnapshotManifest") alloc], @"initWithApplicationInfo:", objcInvoke(self.application, @"info"));
    // There's a few variants of snapshots offered: portait/landscape, dark/light.
    // For now just try to find a landscape snapshot. If no landscape, fallback to portait.
    id appSnapshot = nil;
    for (id snapshotGroup in objcInvoke(launchImageSnapshotManifest, @"_allSnapshotGroups"))
    {
        for (id snapshotCandidate in objcInvoke(snapshotGroup, @"snapshots"))
        {
            int snapshotOrientation = objcInvokeT(snapshotCandidate, @"interfaceOrientation", int);
            int snapshotContentType = objcInvokeT(snapshotCandidate, @"contentType", int);
            if (UIInterfaceOrientationIsLandscape(snapshotOrientation))
            {
                BOOL isSceneContent = snapshotContentType == 0;
                if (!appSnapshot && isSceneContent)
                {
                    if ([objcInvoke(snapshotCandidate, @"name") isEqualToString:@"CarPlayLaunchImage"])
                    {
                        appSnapshot = snapshotCandidate;
                        break;
                    }
                }

                BOOL isStaticOrGeneratedImage = (snapshotContentType == 1 || snapshotContentType == 2);
                if (isStaticOrGeneratedImage)
                {
                    appSnapshot = snapshotCandidate;
                    break;
                }
            }

            // Portait, but better than nothing
            if (!appSnapshot)
            {
                appSnapshot = snapshotCandidate;
            }
        }
    }
    // If no landscape image was found, queue up a snapshot once the app launches
    self.shouldGenerateSnapshot = UIInterfaceOrientationIsPortrait(objcInvokeT(appSnapshot, @"interfaceOrientation", int));

    // Get the image from the chosen snapshot
    id appSnapshotImage = objcInvoke_1(appSnapshot, @"imageForInterfaceOrientation:", 1);

    // Build an imageview to contain the launch image.
    // The processLaunched handler defined above is responsible for cleaning this up
    self.launchImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, [[self appContainerView] frame].size.width, [[self appContainerView] frame].size.height)];
    [self.launchImageView setImage:appSnapshotImage];
    [self.launchImageView setContentMode:UIViewContentModeScaleToFill];
    [[self appContainerView] addSubview:self.launchImageView];
}

- (void)setupLiveAppView
{
    LOG_LIFECYCLE_EVENT;
    NSString *appIdentifier = objcInvoke(self.application, @"bundleIdentifier");

    NSMutableArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
    [lockAssertions addObject:appIdentifier];

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    assertGotExpectedObject(displaySceneManager, @"SBMainDisplaySceneManager");

    id sceneLayoutManager = objcInvoke(displaySceneManager, @"_layoutStateManager");
    assertGotExpectedObject(sceneLayoutManager, @"SBMainDisplayLayoutStateManager");

    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");
    assertGotExpectedObject(mainScreenIdentity, @"FBSDisplayIdentity");

    id sceneIdentity = objcInvoke_2(displaySceneManager, @"_sceneIdentityForApplication:createPrimaryIfRequired:", self.application, 1);
    assertGotExpectedObject(sceneIdentity, @"FBSSceneIdentity");

    id sceneHandleRequest = objcInvoke_3(objc_getClass("SBApplicationSceneHandleRequest"), @"defaultRequestForApplication:sceneIdentity:displayIdentity:", self.application, sceneIdentity, mainScreenIdentity);
    assertGotExpectedObject(sceneHandleRequest, @"SBApplicationSceneHandleRequest");

    id sceneHandle = objcInvoke_1(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    assertGotExpectedObject(sceneHandle, @"SBDeviceApplicationSceneHandle");

    id appSceneEntity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
    assertGotExpectedObject(appSceneEntity, @"SBDeviceApplicationSceneEntity");

    self.appViewController = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", appIdentifier, appSceneEntity);
    assertGotExpectedObject(self.appViewController, @"SBAppViewController");
    objcInvoke_1(self.appViewController, @"setIgnoresOcclusions:", 0);
    setIvar(self.appViewController, @"_currentMode", @(2));
    objcInvoke(getIvar(self.appViewController, @"_activationSettings"), @"clearActivationSettings");

    id sceneUpdateTransaction = objcInvoke_2(self.appViewController, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", appSceneEntity, 1);
    assertGotExpectedObject(sceneUpdateTransaction, @"SBApplicationSceneUpdateTransaction");

    __block NSMutableArray *transactions = getIvar(self.appViewController, @"_activeTransitions");
    objcInvoke_1(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {

        [transactions removeObject:sceneUpdateTransaction];

        id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
        assertGotExpectedObject(processLaunchTransaction, @"FBApplicationProcessLaunchTransaction");

        id appProcess = objcInvoke(processLaunchTransaction, @"process");
        assertGotExpectedObject(appProcess, @"FBProcess");

        objcInvoke_1(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
            // Wait a sec then remove the splashscreen image. It should already be hidden/covered by the live app view, but it needs to be removed
            // so it doesn't poke through if the App's orientation changes to portait
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self.launchImageView removeFromSuperview];

                if (self.shouldGenerateSnapshot)
                {
                    // Now that the app is launched and presumably in landscape mode, save a snapshot.
                    // If an app does not natively support landscape mode and doesn't ship a landscape launch image, this snapshot can be used during cold-launches
                    id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
                    if (!appScene)
                    {
                        return;
                    }
                    id sceneSettings = objcInvoke(appScene, @"mutableSettings");
                    objcInvoke_1(sceneSettings, @"setInterfaceOrientation:", self.orientation);
                    id snapshotContext = objcInvoke_2(objc_getClass("FBSSceneSnapshotContext"), @"contextWithSceneID:settings:", objcInvoke(appScene, @"identifier"), sceneSettings);
                    objcInvoke_1(snapshotContext, @"setName:", @"CarPlayLaunchImage");
                    objcInvoke_1(snapshotContext, @"setScale:", 2);
                    objcInvoke_1(snapshotContext, @"setExpirationInterval:", 99999);
                    objcInvoke_3(self.application, @"saveSnapshotForSceneHandle:context:completion:", sceneHandle, snapshotContext, nil);
                }
            });

            // Ask the app to rotate to landscape
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:appIdentifier userInfo:@{@"orientation": @(self.orientation)}];
        });
    });

    [transactions addObject:sceneUpdateTransaction];
    objcInvoke(sceneUpdateTransaction, @"begin");
    objcInvoke(self.appViewController, @"_createSceneViewController");

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    assertGotExpectedObject(animationFactory, @"BSUIAnimationFactory");

    id appView = objcInvoke(self.appViewController, @"appView");
    objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, animationFactory, 0);
    [[self.appViewController view] setBackgroundColor:[UIColor clearColor]];

    // Create a scene monitor to watch for the app process dying. The carplay window will dismiss itself.
    // todo: this returns nil if the app process isn't running..
    NSString *sceneID = objcInvoke_1(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:", appIdentifier);
    self.sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
    objcInvoke_1(self.sceneMonitor, @"setDelegate:", self);
}

/*
FBSceneMonitor delegate method, invoked when the app process dies.
Use this to close the window on the CarPlay screen if the app crashes or is killed via the App Switcher on main screen
*/
- (void)sceneMonitor:(id)arg1 sceneWasDestroyed:(id)arg2
{
    LOG_LIFECYCLE_EVENT;
    // Close the window
    objcInvoke(self, @"dismiss");
}

- (void)exitFullscreen
{
    LOG_LIFECYCLE_EVENT;
    if ([self fullscreenTransparentOverlay] != nil)
    {
        [[self fullscreenTransparentOverlay] removeFromSuperview];
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:NO];
    }
}

- (void)enterFullscreen
{
    LOG_LIFECYCLE_EVENT;
    // Only need fullscreen when in landscape
    if (UIInterfaceOrientationIsPortrait(self.orientation))
    {
        return;
    }

    BOOL toFullScreen = 1;

    self.fullscreenTransparentOverlay = [[UIView alloc] initWithFrame:[[self rootWindow] frame]];
    [self.fullscreenTransparentOverlay setBackgroundColor:[UIColor whiteColor]];
    [self.fullscreenTransparentOverlay setAlpha:0.05];
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(exitFullscreen)];
    [self.fullscreenTransparentOverlay addGestureRecognizer:tapGesture];
    [self.fullscreenTransparentOverlay setUserInteractionEnabled:YES];
    [[self rootWindow] addSubview:self.fullscreenTransparentOverlay];

    [UIView animateWithDuration:0.2 animations:^(void) {
        [self resizeAppViewForOrientation:self.orientation fullscreen:toFullScreen forceUpdate:NO];
    } completion:nil];
}

/*
When a CarPlay App is closed
*/
- (void)dismiss
{
    LOG_LIFECYCLE_EVENT;
    // Invalidate the scene monitor
    [self.sceneMonitor invalidate];

    // Remove any observers
    for (id observer in _observers)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] removeObserver:observer];
    }

    void (^cleanupAfterCarplay)() = ^() {
        // Notify the application process to stop enforcing an orientation lock
        int resetOrientationLock = -1;
        NSString *hostedIdentifier = getIvar(self.appViewController, @"_identifier");
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:hostedIdentifier userInfo:@{@"orientation": @(resetOrientationLock)}];

        [self.rootWindow setHidden:YES];
        objcInvoke_1(self.appViewController, @"_setCurrentMode:", 0);

        // Find the main sceen's sceneView for the dismissing app and put it in LiveContent mode (from PlaceHolder mode)
        // This removes the placeholder view visible in the app switcher
        id currentSceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
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
        id appScene = objcInvoke(objcInvoke(self.appViewController, @"sceneHandle"), @"sceneIfExists");
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

        // If the device is locked and screen off, set the screen state to off
        if (objcInvokeT(sharedApp, @"isLocked", BOOL) == YES)
        {
            void *_BKSHIDServicesGetBacklightFactor = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
            float backlightFactor = ((float (*)(void))_BKSHIDServicesGetBacklightFactor)();
            if (backlightFactor < 0.2)
            {
                orig_BKSDisplayServicesSetScreenBlanked(1);
            }
        }

        objc_setAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // todo: resign first responder (kb causes glitches on return)
    };

    [UIView animateWithDuration:0.5 animations:^(void)
    {
        [[self rootWindow] setAlpha:0];
    } completion:^(BOOL completed)
    {
        cleanupAfterCarplay();
    }];
}

/*
When the "rotate orientation" button is pressed on a CarplayEnabled app window
*/
- (void)handleRotate
{
    LOG_LIFECYCLE_EVENT;
    int desiredOrientation = (UIInterfaceOrientationIsLandscape(self.orientation)) ? 1 : 3;

    id appScene = objcInvoke(objcInvoke([self appViewController], @"sceneHandle"), @"sceneIfExists");
    if (!appScene)
    {
        // The scene doesn't exist - maybe the app hasn't finished launching yet
        return;
    }

    NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:sceneAppBundleID userInfo:@{@"orientation": @(desiredOrientation)}];
    [self resizeAppViewForOrientation:desiredOrientation fullscreen:self.isFullscreen forceUpdate:NO];
}

/*
Handle resizing the Carplay App window. Called anytime the app orientation changes (including first appearance)
*/
- (void)resizeAppViewForOrientation:(int)desiredOrientation fullscreen:(BOOL)fullscreen forceUpdate:(BOOL)forceUpdate
{
    LOG_LIFECYCLE_EVENT;
    if (!forceUpdate && (desiredOrientation == self.orientation && self.isFullscreen == fullscreen))
    {
        return;
    }

    id appSceneView = getIvar(getIvar(self.appViewController, @"_deviceAppViewController"), @"_sceneView");
    assertGotExpectedObject(appSceneView, @"SBSceneView");
    UIView *hostingContentView = getIvar(appSceneView, @"_sceneContentContainerView");
    UIScreen *targetScreen = nil;
    if (_drawOnMainScreen)
    {
        targetScreen = [UIScreen mainScreen];
    }
    else {
        for (UIScreen *currentScreen in [UIScreen screens])
        {
            if (objcInvokeT(currentScreen, @"_isCarScreen", BOOL))
            {
                targetScreen = currentScreen;
                break;
            }
        }
    }

    assertGotExpectedObject(targetScreen, @"UIScreen");

    CGRect carplayDisplayBounds = [targetScreen bounds];
    CGFloat dockWidth = (fullscreen) ? 0 : CARPLAY_DOCK_WIDTH;
    CGSize carplayDisplaySize = CGSizeMake(carplayDisplayBounds.size.width - dockWidth, carplayDisplayBounds.size.height);

    CGSize mainScreenSize = ((CGRect (*)(id, SEL, int))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"boundsForOrientation:"), desiredOrientation).size;

    CGFloat widthScale = carplayDisplaySize.width / mainScreenSize.width;
    CGFloat heightScale = carplayDisplaySize.height / mainScreenSize.height;
    CGFloat xOrigin = [[self rootWindow] frame].origin.x;

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
    [[self.appViewController view] setFrame:CGRectMake(xOrigin, [[self.appViewController view] frame].origin.y, carplayDisplaySize.width, carplayDisplaySize.height)];

    BOOL rightHandDock = [self shouldUseRightHandDock];
    UIView *containingView = [self appContainerView];
    CGRect containingViewFrame = [containingView frame];
    containingViewFrame.origin.x = (rightHandDock) ? 0 : dockWidth;
    [containingView setFrame:containingViewFrame];

    [self.dockView setAlpha: (fullscreen) ? 0 : 1];

    // Update last known orientation and fullscreen status
    self.orientation = desiredOrientation;
    self.isFullscreen = fullscreen;
}

- (BOOL)shouldUseRightHandDock
{
    // Should the dock be drawn on the left or right side of the screen
    switch ([[CRPreferences sharedInstance] dockAlignment])
    {
        case CRDockAlignmentLeft:
            return NO;
        case CRDockAlignmentRight:
            return YES;
        case CRDockAlignmentAuto:
        {
            // Auto mode - determine which alignment Carplay is using and mimick it
            id carplaySession = objcInvoke(self.sessionStatus, @"session");
            id usesRightHand = objcInvoke_1(carplaySession, @"_endpointValueForKey:", @"RightHandDrive");
            return [usesRightHand boolValue];
        }
        default:
        {
            break;
        }
    }

    return NO;
}

@end