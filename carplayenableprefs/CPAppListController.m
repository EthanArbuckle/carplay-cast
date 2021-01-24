#include "CPAppListController.h"
#include "../src/common.h"

@implementation CPAppListController

- (id)initWithAppList:(NSArray *)appList
{
    if ((self = [super init]))
    {
        [self setTitle:@"Add or Remove Apps"];
        // Sort the list by app name
        NSSortDescriptor *nameDescriptor = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
        NSArray *sortDescriptors = [NSArray arrayWithObject:nameDescriptor];
        _appList = [appList sortedArrayUsingDescriptors:sortDescriptors];

        _rootTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, [[UIScreen mainScreen] bounds].size.height) style:UITableViewStyleGrouped];
        [_rootTable setDelegate:self];
        [_rootTable setDataSource:self];
        [[self view] addSubview:_rootTable];
    }

    return self;
}

- (BOOL)isAppCarplayEnabled:(NSString *)identifier
{
    NSArray *excludedApps = [[CRPreferences sharedInstance] excludedApplications];
    return [excludedApps containsObject:identifier] == NO;
}

- (void)setApp:(NSString *)identifier shouldBeExcluded:(BOOL)shouldExclude
{
    NSMutableArray *excludedApps = [[[CRPreferences sharedInstance] excludedApplications] mutableCopy];

    BOOL alreadyExcluded = [excludedApps containsObject:identifier];
    if (shouldExclude && !alreadyExcluded)
    {
        [excludedApps addObject:identifier];
    }
    else if (!shouldExclude && alreadyExcluded)
    {
        [excludedApps removeObject:identifier];
    }

    [[CRPreferences sharedInstance] updateValue:excludedApps forPreferenceKey:@"excludedApps"];

    // Notify CarPlay of the changes
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsAppLibraryChanged]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [_appList count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"com.carplay.rootcell"];
    if (cell == nil)
    {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"com.carplay.rootcell"];
    }

    // Get info about the current app
    NSDictionary *currentApp = _appList[indexPath.row];
    NSString *appName = currentApp[@"name"];
    NSString *appIdentifier = currentApp[@"bundleID"];
    UIImage *appIcon = [UIImage imageWithData:currentApp[@"iconImage"]];

    // Setup the cell
    [[cell textLabel] setText:appName];
    [[cell imageView] setImage:appIcon];
    if ([self isAppCarplayEnabled:appIdentifier])
    {
        [cell setAccessoryType:UITableViewCellAccessoryCheckmark];
    }
    else
    {
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @"Carplay enabled apps";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *chosenApp = _appList[indexPath.row];
    NSString *appIdentifier = chosenApp[@"bundleID"];

    BOOL isCurrentlyEnabled = [self isAppCarplayEnabled:appIdentifier];
    [self setApp:appIdentifier shouldBeExcluded:isCurrentlyEnabled];

    [self.rootTable reloadData];
}

@end
