#include <Foundation/Foundation.h>
#include <objc/message.h>
#include <dlfcn.h>

#define getIvar(object, ivar) [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]
#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke(a, b) objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)
#define assertGotExpectedObject(obj, type) if (!obj || ![obj isKindOfClass:NSClassFromString(type)]) [NSException raise:@"UnexpectedObjectException" format:@"Expected %@ but got %@", type, obj]

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
When the "close" button is pressed on a CarplayEnabled app window
*/
%new
- (void)dismiss:(id)button
{
    if (currentlyHostedAppController)
    {
        objcInvoke(currentlyHostedAppController, @"dismiss");
    }
}

/*
When the "rotate orientation" button is pressed on a CarplayEnabled app window
*/
%new
- (void)handleRotate:(id)button
{
    BOOL wasLandscape = lastOrientation >= 3;
    int desiredOrientation = (wasLandscape) ? 1 : 3;

    id appScene = objcInvoke(objcInvoke(currentlyHostedAppController, @"sceneHandle"), @"sceneIfExists");
    NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:sceneAppBundleID userInfo:@{@"orientation": @(desiredOrientation)}];
    objcInvoke_1(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay:", desiredOrientation);
}

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
        [container addSubview:objcInvoke(appViewController, @"view")];
        [rootWindow addSubview:container];

        UIView *sidebarView = [[UIView alloc] initWithFrame:CGRectMake(0, rootWindowFrame.origin.y, 40, rootWindowFrame.size.height)];
        [sidebarView setBackgroundColor:[UIColor lightGrayColor]];
        [rootWindow addSubview:sidebarView];

        id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40];

        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
        [closeButton addTarget:self action:@selector(dismiss:) forControlEvents:UIControlEventTouchUpInside];
        [closeButton setFrame:CGRectMake(0, 10, 35.0, 35.0)];
        [closeButton setTintColor:[UIColor blackColor]];
        [sidebarView addSubview:closeButton];

        UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
        [rotateButton addTarget:self action:@selector(handleRotate:) forControlEvents:UIControlEventTouchUpInside];
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
                UIView *backgroundView = objcInvoke(appSceneView, @"backgroundView");
                objcInvoke_1(backgroundView, @"setWallpaperStyle:", 18);

                id orientationTransformedView = nil;
                id _candidate = [appSceneView superview];
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
                    UILabel *hostedOnCarplayLabel = [[UILabel alloc] initWithFrame:CGRectMake(150, 300, 300, 50)];
                    [hostedOnCarplayLabel setText:@"Running on CarPlay Screen"];
                    [hostedOnCarplayLabel setTextAlignment:NSTextAlignmentCenter];
                    [hostedOnCarplayLabel setCenter:[backgroundView center]];
                    [hostedOnCarplayLabel setHidden:1];
                    [backgroundView addSubview:hostedOnCarplayLabel];

                    UIButton *sbDismissButton = [UIButton buttonWithType:UIButtonTypeCustom];
                    [sbDismissButton setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
                    [sbDismissButton addTarget:appViewController action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
                    [sbDismissButton setFrame:CGRectMake(([[UIScreen mainScreen] bounds].size.width / 2) - (70.0 / 2), hostedOnCarplayLabel.frame.origin.y + 70, 70.0, 70.0)];
                    [sbDismissButton setTintColor:[UIColor blackColor]];
                    [sbDismissButton setHidden:1];
                    [backgroundView addSubview:sbDismissButton];

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        int deviceOrientation = [[UIDevice currentDevice] orientation];
                        objcInvoke_1(orientationTransformedView, @"setContentOrientation:", deviceOrientation);

                        [hostedOnCarplayLabel setHidden:0];
                        [sbDismissButton setHidden:0];
                    });
                }

                objcInvoke_3(appSceneView, @"setDisplayMode:animationFactory:completion:", 1, animationFactory, nil);
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

/*
When a CarPlay App is closed
*/
%new
- (void)dismiss
{
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

        // After the scene returns to the device, release the assertion that prevents suspension
        id appScene = objcInvoke(objcInvoke(currentlyHostedAppController, @"sceneHandle"), @"sceneIfExists");
        assertGotExpectedObject(appScene, @"FBScene");

        NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
        [appIdentifiersToIgnoreLockAssertions removeObject:sceneAppBundleID];

        // Send the app to the background *if it is not on the main screen*
        id sharedApp = [UIApplication sharedApplication];
        id frontmostApp = objcInvoke(sharedApp, @"_accessibilityFrontMostApplication");
        BOOL isAppOnMainScreen = frontmostApp && [objcInvoke(frontmostApp, @"bundleIdentifier") isEqualToString:sceneAppBundleID];
        if (!isAppOnMainScreen)
        {
            id sceneSettings = objcInvoke(appScene, @"mutableSettings");
            objcInvoke_1(sceneSettings, @"setBackgrounded:", 1);
            objcInvoke_1(sceneSettings, @"setForeground:", 0);
            ((void (*)(id, SEL, id, id, void *))objc_msgSend)(appScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), sceneSettings, nil, 0);
        }

        // If the device is locked, set the screen state to off
        if (objcInvokeT(sharedApp, @"isLocked", BOOL) == YES)
        {
            orig_BKSDisplayServicesSetScreenBlanked(1);
        }

        rootWindow = nil;
        currentlyHostedAppController = nil;

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

- (id)initWithSceneHandle:(id)arg1 referenceSize:(struct CGSize)arg2 orientation:(long long)arg3 hostRequester:(id)arg4
{
    NSLog(@"initWithSceneHandle");
    id _self = %orig;

    if (currentlyHostedAppController != nil)
    {
        id currentSceneHandle = objcInvoke(_self, @"sceneHandle");
        id carplaySceneHandle = objcInvoke(currentlyHostedAppController, @"sceneHandle");
        if ([currentSceneHandle isEqual:carplaySceneHandle])
        {
            NSLog(@"this scene is on the carplay unit");

            id backgroundView = objcInvoke(_self, @"backgroundView");
            objcInvoke_1(backgroundView, @"setWallpaperStyle:", 18);

            objcInvoke_3(_self, @"setDisplayMode:animationFactory:completion:", 1, nil, nil);
        }

    }

    return _self;
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

/*
Injected into the CarPlay process
*/
%group CARPLAY

struct SBIconImageInfo {
    struct CGSize size;
    double scale;
    double continuousCornerRadius;
};

%hook CARApplication

void addCarplayDeclarationsToAppLibrary(id appLibrary)
{
    for (id appInfo in objcInvoke(appLibrary, @"allInstalledApplications"))
    {
        if (getIvar(appInfo, @"_carPlayDeclaration") == nil)
        {
            if ([objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] == NO)
            {
                continue;
            }

            id carplayDeclaration = [[objc_getClass("CRCarPlayAppDeclaration") alloc] init];
            objcInvoke_1(carplayDeclaration, @"setSupportsTemplates:", 0);
            objcInvoke_1(carplayDeclaration, @"setSupportsMaps:", 1);
            objcInvoke_1(carplayDeclaration, @"setBundleIdentifier:", objcInvoke(appInfo, @"bundleIdentifier"));
            objcInvoke_1(carplayDeclaration, @"setBundlePath:", objcInvoke(appInfo, @"bundleURL"));
            setIvar(appInfo, @"_carPlayDeclaration", carplayDeclaration);

            NSArray *newTags = @[@"CarPlayEnable"];
            if (objcInvoke(appInfo, @"tags"))
            {
                newTags = [newTags arrayByAddingObjectsFromArray:objcInvoke(appInfo, @"tags")];
            }
            setIvar(appInfo, @"_tags", newTags);
        }
    }
}

/*
Include all User applications on the CarPlay dashboard
*/
+ (id)_newApplicationLibrary
{
    id allAppsConfiguration = [[objc_getClass("FBSApplicationLibraryConfiguration") alloc] init];
    objcInvoke_1(allAppsConfiguration, @"setApplicationInfoClass:", objc_getClass("CARApplicationInfo"));
    objcInvoke_1(allAppsConfiguration, @"setApplicationPlaceholderClass:", objc_getClass("FBSApplicationPlaceholder"));
    objcInvoke_1(allAppsConfiguration, @"setAllowConcurrentLoading:", 1);
    objcInvoke_1(allAppsConfiguration, @"setInstalledApplicationFilter:", ^BOOL(id appProxy, NSSet *arg2) {
        NSArray *appTags = objcInvoke(appProxy, @"appTags");
        if ([appTags containsObject:@"hidden"])
        {
            return 0;
        }
        return 1;
    });

    id allAppsLibrary = objcInvoke_1([objc_getClass("FBSApplicationLibrary") alloc], @"initWithConfiguration:", allAppsConfiguration);
    // Add a "carplay declaration" to each app so they appear on the dashboard
    addCarplayDeclarationsToAppLibrary(allAppsLibrary);

    NSArray *systemIdentifiers = @[@"com.apple.CarPlayTemplateUIHost", @"com.apple.MusicUIService", @"com.apple.springboard", @"com.apple.InCallService", @"com.apple.CarPlaySettings", @"com.apple.CarPlayApp"];
    for (NSString *systemIdent in systemIdentifiers)
    {
        id appProxy = objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", systemIdent);
        id appState = objcInvoke(appProxy, @"appState");
        if (objcInvokeT(appState, @"isValid", int) == 1)
        {
            objcInvoke_2(allAppsLibrary, @"addApplicationProxy:withOverrideURL:", appProxy, 0);
        }
    }

    return allAppsLibrary;
}

%end

/*
Carplay dashboard icon appearance
*/
%hook SBIconListGridLayoutConfiguration

/*
Make the CarPlay dashboard show 5 columns of apps instead of 4
*/
- (void)setNumberOfPortraitColumns:(int)arg1
{
    %orig(5);
}

/*
Make the Carplay dashboard icons a little smaller so 5 fit comfortably
*/
- (struct SBIconImageInfo)iconImageInfoForGridSizeClass:(unsigned long long)arg1
{
    struct SBIconImageInfo info = %orig;
    info.size = CGSizeMake(50, 50);

    return info;
}

%end

/*
When an app is launched via Carplay dashboard
*/
%hook CARApplicationLaunchInfo

+ (id)launchInfoForApplication:(id)arg1 withActivationSettings:(id)arg2
{
    if ([objcInvoke(arg1, @"tags") containsObject:@"CarPlayEnable"])
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable" object:nil userInfo:@{@"identifier": objcInvoke(arg1, @"bundleIdentifier")}];

        id sharedApp = [UIApplication sharedApplication];
        id appHistory = objcInvoke(sharedApp, @"_currentAppHistory");

        NSString *previousBundleID = nil;
        NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
        if ([orderedAppHistory count] > 0)
        {
            previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
        }

        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), objcInvoke(arg1, @"bundleIdentifier"), previousBundleID);

        id dashboardRootController = objcInvoke(objcInvoke(sharedApp, @"_currentDashboard"), @"rootViewController");
        id dockController = objcInvoke(dashboardRootController, @"appDockViewController");
        objcInvoke(dockController, @"_refreshAppDock");

        // If the is already a Carplay app running, close it
        id dashboard = objcInvoke(sharedApp, @"_currentDashboard");
        assertGotExpectedObject(dashboard, @"CARDashboard");
        NSDictionary *foregroundScenes = objcInvoke(dashboard, @"identifierToForegroundAppScenesMap");
        if ([[foregroundScenes allKeys] count] > 0)
        {
            id homeButtonEvent = objcInvoke_2(objc_getClass("CAREvent"), @"eventWithType:context:", 1, @"Close carplay app");
            assertGotExpectedObject(homeButtonEvent, @"CAREvent");
            objcInvoke_1(dashboard, @"handleEvent:", homeButtonEvent);
        }

        return nil;
    }
    else
    {
        return %orig;
    }
}

%end

/*
When an app is launched via the Carplay Dock
*/
%hook CARAppDockViewController

- (void)_dockButtonPressed:(id)arg1
{
    %orig;

    NSString *bundleID = objcInvoke(arg1, @"bundleIdentifier");
    id sharedApp = [UIApplication sharedApplication];
    id appLibrary = objcInvoke(sharedApp, @"sharedApplicationLibrary");
    id selectedAppInfo = objcInvoke_1(appLibrary, @"applicationInfoForBundleIdentifier:", bundleID);
    if ([objcInvoke(selectedAppInfo, @"tags") containsObject:@"CarPlayEnable"])
    {
        objcInvoke_1(self, @"setDockEnabled:", 1);
    }
}

%end


/*
Called when an app is installed or uninstalled.
Used for adding "carplay declaration" to newly installed apps so they appear on the dashboard
*/
%hook _CARDashboardHomeViewController

- (void)_handleAppLibraryRefresh
{
    id appLibrary = objcInvoke(self, @"library");
    addCarplayDeclarationsToAppLibrary(appLibrary);
    %orig;
}

%end

%hook CARIconView

%new
- (void)handleLaunchAppInNormalMode:(UILongPressGestureRecognizer *)gesture
{
    if ([gesture state] == UIGestureRecognizerStateBegan)
    {
        id icon = objcInvoke(self, @"icon");
        assertGotExpectedObject(icon, @"SBIcon");
        NSString *bundleID = objcInvoke(icon, @"applicationBundleID");

        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable" object:nil userInfo:@{@"identifier": bundleID}];

        id sharedApp = [UIApplication sharedApplication];
        id appHistory = objcInvoke(sharedApp, @"_currentAppHistory");

        NSString *previousBundleID = nil;
        NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
        if ([orderedAppHistory count] > 0)
        {
            previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), bundleID, previousBundleID);

        id dashboardRootController = objcInvoke(objcInvoke(sharedApp, @"_currentDashboard"), @"rootViewController");
        id dockController = objcInvoke(dashboardRootController, @"appDockViewController");
        objcInvoke(dockController, @"_refreshAppDock");
    }
}

- (id)initWithConfigurationOptions:(unsigned long long)arg1 listLayoutProvider:(id)arg2
{
    id _self = %orig;
    UILongPressGestureRecognizer *launchGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:_self action:NSSelectorFromString(@"handleLaunchAppInNormalMode:")];
    [launchGesture setMinimumPressDuration:1.5];
    [_self addGestureRecognizer:launchGesture];
    return _self;
}
%end

%end

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
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"])
    {
        %init(SPRINGBOARD);
        // Hook BKSDisplayServicesSetScreenBlanked() - necessary for allowing animations/video when the screen is off
        void *_BKSDisplayServicesSetScreenBlanked = dlsym(dlopen(NULL, 0), "BKSDisplayServicesSetScreenBlanked");
        MSHookFunction(_BKSDisplayServicesSetScreenBlanked, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    }
    else if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"CarPlay"])
    {
        %init(CARPLAY);
    }
    else
    {
        // Only need to inject into Apps, not daemons
        if ([[[NSBundle mainBundle] bundlePath] containsString:@".app"])
        {
            %init(APPS);
        }
    }
}