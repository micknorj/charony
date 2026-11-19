// Thread-safe, process-local discovery hints. GPL-3.0-or-later.
#import <Foundation/Foundation.h>
@interface WQDiscoveryState : NSObject
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
@end
WQDiscoveryState *wq_discovery_state(void);
