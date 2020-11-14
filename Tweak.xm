#include <objc/message.h>

#define objcInvoke(a, b) ((id (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke_1id(a, b, c) ((id (*)(id, SEL, id))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1int(a, b, c) ((id (*)(id, SEL, int))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1T(a, b, c, t) ((id (*)(id, SEL, t))objc_msgSend)(a, NSSelectorFromString(b), c)

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

    id displayConfiguration = ((id (*)(id, SEL, id, int))objc_msgSend)([objc_getClass("FBSDisplayConfiguration") alloc], NSSelectorFromString(@"initWithCADisplay:isMainDisplay:"), carplayExternalDisplay, 0);

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");

    id sceneIdentity = ((id (*)(id, SEL, id, int))objc_msgSend)(displaySceneManager, NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:"), targetApp, 1);
    id sceneHandleRequest = ((id (*)(id, SEL, id, id, id))objc_msgSend)(objc_getClass("SBApplicationSceneHandleRequest"), NSSelectorFromString(@"defaultRequestForApplication:sceneIdentity:displayIdentity:"), targetApp, sceneIdentity, mainScreenIdentity);

    id sceneHandle = objcInvoke_1id(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    id appSceneEntity = objcInvoke_1id([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);

    currentlyHostedAppController = ((id (*)(id, SEL, NSString *, id))objc_msgSend)([objc_getClass("SBAppViewController") alloc], NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:"), identifier, appSceneEntity);
    objcInvoke_1int(currentlyHostedAppController, @"setIgnoresOcclusions:", 0);
    objcInvoke_1int(currentlyHostedAppController, @"_setCurrentMode:", 2);

    id rootWindow = objcInvoke_1id([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);

    objcInvoke_1id(rootWindow, @"setRootViewController:", currentlyHostedAppController);
    objcInvoke_1int(rootWindow, @"setHidden:", 0);

    objcInvoke(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay");

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

    id rootWindow = [[self view] superview];
    [[self view] removeFromSuperview];
    objcInvoke_1int(rootWindow, @"setHidden:", 1);

    rootWindow = nil;
    currentlyHostedAppController = nil;
    lastOrientation = -1;
}

%new
- (void)resizeHostedAppForCarplayDisplay
{
    id sharedApp = objcInvoke(objc_getClass("UIApplication"), @"sharedApplication");
    int deviceOrientation = objcInvokeT(sharedApp, @"statusBarOrientation", int);
    if (deviceOrientation == lastOrientation)
    {
        return;
    }
    lastOrientation = deviceOrientation;

    id appSceneView = [[self valueForKey:@"_deviceAppViewController"] valueForKey:@"_sceneView"];
    UIView *hostingContentView = [appSceneView valueForKey:@"_sceneContentContainerView"];

    CGRect displayFrame = ((CGRect (*)(id, SEL))objc_msgSend)(carplayExternalDisplay, NSSelectorFromString(@"frame"));
    NSLog(@"carplay frame: %@", NSStringFromCGRect(displayFrame));

    CGSize carplayDisplaySize = displayFrame.size;
    CGSize mainScreenSize = [[UIScreen mainScreen] bounds].size;

    CGFloat widthScale;
    CGFloat heightScale;
    CGFloat xOrigin;

    id rootWindow = [[self view] superview];

    if (deviceOrientation == 1 || deviceOrientation == 2)
    {
        // half width, full height
        NSLog(@"portait");
        widthScale = carplayDisplaySize.width / (mainScreenSize.width * 4);
        heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
        xOrigin = (([rootWindow frame].size.width / 4) + [rootWindow frame].origin.x);
    }
    else
    {
        NSLog(@"landscape");
        // full width and height
        widthScale = carplayDisplaySize.width / (mainScreenSize.width * 2);
        heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
        xOrigin = [rootWindow frame].origin.x;
    }

    NSLog(@"UIScreen size is %@, w scale: %f, %f, origin: %f", NSStringFromCGSize(mainScreenSize), widthScale, heightScale, xOrigin);
    [UIView animateWithDuration:0.2 animations:^(void)
    {
        [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
        CGRect frame = [[self view] frame];
        [[self view] setFrame:CGRectMake(xOrigin, frame.origin.y, frame.size.width, frame.size.height)];
    } completion:nil];
}

%end


%hook UIWindow

- (BOOL)_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    BOOL shouldRotate = %orig;
    if (currentlyHostedAppController && carplayExternalDisplay)
    {
        int deviceLocked = objcInvokeT(objcInvoke(objc_getClass("SpringBoard"), @"sharedApplication"), @"isLocked", int);
        if (deviceLocked == 0 && shouldRotate)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                objcInvoke(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay");
            });
        }
    }

    return shouldRotate;
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
    %log;
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
}