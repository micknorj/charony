#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp sentinel"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQAccessTreeTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            NSString *foreign = [base stringByAppendingPathComponent:@"foreign/Caches"];
            mkdirs(foreign);
            NSString *sentinel = [foreign stringByAppendingPathComponent:@"sentinel"];
            put(sentinel, @"outside");
            NSString *container = [base stringByAppendingPathComponent:@"container"];
            mkdirs(container);
            NSString *library = [container stringByAppendingPathComponent:@"Library"];
            check(symlink(foreign.stringByDeletingLastPathComponent.fileSystemRepresentation, library.fileSystemRepresentation) == 0, @"create symlinked Library");
            unsigned long long freed = 0;
            check(!wq_purge_contents_validated([library stringByAppendingPathComponent:@"Caches"], &freed, nil, nil) && has(sentinel, @"outside") && freed == 0, @"symlinked purge ancestry fails closed");
            check(!wq_purge_contents_validated([library stringByAppendingPathComponent:@"missing"], &freed, nil, nil), @"unsafe ancestry not treated as missing success");
            check(!wq_purge_contents_validated(library, &freed, nil, nil) && has(sentinel, @"outside"), @"symlinked final purge target refused");
            check(unlink(library.fileSystemRepresentation) == 0, @"remove fixture symlink");
            NSString *cache = [library stringByAppendingPathComponent:@"Caches"];
            mkdirs([cache stringByAppendingPathComponent:@"nested"]);
            put([cache stringByAppendingPathComponent:@"nested/file"], @"12345");
            check(symlink(foreign.fileSystemRepresentation, [cache stringByAppendingPathComponent:@"external-link"].fileSystemRepresentation) == 0, @"create child link to foreign tree");
            check(wq_purge_contents_validated(cache, &freed, nil, nil), @"safe purge completes");
            NSArray *remaining = [fm contentsOfDirectoryAtPath:cache error:nil];
            check(remaining != nil && remaining.count == 0 && freed >= 5, @"safe purge removes nested children and leaves root");
            check(has(sentinel, @"outside"), @"purge unlinks child symlink without following it");
            NSString *alias = [cache stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
            put([cache stringByAppendingPathComponent:@"alias-file"], @"alias");
            check(wq_purge_contents_validated(alias, &freed, nil, nil), @"canonical var alias accepted");
            check(wq_purge_contents_validated([cache stringByAppendingPathComponent:@"missing"], &freed, nil, nil), @"safe missing folder remains success");
            put([cache stringByAppendingPathComponent:@"retained"], @"keep");
            NSString *moved = [library stringByAppendingPathComponent:@"MovedCaches"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"purgeChild"] && [path isEqual:cache]) {
                    check(rename(cache.fileSystemRepresentation, moved.fileSystemRepresentation) == 0, @"swap purge root after listing");
                    check(symlink(foreign.fileSystemRepresentation, cache.fileSystemRepresentation) == 0, @"install foreign purge alias");
                }
            };
            check(!wq_purge_contents_validated(cache, &freed, nil, nil) && has([moved stringByAppendingPathComponent:@"retained"], @"keep") && has(sentinel, @"outside"), @"changed purge ancestry rejected before deleting listed child");
            wq_test_tree_hook = nil;

            NSString *cancelDir = [base stringByAppendingPathComponent:@"cancel-cache"];
            mkdirs(cancelDir);
            NSString *cancelSentinel = [cancelDir stringByAppendingPathComponent:@"sentinel"];
            put(cancelSentinel, @"keep");
            WQScanCancellation *cancellation = [WQScanCancellation new];
            [cancellation cancel];
            freed = 0;
            check(!wq_purge_contents_validated(cancelDir, &freed, cancellation, nil) && has(cancelSentinel, @"keep"),
                  @"cancelled purge leaves the tree intact");

            NSString *race = [base stringByAppendingPathComponent:@"leaf-race"];
            mkdirs(race);
            NSString *leaf = [race stringByAppendingPathComponent:@"selected"];
            put(leaf, @"original");
            NSString *original = [base stringByAppendingPathComponent:@"original-moved"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if (![stage isEqual:@"purgeBeforeUnlink"]) return;
                check(rename(path.fileSystemRepresentation, original.fileSystemRepresentation) == 0, @"move selected leaf after initial stat");
                put(path, @"replacement");
            };
            freed = 0;
            check(!wq_purge_contents_validated(race, &freed, nil, nil), @"late replacement refuses unlink");
            check(has(leaf, @"replacement") && has(original, @"original") && freed == 0, @"both leaf identities survive replacement refusal");
            wq_test_tree_hook = nil;

            NSString *midCancel = [base stringByAppendingPathComponent:@"mid-cancel"];
            mkdirs(midCancel);
            put([midCancel stringByAppendingPathComponent:@"one"], @"keep");
            put([midCancel stringByAppendingPathComponent:@"two"], @"keep");
            WQScanCancellation *during = [WQScanCancellation new];
            __block NSUInteger attempts = 0;
            wq_test_tree_hook = ^(NSString *stage, NSString *__unused path) {
                if ([stage isEqual:@"purgeBeforeUnlink"] && ++attempts == 2) [during cancel];
            };
            check(!wq_purge_contents_validated(midCancel, &freed, during, nil), @"cancellation immediately before unlink stops walk");
            check([fm contentsOfDirectoryAtPath:midCancel error:nil].count == 1, @"remaining sibling survives cancellation");
            wq_test_tree_hook = nil;
            check(wq_purge_contents_validated(midCancel, &freed, nil, nil), @"interrupted purge can be repeated");
            check(wq_purge_contents_validated(midCancel, &freed, nil, nil), @"completed purge is idempotent");

            NSString *denied = [base stringByAppendingPathComponent:@"validation-failure"];
            mkdirs(denied);
            put([denied stringByAppendingPathComponent:@"sentinel"], @"keep");
            __block BOOL allowed = YES;
            wq_test_tree_hook = ^(NSString *stage, NSString *__unused path) {
                if ([stage isEqual:@"purgeBeforeUnlink"]) allowed = NO;
            };
            check(!wq_purge_contents_validated(denied, &freed, nil, ^BOOL { return allowed; }), @"late validation refusal stops mutation");
            check(has([denied stringByAppendingPathComponent:@"sentinel"], @"keep"), @"late refusal preserves data");
            wq_test_tree_hook = nil;
            check(!wq_purge_contents_validated([denied stringByAppendingString:@"/../validation-failure"], &freed, nil, nil), @"purge rejects traversal grammar");
        } @finally {
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
        puts("All purge safety tests passed.");
    }
    return 0;
}
