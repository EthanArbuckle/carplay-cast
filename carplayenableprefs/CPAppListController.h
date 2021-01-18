#import <Preferences/PSListController.h>

@interface CPAppListController : PSViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, retain) UITableView *rootTable;
@property (nonatomic, retain) NSArray *appList;
@property (nonatomic, retain) NSDictionary *cachedPreferences;

- (id)initWithAppList:(NSArray *)appList;

@end
