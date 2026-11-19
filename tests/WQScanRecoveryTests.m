// Real process interruption and recovery with disposable filesystem fixtures.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#import "../WQScanTask.h"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static void child(NSString *mode, NSString *base, int expected)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    task.arguments = @[mode, base];
    check([task launchAndReturnError:nil], @"launch isolated recovery process");
    [task waitUntilExit];
    check(task.terminationStatus == expected, [@"child exit: " stringByAppendingString:mode]);
}
static void journalSymlinkProtection(void)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *key = @"measure:apps:/symlink-fixture";
    NSString *directory = WQScanJournalDirectory();
    NSString *preserved = [directory stringByAppendingFormat:@"-%@", NSUUID.UUID.UUIDString];
    NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check([files createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:nil], @"create unrelated checkpoint fixture");
    NSString *external = [outside stringByAppendingPathComponent:WQScanJournalPath(key).lastPathComponent];
    NSData *sentinel = [@"unrelated" dataUsingEncoding:NSUTF8StringEncoding];
    check([sentinel writeToFile:external atomically:YES], @"write unrelated checkpoint sentinel");
    check(rename(directory.fileSystemRepresentation, preserved.fileSystemRepresentation) == 0 &&
          symlink(outside.fileSystemRepresentation, directory.fileSystemRepresentation) == 0, @"redirect checkpoint directory fixture");
    @try {
        check(WQScanJournalLoad(key) == nil, @"checkpoint reads refuse symlink ancestry");
        check(!WQScanJournalSave(key, @{@"bytes": @12}), @"checkpoint writes refuse symlink ancestry");
        check(!WQScanJournalRemove(key) && !WQScanJournalRemoveScope(@"apps"), @"checkpoint deletion refuses symlink ancestry");
        WQScanJournalPrune(0);
        check([[NSData dataWithContentsOfFile:external] isEqual:sentinel], @"unrelated data survives checkpoint cleanup");
    } @finally {
        unlink(directory.fileSystemRepresentation);
        check(rename(preserved.fileSystemRepresentation, directory.fileSystemRepresentation) == 0, @"restore original checkpoint store");
    }
    NSString *entry = WQScanJournalPath(key);
    check(symlink(external.fileSystemRepresentation, entry.fileSystemRepresentation) == 0, @"redirect one checkpoint file");
    check(WQScanJournalLoad(key) == nil && WQScanJournalRemove(key), @"checkpoint link is refused for reading and unlinked safely");
    check([[NSData dataWithContentsOfFile:external] isEqual:sentinel], @"unlink leaves external link target unchanged");
    check([files createDirectoryAtPath:entry withIntermediateDirectories:YES attributes:nil error:nil], @"create unexpected checkpoint directory");
    NSString *child = [entry stringByAppendingPathComponent:@"sentinel"];
    check([sentinel writeToFile:child atomically:YES], @"write unexpected-directory sentinel");
    check(!WQScanJournalSave(key, @{@"bytes": @1}) && !WQScanJournalRemove(key), @"checkpoint operations refuse an unexpected directory");
    check([files fileExistsAtPath:child], @"checkpoint cleanup never recursively removes unexpected contents");
    [files removeItemAtPath:entry error:nil];
    NSString *orphan = [directory stringByAppendingPathComponent:[@".checkpoint-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    check([sentinel writeToFile:orphan atomically:YES], @"create interrupted checkpoint staging file");
    WQScanJournalPrune(7 * 24 * 60 * 60);
    check(![files fileExistsAtPath:orphan], @"startup discards orphaned checkpoint staging data");
    [files removeItemAtPath:outside error:nil];
}
static void legacyPrivacyMigration(void)
{
    NSString *finished = @"task:apps", *unfinished = @"task:clean";
    check(WQScanJournalSave(finished, @{@"identifier": @"old", @"unfinished": @NO,
                                       @"result": @{@"rows": @[@"old paths"]}, @"finishedAt": NSDate.date}), @"write legacy completed results");
    check(WQScanJournalSave(unfinished, @{@"identifier": @"resume-id", @"unfinished": @YES, @"userPaused": @YES,
                                         @"result": @{@"rows": @[@"old cached rows"]}, @"status": @"old status"}), @"write legacy paused results");
    check(WQScanJournalSave(@"measure:apps:/fixture", @{@"bytes": @12}), @"write completed scope residue");
    check(WQScanJournalSave(@"measure:clean:/fixture", @{@"pending": @[@"/fixture"], @"bytes": @7}), @"write unfinished measurement");
    NSString *legacy = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-container-scan.plist"];
    check([@{@"roots": @[@"old container paths"]} writeToFile:legacy atomically:YES], @"write legacy discovery cache");
    check(WQScanJournalPrepareKnownTasks(), @"migrate known task storage before opening tabs");
    check(WQScanJournalLoad(finished) == nil && WQScanJournalLoad(@"measure:apps:/fixture") == nil, @"completed state is removed without visiting Apps");
    NSDictionary *paused = WQScanJournalLoad(unfinished);
    check([paused isEqual:@{@"identifier": @"resume-id", @"unfinished": @YES, @"userPaused": @YES}], @"paused task keeps only recovery flags");
    check(WQScanJournalLoad(@"measure:clean:/fixture") != nil, @"unfinished measurement remains resumable");
    check(![NSFileManager.defaultManager fileExistsAtPath:legacy], @"old completed discovery cache is removed");
    WQScanJournalRemoveScope(@"clean");
    WQScanJournalRemove(unfinished);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc > 2) {
            NSString *mode = @(argv[1]), *base = @(argv[2]);
            if ([mode isEqual:@"measure-crash"]) {
                __block NSUInteger steps = 0;
                wq_measure_tree_resumable(base, @"recovery", @"job1", nil, NULL, ^(void (^work)(void)) {
                    if (++steps == 3) _exit(23); // root committed; first child has not been measured
                    work();
                });
                return 1;
            }
            if ([mode isEqual:@"measure-resume"]) {
                unsigned long long size = 0;
                check(wq_measure_tree_resumable(base, @"recovery", @"job1", nil, &size, ^(void (^work)(void)) { work(); }) == WQMeasureResultKnown,
                      @"resume after process termination");
                check(size == 12, @"completed root bytes reused, child counted once");
                return 0;
            }
            if ([mode isEqual:@"task-crash"]) {
                WQScanTask *task = [WQScanTask taskNamed:base];
                NSUInteger generation = [task beginFresh:YES cancel:^{}];
                [task finish:@{@"rows": @[@"old"]} generation:generation];
                [task beginFresh:YES cancel:^{}];
                _exit(24); // no termination callback: unfinished task is already durable
            }
            WQScanTask *task = [WQScanTask taskNamed:base];
            if ([mode isEqual:@"task-pause"]) {
                [task beginFresh:YES cancel:^{}];
                [task pause];
                return 0;
            }
            if ([mode isEqual:@"task-paused-reopen"]) {
                check(task.userPaused && !task.running && !task.interrupted, @"user pause survives restart without auto-resume");
                NSString *identifier = task.identifier;
                [task beginFresh:NO cancel:^{}];
                check([identifier isEqual:task.identifier], @"explicit resume retains paused task checkpoints");
                return 0;
            }
            if ([mode isEqual:@"task-resume"]) {
                check(task.interrupted && !task.running, @"new process distinguishes interrupted from running");
                NSString *identifier = task.identifier;
                check(task.result == nil, @"interrupted scan does not restore completed rows");
                NSUInteger generation = [task beginFresh:NO cancel:^{}];
                check([identifier isEqual:task.identifier], @"resume retains task identity");
                [task finish:@{@"rows": @[@"new"]} generation:generation];
            } else {
                check(!task.interrupted && !task.running && task.result == nil,
                      @"completed results are absent on another process launch");
            }
            return 0;
        }
        legacyPrivacyMigration();
        journalSymlinkProtection();
        NSString *base = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:[base stringByAppendingPathComponent:@"nested"] withIntermediateDirectories:YES attributes:nil error:nil];
        [@"12345" writeToFile:[base stringByAppendingPathComponent:@"one"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"1234567" writeToFile:[base stringByAppendingPathComponent:@"nested/two"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        child(@"measure-crash", base, 23);
        // Existing measured bytes may be historical; resume must not secretly redo them.
        [@"1234567890" writeToFile:[base stringByAppendingPathComponent:@"one"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        child(@"measure-resume", base, 0);
        unsigned long long size = 0;
        check(wq_measure_tree_resumable(base, @"recovery", @"job2", nil, &size, ^(void (^work)(void)) { work(); }) == WQMeasureResultKnown && size == 17,
              @"explicit fresh task recomputes changed bytes");
        NSString *old = [base stringByAppendingString:@"-old"];
        [fm moveItemAtPath:base toPath:old error:nil];
        [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:[base stringByAppendingPathComponent:@"replacement"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        check(wq_measure_tree_resumable(base, @"recovery", @"job2", nil, &size, ^(void (^work)(void)) { work(); }) == WQMeasureResultKnown && size == 1,
              @"replaced root rejects saved identity and byte count");
        child(@"task-crash", base, 24);
        child(@"task-resume", base, 0);
        child(@"task-completed", base, 0);
        child(@"task-pause", base, 0);
        child(@"task-paused-reopen", base, 0);
        WQScanTask *task = [WQScanTask taskNamed:[base stringByAppendingString:@"-generation"]];
        __block BOOL cancelled = NO;
        NSUInteger first = [task beginFresh:YES cancel:^{ cancelled = YES; }];
        check([task beginFresh:NO cancel:^{}] == 0, @"second screen joins existing work");
        NSUInteger second = [task beginFresh:YES cancel:^{}];
        check(cancelled, @"explicit refresh cancels old generation");
        [task finish:@{@"rows": @[@"obsolete"]} generation:first];
        check(task.running && !task.result, @"obsolete worker cannot replace active results");
        [task finish:@{@"rows": @[@"current"]} generation:second];
        NSUInteger failed = [task beginFresh:YES cancel:^{}];
        [task finish:@{@"rows": @[], @"complete": @NO, @"note": @"failed"} generation:failed];
        check([task.result[@"rows"] isEqual:@[@"current"]] && [task.status isEqual:@"failed"], @"failed refresh preserves successful results");
        NSString *failureName = [base stringByAppendingString:@"-write-failure"];
        NSString *failureKey = [@"task:" stringByAppendingString:failureName];
        NSString *failurePath = WQScanJournalPath(failureKey);
        [fm createDirectoryAtPath:failurePath withIntermediateDirectories:YES attributes:nil error:nil];
        WQScanTask *unsaved = [WQScanTask taskNamed:failureName];
        NSUInteger unsavedGeneration = [unsaved beginFresh:YES cancel:^{}];
        check(unsaved.persistenceFailed && unsaved.running, @"write failure is visible while the in-memory task is retained");
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [fm removeItemAtPath:failurePath error:nil];
        [unsaved finish:@{@"rows": @[@"saved"]} generation:unsavedGeneration];
        check(!unsaved.persistenceFailed && WQScanJournalLoad(failureKey) == nil, @"successful completion removes the journal and clears storage warning");
        wq_scan_set_paused(YES);
        WQScanCancellation *cancel = [WQScanCancellation new];
        [cancel cancel];
        check(!wq_scan_wait(cancel), @"cancel can release a paused worker");
        wq_scan_set_paused(NO);
        check(wq_scan_wait(nil), @"foreground releases scan gate");
        [fm removeItemAtPath:base error:nil];
        [fm removeItemAtPath:old error:nil];
        puts("All scan recovery tests passed.");
    }
    return 0;
}
