#include "../crash_reporting/reporting.h"
#include "../common.h"

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
/*
Given an FBSApplicationLibrary, force all apps within the library to show up on the CarPlay dashboard.
Exclude system apps (they are always glitchy for some reason) and enforce a blacklist.
If an app already supports CarPlay, leave it alone
*/
void addCarplayDeclarationsToAppLibrary(id appLibrary)
{
    // Load exluded apps from user's preferences
    NSArray *userExcludedApps = [[CRPreferences sharedInstance] excludedApplications];

    for (id appInfo in objcInvoke(appLibrary, @"allInstalledApplications"))
    {
        if (getIvar(appInfo, @"_carPlayDeclaration") == nil)
        {
            NSString *appBundleID = objcInvoke(appInfo, @"bundleIdentifier");
            // Skip system apps if the identifier contains "apple". The intention is to exclude all System/Stock apps, but jailbroken apps (Kodi) are
            // considered "System", so looking at the identifier is necessary
            if ([objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] == NO)
            {
                if ([appBundleID containsString:@"com.apple."])
                {
                    continue;
                }
            }

            // Skip if blacklisted
            if (userExcludedApps && [userExcludedApps containsObject:appBundleID])
            {
                continue;
            }

            // Create a fake declaration so this app appears to support carplay.
            id carplayDeclaration = [[objc_getClass("CRCarPlayAppDeclaration") alloc] init];
            // This is not template-driven -- important. Without specifying this, the process that hosts the Templates will continuously spin up
            // and crash, trying to find a non-existant template for this declaration
            objcInvoke_1(carplayDeclaration, @"setSupportsTemplates:", 0);
            objcInvoke_1(carplayDeclaration, @"setSupportsMaps:", 1);
            objcInvoke_1(carplayDeclaration, @"setBundleIdentifier:", appBundleID);
            objcInvoke_1(carplayDeclaration, @"setBundlePath:", objcInvoke(appInfo, @"bundleURL"));
            setIvar(appInfo, @"_carPlayDeclaration", carplayDeclaration);

            // Add a tag to the app, to keep track of which apps have been "forced" into carplay
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
    LOG_LIFECYCLE_EVENT;
    // %orig creates an app library that only contains Carplay-enabled stuff, so its not useful.
    // Create an app library that contains everything
    id allAppsConfiguration = [[objc_getClass("FBSApplicationLibraryConfiguration") alloc] init];
    objcInvoke_1(allAppsConfiguration, @"setApplicationInfoClass:", objc_getClass("CARApplicationInfo"));
    objcInvoke_1(allAppsConfiguration, @"setApplicationPlaceholderClass:", objc_getClass("FBSApplicationPlaceholder"));
    objcInvoke_1(allAppsConfiguration, @"setAllowConcurrentLoading:", 1);
    objcInvoke_1(allAppsConfiguration, @"setInstalledApplicationFilter:", ^BOOL(id appProxy, NSSet *arg2) {
        NSArray *appTags = objcInvoke(appProxy, @"appTags");
        // Skip apps with a Hidden tag
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
- (int)numberOfPortraitColumns
{
    int columns = %orig;
    if ([[CRPreferences sharedInstance] fiveColumnIconLayout])
    {
        columns = MAX(5, columns);
    }
    return columns;
}

/*
Make the Carplay dashboard icons a little smaller so 5 fit comfortably
*/
- (struct SBIconImageInfo)iconImageInfoForGridSizeClass:(unsigned long long)arg1
{
    struct SBIconImageInfo info = %orig;
    if ([[CRPreferences sharedInstance] fiveColumnIconLayout])
    {
        info.size = CGSizeMake(50, 50);
    }
    return info;
}

%end

/*
When an app is launched via Carplay dashboard
*/
%hook CARApplicationLaunchInfo

+ (id)launchInfoForApplication:(id)arg1 withActivationSettings:(id)arg2
{
    // An app is being launched. Use the attached tags to determine if carplay support has been coerced onto it
    if ([objcInvoke(arg1, @"tags") containsObject:@"CarPlayEnable"])
    {
        LOG_LIFECYCLE_EVENT;
        // Notify SpringBoard of the launch. SpringBoard will host the application + UI
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": objcInvoke(arg1, @"bundleIdentifier")}];

        // Add this item into the App History (so it shows up in the dock's "recents")
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

        // If there is already a native-Carplay app running, close it
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

    return %orig;
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

- (id)initWithEnvironment:(id)arg1
{
    id _self = %orig;
    // Register for Preference Changed notifications
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        // Reload the preferences from disk
        [[CRPreferences sharedInstance] reloadPreferences];
        if ([note.object isEqualToString:kPrefsAppLibraryChanged])
        {
            // Apps were added/removed - reload the app library
            id updatedLibrary = objcInvoke(objc_getClass("CARApplication"), @"_newApplicationLibrary");
            objcInvoke_1(self, @"setLibrary:", updatedLibrary);
            objcInvoke(self, @"_handleAppLibraryRefresh");
        }
        else if ([note.object isEqualToString:kPrefsIconLayoutChanged])
        {
            // 5 column dashboard was changed. Relayout dashboard icons
            objcInvoke(self, @"resetIconState");
        }
    }];

    return _self;
}

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

        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": bundleID}];

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
    id iconView = %orig;

    // Add long press gesture to the dashboard's icons
    UILongPressGestureRecognizer *launchGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:iconView action:NSSelectorFromString(@"handleLaunchAppInNormalMode:")];
    [launchGesture setMinimumPressDuration:1.5];
    [iconView addGestureRecognizer:launchGesture];

    return iconView;
}

%end

%end


%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"])
    {
        %init(CARPLAY);
        // Upload any relevant crashlogs
        symbolicateAndUploadCrashlogs();
    }
}