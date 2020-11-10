#include <objc/message.h>

#define objcInvoke(a, b) ((id (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke_1id(a, b, c) ((id (*)(id, SEL, id))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_1int(a, b, c) ((id (*)(id, SEL, int))objc_msgSend)(a, NSSelectorFromString(b), c)

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

%hook SpringBoard

%new
- (id)hostAppOnCarplayUnit:(NSString *)identifier {

	id targetApp = objcInvoke_1id(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
	if (!targetApp) {
		NSLog(@"the requested app doesn't exist: %@", identifier);
		return nil;
	}


	id appSceneEntity = objcInvoke_1id([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationForMainDisplay:", targetApp);
	id appViewController = ((id (*)(id, SEL, NSString *, id))objc_msgSend)([objc_getClass("SBAppViewController") alloc], NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:"), identifier, appSceneEntity);

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
	id rootWindow = objcInvoke_1id([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);

	objcInvoke_1id(rootWindow, @"addSubview:", objcInvoke(appViewController, @"view"));
	objcInvoke_1int(appViewController, @"_setCurrentMode:", 2);

	objcInvoke(appViewController, @"resizeHostedAppForCarplayDisplay");

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
}

%new
- (void)resizeHostedAppForCarplayDisplay {
	
	id appSceneView = [[self valueForKey:@"_deviceAppViewController"] valueForKey:@"_sceneView"];
	UIView *hostingContentView = [appSceneView valueForKey:@"_sceneContentContainerView"];

	CGRect displayFrame = ((CGRect (*)(id, SEL))objc_msgSend)(carplayExternalDisplay, NSSelectorFromString(@"frame"));
	CGSize carplayDisplaySize = displayFrame.size;

	CGSize mainScreenSize = [[UIScreen mainScreen] bounds].size;
	CGFloat widthScale = carplayDisplaySize.width / (mainScreenSize.width * 2);
	CGFloat heightScale = carplayDisplaySize.height / (mainScreenSize.height * 2);
	[hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
}

%end


%hook UIWindow

- (BOOL)_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
	if (currentlyHostedAppController && carplayExternalDisplay) {
		objcInvoke(currentlyHostedAppController, @"resizeHostedAppForCarplayDisplay");
	}

	return %orig;
}

%end