#include "common.h"

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


/*
App icons on the Carplay dashboard.
For apps that natively support Carplay, add a longpress gesture to launch it in "full mode". Tapping them
will launch their normal Carplay mode UI
*/
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


%ctor {
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"CarPlay"])
    {
        %init(CARPLAY);
    }
}