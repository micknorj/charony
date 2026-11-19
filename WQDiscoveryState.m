#import "WQDiscoveryState.h"
@implementation WQDiscoveryState {
    NSMutableDictionary *_values;
}
- (instancetype)init
{
    if ((self = [super init])) _values = [NSMutableDictionary new];
    return self;
}
- (id)objectForKey:(NSString *)key { @synchronized (self) { return _values[key]; } }
- (void)setObject:(id)value forKey:(NSString *)key { @synchronized (self) { _values[key] = value; } }
- (void)removeObjectForKey:(NSString *)key { @synchronized (self) { [_values removeObjectForKey:key]; } }
@end
WQDiscoveryState *wq_discovery_state(void)
{
    static WQDiscoveryState *state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ state = [WQDiscoveryState new]; });
    return state;
}
