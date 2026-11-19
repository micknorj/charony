// App-data clearing policy for charony. GPL-3.0-or-later.
#import <Foundation/Foundation.h>
#import <sys/types.h>
BOOL CHClearAppData(NSString *container, NSString *bundleID, dev_t device, ino_t inode,
                    unsigned long long *freed, NSString **error);
