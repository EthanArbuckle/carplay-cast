#import <Preferences/PSListController.h>
#include "CPAppListController.h"

@interface CRERootListController : PSViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, retain) UITableView *rootTable;
@property (nonatomic, retain) CPAppListController *appListController;

@end
