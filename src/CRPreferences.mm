#include "common.h"

@implementation CRPreferences

+ (instancetype)sharedInstance
{
    static CRPreferences *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CRPreferences alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    if ((self = [super init]))
    {
        [self reloadPreferences];
    }

    return self;
}

- (void)reloadPreferences
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:PREFERENCES_PLIST_PATH])
    {
        _cachedPreferences = [[NSDictionary alloc] initWithContentsOfFile:PREFERENCES_PLIST_PATH];
    }
    else {
        _cachedPreferences = @{};
    }
}

- (void)writePreferences
{
    [_cachedPreferences writeToFile:PREFERENCES_PLIST_PATH atomically:NO];
}

- (void)updateValue:(id)value forPreferenceKey:(NSString *)key
{
    NSMutableDictionary *copy = [_cachedPreferences mutableCopy];
    copy[key] = value;
    _cachedPreferences = copy;
    [self writePreferences];
}

- (NSArray *)excludedApplications
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"excludedApps"])
    {
        return [_cachedPreferences valueForKey:@"excludedApps"];
    }

    return @[@"com.netflix.Netflix", @"com.hulu.plus", @"com.amazon.aiv.AIVApp"];
}

- (CRDockAlignment)dockAlignment
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"dockAlignment"])
    {
        return (CRDockAlignment)[[_cachedPreferences valueForKey:@"dockAlignment"] intValue];
    }

    return CRDockAlignmentAuto;
}

- (BOOL)fiveColumnIconLayout
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"fiveColumnIconLayout"])
    {
        return [[_cachedPreferences valueForKey:@"fiveColumnIconLayout"] boolValue];
    }

    return YES;
}

@end