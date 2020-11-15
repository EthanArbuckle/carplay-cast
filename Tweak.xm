#include <objc/message.h>

#define objcInvoke(a, b) ((id (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke_1id(a, b, c) ((id (*)(id, SEL, id))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1int(a, b, c) ((id (*)(id, SEL, int))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1T(a, b, c, t) ((id (*)(id, SEL, t))objc_msgSend)(a, NSSelectorFromString(b), c)
#define getIvar(object, ivar) [object valueForKey:ivar]

%group SPRINGBOARD

%hook SBAppViewController

-(int)sceneHandle:(id)arg2 didUpdateSettingsWithDiff:(id)arg3 previousSettings:(id)arg4
{
    id scene = objcInvoke(arg2, @"scene");
    id settings = objcInvoke(scene, @"settings");
    BOOL isForeground = ((BOOL (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"isForeground"));
    if (isForeground == NO)
    {
        return 1;
    }
    return %orig;
}

%end


%hook SBSuspendedUnderLockManager

-(int)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    NSLog(@"forcing allow background %@ %@", arg2, arg3);
    return 0;
}

%end


id currentlyHostedAppController = nil;
id carplayExternalDisplay = nil;
int lastOrientation = -1;
NSString *hostedApp = nil;

%hook SpringBoard

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

%new
- (void)dismiss:(id)button
{
    if (currentlyHostedAppController)
    {
        objcInvoke(currentlyHostedAppController, @"dismiss");
    }
}

%new
- (void)handleRotate:(id)button
{
    BOOL wasLandscape = lastOrientation >= 3;
    int desiredOrientation = (wasLandscape) ? 1 : 3;

    NSLog(@"carplay rotate to %d", desiredOrientation);

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:hostedApp userInfo:@{@"orientation": @(desiredOrientation)}];
    objcInvoke_1T(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay:", desiredOrientation, int);
}

%new
- (id)handleCarPlayLaunchNotification:(id)notification
{   
    NSString *identifier = [notification userInfo][@"identifier"];
    id targetApp = objcInvoke_1id(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
    if (!targetApp)
    {
        NSLog(@"the requested app doesn't exist: %@", identifier);
        return nil;
    }

    carplayExternalDisplay = getCarplayCADisplay();
    if (!carplayExternalDisplay)
    {
        NSLog(@"cannot find a carplay display");
        return nil;
    }

    hostedApp = identifier;

    id displayConfiguration = ((id (*)(id, SEL, id, int))objc_msgSend)([objc_getClass("FBSDisplayConfiguration") alloc], NSSelectorFromString(@"initWithCADisplay:isMainDisplay:"), carplayExternalDisplay, 0);

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");

    id sceneIdentity = ((id (*)(id, SEL, id, int))objc_msgSend)(displaySceneManager, NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:"), targetApp, 1);
    id sceneHandleRequest = ((id (*)(id, SEL, id, id, id))objc_msgSend)(objc_getClass("SBApplicationSceneHandleRequest"), NSSelectorFromString(@"defaultRequestForApplication:sceneIdentity:displayIdentity:"), targetApp, sceneIdentity, mainScreenIdentity);

    id sceneHandle = objcInvoke_1id(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    id appSceneEntity = objcInvoke_1id([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);

    currentlyHostedAppController = ((id (*)(id, SEL, NSString *, id))objc_msgSend)([objc_getClass("SBAppViewController") alloc], NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:"), identifier, appSceneEntity);
    objcInvoke_1int(currentlyHostedAppController, @"setIgnoresOcclusions:", 0);

    [currentlyHostedAppController setValue:@(2) forKey:@"_currentMode"];
    __block id sceneUpdateTransaction = ((id (*)(id, SEL, id, int))objc_msgSend)(currentlyHostedAppController, NSSelectorFromString(@"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:"), appSceneEntity, 1);

    objcInvoke(getIvar(currentlyHostedAppController, @"_activationSettings"), @"clearActivationSettings");
    objcInvoke_1T(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {
        
        objcInvoke_1T(getIvar(currentlyHostedAppController, @"_activeTransitions"), @"removeObject:", sceneUpdateTransaction, id);

        id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
        id appProcess = objcInvoke(processLaunchTransaction, @"process");
        objcInvoke_1T(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
            NSLog(@"sending rotate request");
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:identifier userInfo:@{@"orientation": @(3)}];
        }, void (^)(void));

    }, void (^)(int));

    objcInvoke_1T(getIvar(currentlyHostedAppController, @"_activeTransitions"), @"addObject:", sceneUpdateTransaction, id);
    objcInvoke(sceneUpdateTransaction, @"begin");
    objcInvoke(currentlyHostedAppController, @"_createSceneViewController");

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    id appView = objcInvoke(currentlyHostedAppController, @"appView");
    ((void (*)(id, SEL, int, id, void *))objc_msgSend)(appView, NSSelectorFromString(@"setDisplayMode:animationFactory:completion:"), 4, animationFactory, 0);

    UIWindow *rootWindow = objcInvoke_1id([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);
    CGRect rootWindowFrame = [rootWindow frame];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(40, rootWindowFrame.origin.y, rootWindowFrame.size.width - 40, rootWindowFrame.size.height)];
    [container setBackgroundColor:[UIColor clearColor]];
    [container addSubview:objcInvoke(currentlyHostedAppController, @"view")];
    objcInvoke_1T(rootWindow, @"addSubview:", container, id);

    UIView *sidebarView = [[UIView alloc] initWithFrame:CGRectMake(0, rootWindowFrame.origin.y, 40, rootWindowFrame.size.height)];
    [sidebarView setBackgroundColor:[UIColor lightGrayColor]];
    objcInvoke_1T(rootWindow, @"addSubview:", sidebarView, id);

    id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(dismiss:) forControlEvents:UIControlEventTouchUpInside];
    button.frame = CGRectMake(0, 10, 35.0, 35.0);
    [button setTintColor:[UIColor blackColor]];
    [sidebarView addSubview:button];

    UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [rotateButton addTarget:self action:@selector(handleRotate:) forControlEvents:UIControlEventTouchUpInside];
    rotateButton.frame = CGRectMake(0, rootWindowFrame.size.height - 45, 35.0, 35.0);
    [rotateButton setTintColor:[UIColor blackColor]];
    [sidebarView addSubview:rotateButton];

    objcInvoke_1int(rootWindow, @"setHidden:", 0);
    
    objcInvoke_1T(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay:", 3, int);

    return currentlyHostedAppController;
}

- (void)applicationDidFinishLaunching:(id)arg1
{
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.ethanarbuckle.carplayenable" object:nil];
    %orig;
}

%end


%hook SBAppViewController

%new
- (void)dismiss
{
    objcInvoke_1int(self, @"_setCurrentMode:", 0);

    id rootWindow = [[[self view] superview] superview];
    [[self view] removeFromSuperview];
    objcInvoke_1int(rootWindow, @"setHidden:", 1);

    rootWindow = nil;
    currentlyHostedAppController = nil;
    lastOrientation = -1;

    // todo: resign first responder (kb causes glitches on return)
    // send app to background if its not on the main screen

    NSString *hostedIdentifier = getIvar(self, @"_identifier");
    int resetOrientationLock = -1;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable.orientation" object:hostedIdentifier userInfo:@{@"orientation": @(resetOrientationLock)}];
}

%new
- (void)resizeHostedAppForCarplayDisplay:(int)desiredOrientation
{
    if (desiredOrientation == lastOrientation)
    {
        return;
    }
    lastOrientation = desiredOrientation;

    id appSceneView = [[self valueForKey:@"_deviceAppViewController"] valueForKey:@"_sceneView"];
    UIView *hostingContentView = [appSceneView valueForKey:@"_sceneContentContainerView"];

    CGRect displayFrame = ((CGRect (*)(id, SEL))objc_msgSend)(carplayExternalDisplay, NSSelectorFromString(@"frame"));

    CGSize carplayDisplaySize = CGSizeMake(displayFrame.size.width - 80, displayFrame.size.height);
    CGSize mainScreenSize = [[UIScreen mainScreen] bounds].size;
    CGSize adjustedMainSize = CGSizeMake(MAX(mainScreenSize.width, mainScreenSize.height), MIN(mainScreenSize.width, mainScreenSize.height));

    CGFloat widthScale;
    CGFloat heightScale;
    CGFloat xOrigin;

    id rootWindow = [[[self view] superview] superview];

    if (desiredOrientation == 1 || desiredOrientation == 2)
    {
        // half width, full height
        widthScale = carplayDisplaySize.width / (mainScreenSize.width * 4);
        heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
        xOrigin = (([rootWindow frame].size.width / 4) + [rootWindow frame].origin.x);
    }
    else
    {
        // full width and height
        widthScale = carplayDisplaySize.width / (adjustedMainSize.width * 2);
        heightScale = carplayDisplaySize.height / (adjustedMainSize.height * 2);
        xOrigin = [rootWindow frame].origin.x;
    }

    NSLog(@"UIScreen size is %@, w scale: %f, %f, origin: %f", NSStringFromCGSize(adjustedMainSize), widthScale, heightScale, xOrigin);
    [UIView animateWithDuration:0.2 animations:^(void)
    {
        [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
        CGRect frame = [[self view] frame];
        [[self view] setFrame:CGRectMake(xOrigin, frame.origin.y, carplayDisplaySize.width, carplayDisplaySize.height)];
    } completion:nil];
}

%end

%hook FBScene

- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(void *)arg3
{
    if (currentlyHostedAppController != nil)
    {
        id sceneHandle = objcInvoke(currentlyHostedAppController, @"sceneHandle");
        id carplayHostedScene = objcInvoke(sceneHandle, @"scene");
        if (carplayHostedScene && [carplayHostedScene isEqual:self])
        {
            if (((BOOL (*)(id, SEL))objc_msgSend)(arg1, NSSelectorFromString(@"isForeground")) == NO)
            {
                return;
            }
        }
    }

    %orig;
}

%end

%end


%group CARPLAY

struct SBIconImageInfo {
    struct CGSize size;
    double scale;
    double continuousCornerRadius;
};

%hook CARApplication

+ (id)_newApplicationLibrary
{
    id allAppsConfiguration = [[objc_getClass("FBSApplicationLibraryConfiguration") alloc] init];
    objcInvoke_1T(allAppsConfiguration, @"setApplicationInfoClass:", objc_getClass("CARApplicationInfo"), Class);
    objcInvoke_1T(allAppsConfiguration, @"setApplicationPlaceholderClass:", objc_getClass("FBSApplicationPlaceholder"), Class);
    objcInvoke_1T(allAppsConfiguration, @"setAllowConcurrentLoading:", 1, int);
    objcInvoke_1T(allAppsConfiguration, @"setInstalledApplicationFilter:", ^BOOL(id appProxy, NSSet *arg2) {
        NSArray *appTags = objcInvoke(appProxy, @"appTags");
        if ([appTags containsObject:@"hidden"])
        {
            return 0;
        }
        return 1;
    }, BOOL (^)(id, id));

    id allAppsLibrary = objcInvoke_1id([objc_getClass("FBSApplicationLibrary") alloc], @"initWithConfiguration:", allAppsConfiguration);
    for (id appInfo in objcInvoke(allAppsLibrary, @"allInstalledApplications"))
    {
        if (![appInfo valueForKey:@"_carPlayDeclaration"])
        {
            if ([objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] == NO)
            {
                continue;
            }
            id appProxy = objcInvoke_1T(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", objcInvoke(appInfo, @"bundleIdentifier"), id);
            id carplayDeclaration = objcInvoke_1T(objc_getClass("CRCarPlayAppDeclaration"), @"declarationForAppProxy:", appProxy, id);
            carplayDeclaration = [[objc_getClass("CRCarPlayAppDeclaration") alloc] init];
            objcInvoke_1T(carplayDeclaration, @"setSupportsTemplates:", 0, int);
            objcInvoke_1T(carplayDeclaration, @"setSupportsMaps:", 1, int);
            objcInvoke_1T(carplayDeclaration, @"setBundleIdentifier:", objcInvoke(appInfo, @"bundleIdentifier"), id);
            objcInvoke_1T(carplayDeclaration, @"setBundlePath:", objcInvoke(appInfo, @"bundleURL"), id);
            [appInfo setValue:carplayDeclaration forKey:@"_carPlayDeclaration"];

            NSArray *newTags = @[@"CarPlayEnable"];
            if (objcInvoke(appInfo, @"tags"))
            {
                newTags = [newTags arrayByAddingObjectsFromArray:objcInvoke(appInfo, @"tags")];
            }
            [appInfo setValue:newTags forKey:@"_tags"];
        }
    }

    NSArray *systemIdentifiers = @[@"com.apple.CarPlayTemplateUIHost", @"com.apple.MusicUIService", @"com.apple.springboard", @"com.apple.InCallService", @"com.apple.CarPlaySettings", @"com.apple.CarPlayApp"];
    for (NSString *systemIdent in systemIdentifiers)
    {
        id appProxy = objcInvoke_1T(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", systemIdent, id);
        id appState = objcInvoke(appProxy, @"appState");
        if (objcInvokeT(appState, @"isValid", int) == 1)
        {
            ((void (*)(id, SEL, id, id))objc_msgSend)(allAppsLibrary, NSSelectorFromString(@"addApplicationProxy:withOverrideURL:"), appProxy, 0);
        }
    }

    return allAppsLibrary;
}

%end

%hook SBIconListGridLayoutConfiguration

- (void)setNumberOfPortraitColumns:(int)arg1
{
    %orig(5);
}

- (struct SBIconImageInfo)iconImageInfoForGridSizeClass:(unsigned long long)arg1
{
    struct SBIconImageInfo info = %orig;
    info.size = CGSizeMake(50, 50);

    return info;
}

%end

%hook CARApplicationLaunchInfo
+ (id)launchInfoForApplication:(id)arg1 withActivationSettings:(id)arg2
{
    if ([objcInvoke(arg1, @"tags") containsObject:@"CarPlayEnable"])
    {
        id sharedApp = objcInvoke(objc_getClass("UIApplication"), @"sharedApplication");
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

        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.ethanarbuckle.carplayenable" object:nil userInfo:@{@"identifier": objcInvoke(arg1, @"bundleIdentifier")}];

        return nil;
    }
    else
    {
        return %orig;
    }
}

%end

%hook CARAppDockViewController

- (void)_dockButtonPressed:(id)arg1
{
    %orig;

    NSString *bundleID = objcInvoke(arg1, @"bundleIdentifier");
    id sharedApp = objcInvoke(objc_getClass("UIApplication"), @"sharedApplication");
    id appLibrary = objcInvoke(sharedApp, @"sharedApplicationLibrary");
    id selectedAppInfo = objcInvoke_1T(appLibrary, @"applicationInfoForBundleIdentifier:", bundleID, id);
    if ([objcInvoke(selectedAppInfo, @"tags") containsObject:@"CarPlayEnable"])
    {
        objcInvoke_1T(self, @"setDockEnabled:", 1, int);
    }
}

%end

%end


%group APPS
static int orientationOverride = -1;

%hook UIApplication

- (id)init
{
    id _self = %orig;
    NSLog(@"app launched");
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleRotationRequest:") name:@"com.ethanarbuckle.carplayenable.orientation" object:[[NSBundle mainBundle] bundleIdentifier]];
    return _self;
}

%new
- (void)handleRotationRequest:(id)notification
{
    orientationOverride = [objcInvoke(notification, @"userInfo")[@"orientation"] intValue];
    NSLog(@"app got rotate request. requestedOrientation: %d", orientationOverride);

    int orientationToRequest = orientationOverride;
    if (orientationToRequest == -1)
    {
        id currentDevice = objcInvoke(objc_getClass("UIDevice"), @"currentDevice");
        orientationToRequest = ((int (*)(id, SEL))objc_msgSend)(currentDevice, NSSelectorFromString(@"orientation"));
    }

    id sharedApp = objcInvoke(objc_getClass("UIApplication"), @"sharedApplication");
    // might not be created yet...
    UIWindow *keyWindow = objcInvoke(sharedApp, @"keyWindow");
    ((void (*)(id, SEL, int, float, int))objc_msgSend)(keyWindow, NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), orientationToRequest, 0, 1);
}

%end

%hook UIWindow

- (void)_setRotatableViewOrientation:(int)orientation duration:(float)duration force:(int)force
{
    NSLog(@"_setRotatableViewOrientation(%d) (override is %d)", orientation, orientationOverride);
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
    }
    else if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"CarPlay"])
    {
        %init(CARPLAY);
    }
    else
    {
        %init(APPS);
    }
}