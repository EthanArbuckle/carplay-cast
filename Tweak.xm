#include <objc/message.h>

#define objcInvoke(a, b) ((id (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke_1id(a, b, c) ((id (*)(id, SEL, id))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1int(a, b, c) ((id (*)(id, SEL, int))objc_msgSend)(a, NSSelectorFromString(b), c)

// %hook FBSceneManager

// - (id)_createSceneWithDefinition:(id)arg1 settings:(id)arg2 initialClientSettings:(id)arg3 transitionContext:(id)arg4 fromRemnant:(id)arg5 usingClientProvider:(id)arg6 completion:(void*)arg7
// {
// 	NSLog(@"running,,, %@", arg1);
// 	id specification = objcInvoke(arg1, @"specification");
// 	Class settingsClass = objcInvokeT(specification, @"settingsClass", Class);
// 	NSLog(@"default CLASS IS %@", NSStringFromClass(settingsClass));
// 	objcInvoke_1id(arg1, @"setSpecification:", objcInvoke(NSClassFromString(@"UIApplicationSceneSpecification"), @"specification"));
// 	NSLog(@"new CLASS IS %@", NSStringFromClass(objcInvokeT(objcInvoke(arg1, @"specification"), @"settingsClass", Class)));
// 	NSLog(@"%@", arg1);
// 	NSLog(@"%@", arg2);
// 	NSLog(@"%@", arg3);
// 	NSLog(@"%@", arg4);
// 	NSLog(@"%@", arg5);
// 	NSLog(@"%@", arg6);
// 	return %orig;
// }

// %end

%hook SBAppViewController

-(int)sceneHandle:(id)arg2 didUpdateSettingsWithDiff:(id)arg3 previousSettings:(id)arg4 {

    id scene = objcInvoke(arg2, @"scene");
    id settings = objcInvoke(scene, @"settings");
    BOOL isForeground = ((BOOL (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"isForeground"));
    if (isForeground == NO) {
        return 1;
    }
    return %orig;
}

%end


%hook SBSuspendedUnderLockManager

-(int)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3 {
    NSLog(@"forcing allow background %@ %@", arg2, arg3);
    return 0;
}

%end


id currentlyHostedAppController = nil;
id carplayExternalDisplay = nil;
int lastOrientation = -1;


%hook SpringBoard

%new
- (id)hostAppOnCarplayUnit:(NSString *)identifier {

    id targetApp = objcInvoke_1id(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
    if (!targetApp) {
        NSLog(@"the requested app doesn't exist: %@", identifier);
        return nil;
    }

    CGSize carplayDisplaySize;
    for (id currentDisplay in objcInvoke(objc_getClass("CADisplay"), @"displays")) {

        if (currentDisplay == objcInvoke(objc_getClass("CADisplay"), @"mainDisplay")) {
            continue;
        }

        CGRect displayFrame = ((CGRect (*)(id, SEL))objc_msgSend)(currentDisplay, NSSelectorFromString(@"frame"));
        if (CGRectEqualToRect(displayFrame, CGRectZero)) {
            continue;
        }

        carplayExternalDisplay = currentDisplay;
        carplayDisplaySize = displayFrame.size;
        break;
    }

    if (!carplayExternalDisplay) {
        NSLog(@"cannot find the carplay cadisplay");
        return nil;
    }

    id displayConfiguration = ((id (*)(id, SEL, id, int))objc_msgSend)([objc_getClass("FBSDisplayConfiguration") alloc], NSSelectorFromString(@"initWithCADisplay:isMainDisplay:"), carplayExternalDisplay, 0);

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");

    id sceneIdentity = ((id (*)(id, SEL, id, int))objc_msgSend)(displaySceneManager, NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:"), targetApp, 1);
    id sceneHandleRequest = ((id (*)(id, SEL, id, id, id))objc_msgSend)(objc_getClass("SBApplicationSceneHandleRequest"), NSSelectorFromString(@"defaultRequestForApplication:sceneIdentity:displayIdentity:"), targetApp, sceneIdentity, objcInvoke(displaySceneManager, @"displayIdentity"));

    id sceneHandle = objcInvoke_1id(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    id appSceneEntity = objcInvoke_1id([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);

    id appViewController = ((id (*)(id, SEL, NSString *, id))objc_msgSend)([objc_getClass("SBAppViewController") alloc], NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:"), identifier, appSceneEntity);
    objcInvoke_1int(appViewController, @"setIgnoresOcclusions:", 0);

    id rootWindow = objcInvoke_1id([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);

    objcInvoke_1id(rootWindow, @"setRootViewController:", appViewController);
    objcInvoke_1int(appViewController, @"_setCurrentMode:", 2);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.50 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        objcInvoke(appViewController, @"resizeHostedAppForCarplayDisplay");
    });

    objcInvoke_1int(rootWindow, @"setHidden:", 0);

    currentlyHostedAppController = appViewController;
    return currentlyHostedAppController;
}

%end


%hook SBAppViewController

%new
- (void)dismiss {

    objcInvoke_1int(self, @"_setCurrentMode:", 0);

    id hostingWindow = objcInvoke(objcInvoke(self, @"view"), @"superview");
    objcInvoke(objcInvoke(self, @"view"), @"removeFromSuperview");
    objcInvoke_1int(hostingWindow, @"setHidden:", 1);

    hostingWindow = nil;
    currentlyHostedAppController = nil;
    lastOrientation = -1;
}

%new
- (void)resizeHostedAppForCarplayDisplay {

    id sharedApp = objcInvoke(objc_getClass("UIApplication"), @"sharedApplication");
    int deviceOrientation = objcInvokeT(sharedApp, @"statusBarOrientation", int);
    if (deviceOrientation == lastOrientation) {
        return;
    }
    lastOrientation = deviceOrientation;

    NSLog(@"resizeHostedAppForCarplayDisplay");

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

    if (deviceOrientation == 1 || deviceOrientation == 2) {
        // half width, full height
        NSLog(@"portait");
        widthScale = carplayDisplaySize.width / (mainScreenSize.width * 4);
        heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
        xOrigin = (([rootWindow frame].size.width / 4) + [rootWindow frame].origin.x);
    }
    else {
        NSLog(@"landscape");
        // full width and height
        widthScale = carplayDisplaySize.width / (mainScreenSize.width * 2);
        heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
        xOrigin = [rootWindow frame].origin.x;
    }

    NSLog(@"UIScreen size is %@, w scale: %f, %f, origin: %f", NSStringFromCGSize(mainScreenSize), widthScale, heightScale, xOrigin);
    [UIView animateWithDuration:0.2 animations:^(void) {
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
    if (currentlyHostedAppController && carplayExternalDisplay) {

        int deviceLocked = objcInvokeT(objcInvoke(objc_getClass("SpringBoard"), @"sharedApplication"), @"isLocked", int);
        if (deviceLocked == 0 && shouldRotate) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                objcInvoke(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay");
            });
        }
    }

    return shouldRotate;
}

%end


%hook FBScene

- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(void *)arg3 {

    if (currentlyHostedAppController != nil) {
        id sceneHandle = objcInvoke(currentlyHostedAppController, @"sceneHandle");
        id carplayHostedScene = objcInvoke(sceneHandle, @"scene");
        if (carplayHostedScene && [carplayHostedScene isEqual:self]) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(arg1, NSSelectorFromString(@"isForeground")) == NO) {
                return;
            }
        }
    }

    %orig;
}

%end
