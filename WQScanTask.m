#import "WQScanTask.h"
#import "WQScanJournal.h"

NSString *const WQScanTaskChangedNotification = @"WQScanTaskChanged";
static NSMutableDictionary *gTasks;
static BOOL gTasksPaused;
@implementation WQScanTask {
    void (^_cancel)(void);
}
+ (instancetype)taskNamed:(NSString *)name
{
    if (!NSThread.isMainThread) abort();
    if (!gTasks) {
        WQScanJournalPrune(7 * 24 * 60 * 60);
        WQScanJournalPrepareKnownTasks();
        gTasks = [NSMutableDictionary new];
        [NSNotificationCenter.defaultCenter addObserverForName:@"WQScanJournalWriteFailed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSString *key = note.object;
            for (WQScanTask *task in gTasks.allValues) {
                if ([key isEqual:[@"task:" stringByAppendingString:task.name]] ||
                    [key hasPrefix:[NSString stringWithFormat:@"measure:%@:", task.name]] ||
                    ([key hasPrefix:@"inodes:"] && task.running)) {
                    task->_persistenceFailed = YES;
                    [task notify];
                }
            }
        }];
    }
    WQScanTask *task = gTasks[name];
    if (task) return task;
    task = [WQScanTask new];
    task->_name = [name copy];
    NSDictionary *saved = WQScanJournalLoad([@"task:" stringByAppendingString:name]);
    task->_identifier = [saved[@"identifier"] isKindOfClass:NSString.class] ? saved[@"identifier"] : NSUUID.UUID.UUIDString;
    task->_result = nil;
    task->_finishedAt = nil;
    task->_userPaused = [saved[@"userPaused"] isEqual:@YES];
    task->_interrupted = [saved[@"unfinished"] isEqual:@YES] && !task->_userPaused;
    task->_status = task->_userPaused ? @"Scan paused" : @"";
    task->_paused = gTasksPaused;
    task->_fraction = -1;
    gTasks[name] = task;
    // Sanitize legacy task envelopes immediately, including user-paused tasks.
    [task save];
    return task;
}
+ (void)setPaused:(BOOL)paused
{
    if (!NSThread.isMainThread) abort();
    gTasksPaused = paused;
    for (WQScanTask *task in gTasks.allValues) { task->_paused = paused; [task notify]; }
}
- (void)save
{
    NSMutableDictionary *saved = [@{@"identifier": _identifier, @"unfinished": @(_running || _interrupted || _userPaused), @"userPaused": @(_userPaused)} mutableCopy];
    if (!_running && !_interrupted && !_userPaused) {
        _persistenceFailed = !WQScanJournalRemove([@"task:" stringByAppendingString:_name]);
        return;
    }
    if (!WQScanJournalSave([@"task:" stringByAppendingString:_name], saved)) {
        _persistenceFailed = YES;

    }
}
- (void)notify
{
    [NSNotificationCenter.defaultCenter postNotificationName:WQScanTaskChangedNotification object:self];
}
- (NSUInteger)beginFresh:(BOOL)fresh cancel:(void (^)(void))cancel
{
    if (!NSThread.isMainThread) abort();
    if (_running && !fresh) return 0;
    if (_cancel) _cancel();
    if (fresh || (!_interrupted && !_userPaused)) {
        WQScanJournalRemoveScope(_name);
        _identifier = NSUUID.UUID.UUIDString;
    }
    _generation++;
    _cancel = [cancel copy];
    _running = YES;
    _interrupted = NO;
    _userPaused = NO;
    _status = @"";
    _fraction = -1;
    [self save];
    [self notify];
    return _generation;
}
- (void)pause
{
    if (!NSThread.isMainThread) abort();
    if (!_running) return;
    if (_cancel) _cancel();
    _cancel = nil;
    _generation++;
    _running = NO;
    _interrupted = NO;
    _userPaused = YES;
    _status = @"Scan paused";
    _fraction = -1;
    [self save];
    [self notify];
}
- (void)progress:(NSString *)status generation:(NSUInteger)generation
{
    [self progress:status fraction:-1 generation:generation];
}
- (void)progress:(NSString *)status fraction:(float)fraction generation:(NSUInteger)generation
{
    if (!NSThread.isMainThread) abort();
    if (generation != _generation || !_running) return;
    _status = [status copy];
    _fraction = fraction;
    [self notify];
}
- (void)finish:(NSDictionary *)result generation:(NSUInteger)generation
{
    if (!NSThread.isMainThread) abort();
    if (generation != _generation || !_running) return;
    BOOL failed = [result[@"complete"] isEqual:@NO];
    if (!failed || !_result) {
        _result = [result copy];
        _finishedAt = NSDate.date;
    }
    _running = NO;
    _interrupted = failed;
    _cancel = nil;
    _status = failed && [result[@"note"] isKindOfClass:NSString.class] ? result[@"note"] : @"";
    BOOL cleaned = failed || WQScanJournalRemoveScope(_name);
    [self save];
    if (!cleaned) _persistenceFailed = YES;
    [self notify];
}
@end
