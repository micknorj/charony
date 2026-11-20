// Disposable destructive fixtures only. GPL-3.0-or-later.
#define WQ_ACCESS_TESTING 1
#define wq_grant WQFixtureUpstreamGrant
#import "../WQAccess.m"
#undef wq_grant
static BOOL CHFixtureAccess = YES;
BOOL wq_grant(NSString *path) { (void)path; return CHFixtureAccess; }
#import "../CHAppData.m"
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void require(BOOL ok, NSString *message)
{
    if (!ok) { fprintf(stderr, "FAIL %s\n", message.UTF8String); exit(1); }
    printf("PASS %s\n", message.UTF8String);
}
static void put(NSString *path)
{
    require([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil], @"create disposable parent");
    require([[@"sentinel" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES], @"write disposable sentinel");
}
static BOOL exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
int main(void)
{
    @autoreleasepool {
        require(WQAppsSupportBundleIDValid(@"com.example.app") && WQAppsSupportBundleIDValid(@"com.example-app_1"), @"valid bundle grammar preserved");
        require(WQAppsSupportBundleIDValid(@"pinterest") && WQAppsSupportBundleIDValid(@"ifengNews"), @"real single-word identifiers are accepted");
        for (NSString *invalid in @[@"", @"ab", @"...", @"com/example", @"com..example", @".com.example",
                                    @"com.example.", @"com example.app", @"../escape"])
            require(!WQAppsSupportBundleIDValid(invalid), @"invalid bundle grammar refused");
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHTestApplicationRoot = [base stringByAppendingPathComponent:@"Application"];
        NSString *container = [CHTestApplicationRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *other = [CHTestApplicationRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *unrelated = [other stringByAppendingPathComponent:@"Documents/sentinel"];
        NSString *rootSentinel = [container stringByAppendingPathComponent:@"root-sentinel"];
        NSString *metadata = [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        @try {
            put(unrelated); put(rootSentinel);
            require([@{@"MCMMetadataIdentifier": @"com.example.fixture"} writeToFile:metadata atomically:YES], @"fixture identity");
            for (NSString *part in @[@"Documents", @"Library", @"tmp"]) put([container stringByAppendingPathComponent:[part stringByAppendingString:@"/data"]]);
            struct stat st;
            require(lstat(container.fileSystemRepresentation, &st) == 0, @"capture selection identity");
            require(CHAppContainerAllowed(container), @"canonical disposable app fixture is allowed");
            require([wq_container_label(container) isEqualToString:@"com.example.fixture"], @"fixture bundle identity is readable");
            unsigned long long freed = 0;
            NSString *error = nil;
            require(!CHClearAppData(container, @"com.example.other", st.st_dev, st.st_ino, &freed, &error), @"changed bundle identity refused");
            require(exists([container stringByAppendingPathComponent:@"Documents/data"]), @"identity refusal preserves data");
            require(!CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino + 1, &freed, &error), @"replaced inode refused");
            require(!CHClearAppData([container stringByAppendingString:@"/../escape"], @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error), @"traversal refused");
            CHFixtureAccess = NO;
            require(!CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error), @"inaccessible app refused");
            CHFixtureAccess = YES;
            NSString *library = [container stringByAppendingPathComponent:@"Library"];
            NSString *saved = [container stringByAppendingPathComponent:@"Library-saved"];
            require(rename(library.fileSystemRepresentation, saved.fileSystemRepresentation) == 0 && symlink(other.fileSystemRepresentation, library.fileSystemRepresentation) == 0, @"redirect Library fixture");
            require(!CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error), @"preflight rejects symlink before clearing any part");
            require(exists([container stringByAppendingPathComponent:@"Documents/data"]) && exists(unrelated), @"symlink refusal preserves selected and unrelated data");
            unlink(library.fileSystemRepresentation);
            rename(saved.fileSystemRepresentation, library.fileSystemRepresentation);
            error = nil;
            BOOL cleared = CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error);
            require(cleared, [NSString stringWithFormat:@"confirmed scope clears all three parts (%@)", error ?: @"no error"]);
            require(exists(rootSentinel) && exists(unrelated) && exists(metadata), @"root metadata and other app survive");
            for (NSString *part in @[@"Documents", @"Library", @"tmp"]) {
                NSArray *remaining = [fm contentsOfDirectoryAtPath:[container stringByAppendingPathComponent:part] error:nil];
                require(remaining != nil && remaining.count == 0, @"part roots preserved empty");
            }
            require(CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error), @"repeat clear is idempotent");
            NSString *oneWordFile = [container stringByAppendingPathComponent:@"Documents/one-word-data"];
            put(oneWordFile);
            require([@{@"MCMMetadataIdentifier": @"pinterest"} writeToFile:metadata atomically:YES], @"single-word identity fixture");
            require(CHClearAppData(container, @"pinterest", st.st_dev, st.st_ino, &freed, &error), @"single-word app clears through the real identity policy");
            require(!exists(oneWordFile) && exists(rootSentinel) && exists(unrelated) && exists(metadata), @"single-word clear preserves roots, metadata and unrelated app");
            require([@{@"MCMMetadataIdentifier": @"com.example.fixture"} writeToFile:metadata atomically:YES], @"restore fixture identity");
            put([container stringByAppendingPathComponent:@"Documents/again"]);
            __block BOOL swapped = NO;
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                (void)path;
                if (![stage isEqual:@"purgeChild"] || swapped) return;
                swapped = YES;
                [@{@"MCMMetadataIdentifier": @"com.example.changed"} writeToFile:metadata atomically:YES];
            };
            require(!CHClearAppData(container, @"com.example.fixture", st.st_dev, st.st_ino, &freed, &error), @"identity change during operation stops deletion");
            require(exists([container stringByAppendingPathComponent:@"Documents/again"]), @"interrupted clear retains next item");
            require(!exists([base stringByAppendingPathComponent:@"Backups"]) && !exists([base stringByAppendingPathComponent:@"AppBackups"]), @"no backup artifacts created");
        } @finally {
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
