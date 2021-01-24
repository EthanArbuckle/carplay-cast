#include "CRERootListController.h"
#include "../src/common.h"

@implementation CRERootListController

- (id)initForContentSize:(CGSize)size
{
    if ((self = [super init]))
    {
        [self setTitle:@"CarPlayEnable Preferences"];
        _rootTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, [[UIScreen mainScreen] bounds].size.height) style:UITableViewStyleGrouped];
        [_rootTable setDelegate:self];
        [_rootTable setDataSource:self];
        [[self view] addSubview:_rootTable];

        // The Preference process does not possess the necessary entitlements to fetch installed apps or icon data. Springboard will handle fetching the data - this process
        // will signal and receive the data via notifications
        NSOperationQueue *notificationQueue = [[NSOperationQueue alloc] init];
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataReceiving queue:notificationQueue usingBlock:^(NSNotification * _Nonnull note) {
            NSDictionary *data = [note userInfo];
            // Create AppList controller
            NSArray *appList = data[@"appList"];
            if (appList)
            {
                dispatch_sync(dispatch_get_main_queue(), ^(void) {
                    _appListController = [[CPAppListController alloc] initWithAppList:appList];
                });
            }
        }];

        // Ask Springboard for the app data. This may have a little delay, so its being fetched before the user opens the App List controller
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataRequesting]];
    }

    return self;
}

-(void)viewDidLoad
{
    [[self view] setBackgroundColor:[UIColor redColor]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section)
    {
        case 0:
            return 1;
        case 1:
            return 3;
        case 2:
            return 1;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"com.carplay.rootcell"];
    if (cell == nil)
    {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"com.carplay.rootcell"];
    }

    if (indexPath.section == 0)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"Add/Remove Apps"];
            [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
        }
    }
    else if (indexPath.section == 1)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"Left"];
        }
        else if (indexPath.row == 1)
        {
            [[cell textLabel] setText:@"Right"];
        }
        else if (indexPath.row == 2)
        {
            [[cell textLabel] setText:@"Auto"];
            
        }

        if (indexPath.row == [[CRPreferences sharedInstance] dockAlignment])
        {
            [cell setAccessoryType:UITableViewCellAccessoryCheckmark];
        }
        else
        {
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }
    }
    else if (indexPath.section == 2)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"5 Columns"];
            UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
            [cellSwitch setOn:[[CRPreferences sharedInstance] fiveColumnIconLayout] animated:NO];
            [cellSwitch addTarget:self action:@selector(iconLayoutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [cell setAccessoryView:cellSwitch];
        }
    }
    
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section)
    {
        case 0:
            return @"CarPlay Dashboard";
        case 1:
            return @"Dock Alignment";
        case 2:
            return @"Carplay Icons";
        default:
            break;
    }
    return @"";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == tableView.numberOfSections - 1)
    {
        return @"Created by Ethan Arbuckle";
    }
    return @"";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section)
    {
        case 0:
        {
            if (!_appListController)
            {
                // Have not received app data from SpringBoard yet..
                break;
            }
            // Push to the app list controller
            [[self navigationController] pushViewController:_appListController animated:YES];
            break;
        }
        case 1:
        {
            // Save the new setting
            [[CRPreferences sharedInstance] updateValue:@(indexPath.row) forPreferenceKey:@"dockAlignment"];
            // Notify CarPlay of the changes
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockAlignmentChanged]];
            break;
        }
        default:
            break;
    }

    [_rootTable reloadData];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)iconLayoutSwitchChanged:(UISwitch *)sender
{
    // Save the new setting
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:@"fiveColumnIconLayout"];
    // Notify CarPlay of the changes
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsIconLayoutChanged]];
}

@end
