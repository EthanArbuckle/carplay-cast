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
			_appListController = [[CPAppListController alloc] initWithAppList:data[@"appList"]];
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
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	switch (section)
	{
		case 0:
			return 1;
		case 1:
			return 3;
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
			[cell setAccessoryType:UITableViewCellAccessoryCheckmark];
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
		default:
			break;
	}
	return @"";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	switch (section)
	{
		case 0:
			//return @"";
		case 1:
			return @"Created by Ethan Arbuckle";
		default:
			break;
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
			break;
		default:
			break;
	}

	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
