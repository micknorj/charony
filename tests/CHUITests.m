// Fixture-driven UIKit controller harness, no real container operations.
#import <UIKit/UIKit.h>
#import "../WQScanTask.h"
#import "../WQApps.h"
#define WQ_CACHE_TESTING 1
#import "../WQCache.m"
#import "../WQUI.h"
static void marker(NSString *name)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    [@"ok" writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void check(BOOL condition, NSString *name)
{
    if (!condition) { marker([@"FAIL-" stringByAppendingString:name]); abort(); }
}
// Rescanning is supplied by fixtures. The real batch mutation implementation runs.
@interface CHFixtureCaches : WQCacheCleanerViewController
@end
@implementation CHFixtureCaches
- (void)scan {}
@end
@interface CHFixtureApps : WQAppsViewController
@end
@implementation CHFixtureApps
- (void)scan {}
@end
// Wait for genuine UIKit presentation before switching away from Search.
// The former synchronous test switched tabs before Search became active.
static void selectFixtureTab(UITabBarController *tabs, UITab *tab)
{
    if ([tabs.delegate tabBarController:tabs shouldSelectTab:tab]) {
        UITab *previous = tabs.selectedTab;
        tabs.selectedTab = tab;
        [tabs.delegate tabBarController:tabs didSelectTab:tab previousTab:previous];
    }
}
static void runActiveSearchNavigationFixtures(UITabBarController *tabs, WQAppsViewController *apps,
                                               UINavigationController *appsNav, dispatch_block_t next)
{
    UITab *search = tabs.tabs[2], *appsTab = tabs.tabs[0], *cachesTab = tabs.tabs[1];
    check([tabs.delegate tabBarController:tabs shouldSelectTab:search], @"search-selection-allowed");
    UITab *previous = tabs.selectedTab;
    tabs.selectedTab = search;
    [tabs.delegate tabBarController:tabs didSelectTab:search previousTab:previous];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UISearchController *controller = apps.contextSearchController;
        check(controller.active && apps.view.window != nil, @"search-is-actually-presented");
        controller.searchBar.text = @"no-match";
        [apps updateSearchResultsForSearchController:controller];
        check([apps.tableView numberOfRowsInSection:0] == 0, @"apps-search-filters-current-context");
        controller.searchBar.text = @"fixture";
        [apps updateSearchResultsForSearchController:controller];
        check([apps.tableView numberOfRowsInSection:0] == 1, @"bundle-and-name-search");
        selectFixtureTab(tabs, appsTab);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            check(tabs.selectedTab == appsTab && appsNav.topViewController == apps, @"same-search-context-restored");
            check(apps.view.window != nil && [apps.view isDescendantOfView:appsNav.view], @"apps-content-remains-visible-after-active-search");
            selectFixtureTab(tabs, search);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                check(controller.active && apps.view.window != nil, @"search-reopens-after-restoration");
                selectFixtureTab(tabs, cachesTab);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    check(tabs.selectedTab == cachesTab && appsNav.topViewController == apps, @"original-context-restored");
                    check(tabs.selectedViewController.view.window != nil, @"cache-content-visible-after-active-search");
                    next();
                });
            });
        });
    });
}
// Drive real scan notifications without container access. The original
// harness seeded a completed result before showing Apps, missing first scans.
static void runAppListStateFixtures(void)
{
    CHFixtureApps *controller = [CHFixtureApps new];
    [controller loadViewIfNeeded];
    WQScanTask *task = [WQScanTask taskNamed:@"apps"];
    NSUInteger generation = [task beginFresh:YES cancel:^{}];
    check([controller tableView:controller.tableView numberOfRowsInSection:0] == 0, @"first-app-scan-has-no-phantom-row");
    [controller.tableView reloadData];
    [controller.tableView layoutIfNeeded];
    [task finish:@{@"rows": @[], @"complete": @YES} generation:generation];
    check([controller tableView:controller.tableView numberOfRowsInSection:0] == 0, @"empty-completed-app-scan-is-safe");
    generation = [task beginFresh:YES cancel:^{}];
    check([controller tableView:controller.tableView numberOfRowsInSection:0] == 0, @"empty-app-refresh-has-no-phantom-row");
    NSDictionary *row = @{@"name": @"Read-only Fixture", @"bundleID": @"com.example.fixture", @"bytes": @123,
                          @"hasAccess": @YES, @"hasIdentity": @YES, @"sizeKnown": @YES};
    [task finish:@{@"rows": @[row], @"note": @"", @"complete": @YES} generation:generation];
    check([controller tableView:controller.tableView numberOfRowsInSection:0] == 1, @"completed-app-model-is-visible");
    check([[controller tableView:controller.tableView titleForHeaderInSection:0] containsString:@"1 app ·"], @"single-app-summary-uses-singular");
    generation = [task beginFresh:YES cancel:^{}];
    NSMutableDictionary *partial = [row mutableCopy];
    partial[@"sizeKnown"] = @NO;
    [task finish:@{@"rows": @[partial], @"note": @"", @"complete": @YES} generation:generation];
    check([[controller tableView:controller.tableView titleForHeaderInSection:0] containsString:@"size incomplete"], @"partial-app-total-does-not-claim-an-exact-size");
    generation = [task beginFresh:YES cancel:^{}];
    check([controller tableView:controller.tableView numberOfRowsInSection:0] == 1, @"refresh-keeps-real-app-row");
    UITableViewCell *cell = [controller tableView:controller.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    check([content.text isEqualToString:@"Read-only Fixture"], @"refresh-row-renders-existing-model");
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)[controller tableView:controller.tableView viewForFooterInSection:0];
    content = (UIListContentConfiguration *)footer.contentConfiguration;
    check(content.textProperties.numberOfLines == 0 && [content.text containsString:@"Safari and Messages"], @"apps-footer-wraps-the-complete-safety-guidance");
    [task finish:@{@"rows": @[], @"complete": @YES} generation:generation];
    generation = [task beginFresh:YES cancel:^{}];
    NSString *error = @"App discovery failed or was cancelled. Pull to refresh to try again.";
    [task finish:@{@"rows": @[], @"complete": @NO, @"note": error} generation:generation];
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)[controller tableView:controller.tableView viewForHeaderInSection:0];
    content = (UIListContentConfiguration *)header.contentConfiguration;
    check(content.textProperties.numberOfLines == 0 && [content.text isEqualToString:error], @"app-error-header-wraps-the-complete-retry-instruction");
}
static WQCacheItem *cacheFixture(NSString *root)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *container = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
    NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];
    for (NSString *path in @[caches, tmp]) {
        check([files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create-cache-fixture");
        check([@"disposable" writeToFile:[path stringByAppendingPathComponent:@"sentinel"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write-cache-fixture");
    }
    check([@{@"MCMMetadataIdentifier": @"com.example.fixture"} writeToFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] atomically:YES], @"cache-identity-fixture");
    WQCacheItem *item = [WQCacheItem new];
    item.name = @"Disposable";
    item.bundleID = @"com.example.fixture";
    item.containerPath = container;
    item.targets = @[caches, tmp];
    item.targetRecords = @[WQCacheTargetRecordForPath(caches, @"Library/Caches"), WQCacheTargetRecordForPath(tmp, @"tmp")];
    WQCacheCaptureContainerIdentity(item);
    item.selected = YES;
    return item;
}
static void waitForBatch(WQCacheCleanerViewController *controller, NSUInteger remaining, dispatch_block_t next)
{
    if (![[controller valueForKey:@"cleaning"] boolValue]) { next(); return; }
    check(remaining > 0, @"batch-completion-timeout");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        waitForBatch(controller, remaining - 1, next);
    });
}
static WQCacheItem *crashFixture(NSString *path)
{
    WQCacheItem *item = [WQCacheItem new];
    item.name = @"Disposable reports";
    item.crashLogs = YES;
    item.targets = @[path];
    item.targetRecords = @[WQCacheTargetRecordForPath(path, nil)];
    return item;
}
static void runCrashFixtures(NSString *root)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *allowed = [root stringByAppendingPathComponent:@"CrashReporter"];
    NSString *outside = [root stringByAppendingPathComponent:@"unrelated-reports"];
    for (NSString *path in @[allowed, outside]) {
        check([files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create-report-fixture");
        check([@"keep" writeToFile:[path stringByAppendingPathComponent:@"sentinel"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write-report-fixture");
    }
    WQCacheFixtureCrashRoots = @[allowed];
    WQCacheItem *reports = crashFixture(allowed);
    check(WQCacheValidateItem(reports, NULL), @"allowlisted-reports-accepted");
    check(!WQCacheValidateItem(crashFixture(outside), NULL), @"unrelated-report-directory-refused");
    WQCacheItem *forged = crashFixture(allowed);
    forged.targetRecords = @[WQCacheTargetRecordForPath(outside, nil)];
    check(!WQCacheValidateItem(forged, NULL), @"crash-target-record-mismatch-refused");
    forged.targetRecords = @[];
    forged.targets = @[];
    check(!WQCacheValidateItem(forged, NULL), @"empty-crash-state-refused-without-query");
    NSString *saved = [allowed stringByAppendingString:@"-saved"];
    check(rename(allowed.fileSystemRepresentation, saved.fileSystemRepresentation) == 0, @"replace-report-root");
    [files createDirectoryAtPath:allowed withIntermediateDirectories:YES attributes:nil error:nil];
    check(!WQCacheValidateItem(reports, NULL), @"changed-report-root-refused");
    [files removeItemAtPath:allowed error:nil];
    check(rename(saved.fileSystemRepresentation, allowed.fileSystemRepresentation) == 0, @"restore-original-report-root");
    NSString *link = [root stringByAppendingPathComponent:@"report-link"];
    check(symlink(root.fileSystemRepresentation, link.fileSystemRepresentation) == 0, @"create-report-ancestry-link");
    NSString *linkedTarget = [link stringByAppendingPathComponent:@"CrashReporter"];
    WQCacheFixtureCrashRoots = @[linkedTarget];
    check(!WQCacheValidateItem(crashFixture(linkedTarget), NULL), @"symlinked-report-ancestry-refused");
    WQCacheFixtureCrashRoots = @[allowed];
    WQScanCancellation *cancel = [WQScanCancellation new];
    [cancel cancel];
    unsigned long long freed = 0;
    check(!wq_purge_contents_validated(allowed, &freed, cancel, ^BOOL { return WQCacheValidateItem(reports, NULL); }), @"cancelled-report-clean-keeps-files");
    check([files fileExistsAtPath:[allowed stringByAppendingPathComponent:@"sentinel"]], @"cancelled-report-data-survives");
    check(wq_purge_contents_validated(allowed, &freed, nil, ^BOOL { return WQCacheValidateItem(reports, NULL); }), @"allowlisted-report-clean-succeeds");
    NSArray *remaining = [files contentsOfDirectoryAtPath:allowed error:nil];
    check(remaining != nil && remaining.count == 0, @"report-root-remains-empty");
    check([files fileExistsAtPath:[outside stringByAppendingPathComponent:@"sentinel"]], @"unrelated-reports-survive");
    check(wq_purge_contents_validated(allowed, &freed, nil, ^BOOL { return WQCacheValidateItem(reports, NULL); }), @"report-clean-repeat-is-safe");
    WQCacheItem *regular = cacheFixture(root);
    [files removeItemAtPath:regular.targets[0] error:nil];
    [@"file" writeToFile:regular.targets[0] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    regular.targetRecords = @[WQCacheTargetRecordForPath(regular.targets[0], @"Library/Caches"), regular.targetRecords[1]];
    check(!WQCacheValidateItem(regular, NULL), @"regular-file-cache-target-refused-at-preflight");
    check([WQCacheConfirmationScope(@[regular, regular, reports]) containsString:@"2 apps, plus Crash Logs"], @"batch-scope-counts-apps-and-reports");
    WQCacheFixtureCrashRoots = nil;
}
static void runCacheBatchFixtures(UIWindow *window, dispatch_block_t next)
{
    NSString *root = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    WQCacheFixtureRoot = root;
    WQCacheItem *first = cacheFixture(root), *second = cacheFixture(root), *unselected = cacheFixture(root);
    unselected.selected = NO;
    CHFixtureCaches *controller = [CHFixtureCaches new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [controller loadViewIfNeeded];
    [controller setValue:@[first, second, unselected] forKey:@"items"];
    check(WQCacheValidateItem(first, NULL), @"cache-fixture-validation");
    // Cancellation dismisses the confirmation without entering the mutation worker.
    [controller confirmClean];
    UIAlertController *confirmation = (UIAlertController *)controller.presentedViewController;
    check([confirmation isKindOfClass:UIAlertController.class], @"batch-confirmation-presented");
    NSUInteger destructive = 0, cancel = 0;
    for (UIAlertAction *action in confirmation.actions) {
        if (action.style == UIAlertActionStyleDestructive) destructive++;
        if (action.style == UIAlertActionStyleCancel) cancel++;
    }
    check(destructive == 1 && cancel == 1, @"one-batch-confirmation-and-cancel");
    [controller dismissViewControllerAnimated:NO completion:^{
        check([NSFileManager.defaultManager fileExistsAtPath:[first.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"cancel-preserves-cache-data");
        unselected.selected = YES; // Selection changes after the displayed confirmation.
        [controller cleanItems:@[first, second] generation:[[controller valueForKey:@"scanGeneration"] unsignedIntegerValue]];
        waitForBatch(controller, 200, ^{
            check(![[controller valueForKey:@"cleaning"] boolValue], @"batch-finished");
            for (WQCacheItem *item in @[first, second]) {
                for (NSString *target in item.targets) {
                    NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:target error:nil];
                    check(remaining != nil && remaining.count == 0, @"selected-cache-and-tmp-emptied");
                }
            }
            check([NSFileManager.defaultManager fileExistsAtPath:[unselected.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"unselected-app-untouched");
            check(![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"Backups"]], @"batch-no-backup-artifact");
            // Changed target identity refuses the entire batch before deleting an item.
            WQCacheItem *changed = cacheFixture(root), *safe = cacheFixture(root);
            [controller setValue:@[safe, changed] forKey:@"items"];
            NSString *moved = [changed.targets[0] stringByAppendingString:@"-old"];
            check(rename(changed.targets[0].fileSystemRepresentation, moved.fileSystemRepresentation) == 0, @"replace-cache-identity");
            [NSFileManager.defaultManager createDirectoryAtPath:changed.targets[0] withIntermediateDirectories:YES attributes:nil error:nil];
            [controller cleanItems:@[safe, changed] generation:[[controller valueForKey:@"scanGeneration"] unsignedIntegerValue]];
            waitForBatch(controller, 200, ^{
                check([[controller valueForKey:@"cleanRequiresRescan"] boolValue], @"changed-batch-requires-rescan");
                check([NSFileManager.defaultManager fileExistsAtPath:[safe.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"failed-preflight-keeps-other-selected-data");
                runCrashFixtures(root);
                CHFixtureCaches *stale = [CHFixtureCaches new];
                window.rootViewController = [[UINavigationController alloc] initWithRootViewController:stale];
                [stale loadViewIfNeeded];
                WQCacheItem *stillSafe = cacheFixture(root);
                [stale setValue:@[stillSafe] forKey:@"items"];
                [stale cleanItems:@[stillSafe] generation:[[stale valueForKey:@"scanGeneration"] unsignedIntegerValue] + 1];
                check(![[stale valueForKey:@"cleaning"] boolValue], @"stale-confirmation-does-not-start-worker");
                check([NSFileManager.defaultManager fileExistsAtPath:[stillSafe.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"stale-confirmation-preserves-data");
                [NSFileManager.defaultManager removeItemAtPath:root error:nil];
                next();
            });
        });
    }];
}
@interface CHFixtureScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) WQScanTask *lifecycleTask;
@property (nonatomic) BOOL waitingForForeground;
- (void)beginLifecycleValidation;
@end
@implementation CHFixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session; (void)options;
    if ([NSProcessInfo.processInfo.arguments containsObject:@"recover"]) {
        WQScanTask *apps = [WQScanTask taskNamed:@"apps"];
        WQScanTask *clean = [WQScanTask taskNamed:@"clean"];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *expectedID = [NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"lifecycle-id"] encoding:NSUTF8StringEncoding error:nil];
        check(apps.result == nil && !apps.interrupted, @"completed-app-rows-absent-after-relaunch");
        check(clean.interrupted && clean.result == nil && [clean.identifier isEqualToString:expectedID], @"unfinished-cache-task-recovered-without-completed-rows");
        NSUInteger generation = [clean beginFresh:NO cancel:^{}];
        check([clean.identifier isEqualToString:expectedID], @"relaunch-resume-preserves-task-identity");
        NSDictionary *row = @{@"name": @"Recovered Fixture", @"bundleID": @"com.example.fixture", @"hasAccess": @YES, @"hasIdentity": @YES, @"limited": @YES};
        [clean finish:@{@"rows": @[row], @"complete": @YES} generation:generation];
        generation = [apps beginFresh:YES cancel:^{}];
        [apps finish:@{@"rows": @[row], @"complete": @YES} generation:generation];
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        self.window.rootViewController = [NSClassFromString(@"CHTabs") new];
        [self.window makeKeyAndVisible];
        dispatch_async(dispatch_get_main_queue(), ^{
            UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
            UINavigationController *navigation = (UINavigationController *)tabs.selectedViewController;
            WQAppsViewController *controller = (WQAppsViewController *)navigation.topViewController;
            [controller loadViewIfNeeded];
            check([controller.tableView numberOfRowsInSection:0] == 1, @"rebuilt-apps-controller-shows-current-fixture");
            marker(@"recovery-passed");
        });
        return;
    }
    runAppListStateFixtures();
    NSDictionary *row = @{@"name": @"Disposable Fixture", @"bundleID": @"com.example.fixture", @"container": @"/fixture", @"containerPath": @"/fixture", @"hasAccess": @YES, @"hasIdentity": @YES, @"bytes": @123, @"cacheBytes": @123, @"limited": @YES};
    for (NSString *name in @[@"apps", @"clean"]) {
        WQScanTask *task = [WQScanTask taskNamed:name];
        NSUInteger generation = [task beginFresh:YES cancel:^{}];
        NSMutableDictionary *inaccessible = [row mutableCopy];
        inaccessible[@"hasAccess"] = @NO;
        NSArray *rows = [name isEqualToString:@"apps"] ? @[row, inaccessible] : @[row];
        [task finish:@{@"rows": rows, @"note": @"", @"complete": @YES} generation:generation];
    }
    wq_scan_lifecycle_install();
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UITabBarController *tabs = [NSClassFromString(@"CHTabs") new];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        check(tabs.tabs.count == 3 && [tabs.tabs[2] isKindOfClass:UISearchTab.class], @"two-content-tabs-and-native-search");
        UINavigationController *appsNav = (UINavigationController *)tabs.selectedViewController;
        WQAppsViewController *apps = (WQAppsViewController *)appsNav.topViewController;
        [apps loadViewIfNeeded];
        check([apps.tableView numberOfRowsInSection:0] == 1, @"accessible-app-visible-and-inaccessible-app-hidden");
        check(!apps.navigationItem.searchController, @"search-only-in-search-context");
        runActiveSearchNavigationFixtures(tabs, apps, appsNav, ^{
        UINavigationController *cacheNav = (UINavigationController *)tabs.selectedViewController;
        WQCacheCleanerViewController *caches = (WQCacheCleanerViewController *)cacheNav.topViewController;
        [caches loadViewIfNeeded];
        check([caches.tableView numberOfRowsInSection:1] == 1, @"apps-query-does-not-filter-caches");
        NSArray *items = [caches valueForKey:@"items"];
        WQSummaryCell *summary = (WQSummaryCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        check([summary.statusLabel.text containsString:@"selected"], @"empty-completed-cache-note-keeps-selection-summary-visible");
        [caches setValue:@"Freed fixture data." forKey:@"result"];
        summary = (WQSummaryCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        check([summary.statusLabel.text isEqualToString:@"Freed fixture data."], @"empty-completed-cache-note-keeps-clean-result-visible");
        [caches setValue:nil forKey:@"result"];
        id item = items.firstObject;
        NSNumber *cacheKnown = [item valueForKey:@"cacheKnown"];
        [item setValue:@NO forKey:@"cacheKnown"];
        summary = (WQSummaryCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        check([summary.captionLabel.text containsString:@"incomplete"], @"partial-cache-total-is-labelled-incomplete");
        [item setValue:cacheKnown forKey:@"cacheKnown"];
        [item setValue:@NO forKey:@"limited"];
        NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:1];
        WQCleanerCell *cacheCell = (WQCleanerCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check(cacheCell.isAccessibilityElement && [cacheCell.accessibilityValue isEqualToString:@"Not selected"], @"cache-row-exposes-unselected-state");
        check([cacheCell.accessibilityLabel containsString:@"Disposable Fixture"] && (cacheCell.accessibilityTraits & UIAccessibilityTraitButton), @"cache-row-groups-name-and-action");
        check(cacheCell.nameLabel.adjustsFontForContentSizeCategory && cacheCell.detailLabel.adjustsFontForContentSizeCategory && cacheCell.sizeLabel.adjustsFontForContentSizeCategory, @"cache-labels-follow-dynamic-type");
        [caches tableView:caches.tableView didSelectRowAtIndexPath:cacheRow];
        check([[item valueForKey:@"selected"] boolValue], @"manual-cache-selection");
        cacheCell = (WQCleanerCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Selected"] && (cacheCell.accessibilityTraits & UIAccessibilityTraitSelected), @"cache-row-exposes-selected-state");
        [caches tableView:caches.tableView didSelectRowAtIndexPath:cacheRow];
        check(![[item valueForKey:@"selected"] boolValue], @"manual-cache-deselection");
        cacheCell = (WQCleanerCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Not selected"] && !(cacheCell.accessibilityTraits & UIAccessibilityTraitSelected), @"cache-row-clears-selected-accessibility-state");
        [item setValue:@YES forKey:@"limited"];
        cacheCell = (WQCleanerCell *)[caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Access limited"], @"limited-cache-row-exposes-refusal-state");
        check(![[items.firstObject valueForKey:@"selected"] boolValue], @"cache-fixture-not-preselected");
        WQScanTask *task = [WQScanTask taskNamed:@"clean"];
        NSUInteger generation = [task beginFresh:YES cancel:^{}];
        [task pause];
        check(task.userPaused && !task.running, @"manual-pause");
        generation = [task beginFresh:NO cancel:^{}];
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
        check(task.paused && task.running, @"background-pause-state");
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
        [task finish:@{@"rows": @[row], @"complete": @YES} generation:generation];
        check(!task.paused && !task.running, @"foreground-completion-state");
        self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [self.window layoutIfNeeded];
        check(caches.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark, @"dark-appearance");
        self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        [self.window layoutIfNeeded];
        check(caches.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight, @"light-appearance");
        tabs.selectedTab = tabs.tabs[0];
        [self.window layoutIfNeeded];
        [apps tableView:apps.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIAlertController *clear = (UIAlertController *)apps.presentedViewController;
        check([clear isKindOfClass:UIAlertController.class], @"clear-data-confirmation");
        NSUInteger destructive = 0, cancel = 0;
        for (UIAlertAction *action in clear.actions) {
            if (action.style == UIAlertActionStyleDestructive) destructive++;
            if (action.style == UIAlertActionStyleCancel) cancel++;
        }
        check(destructive == 1 && cancel == 1, @"one-clear-data-confirmation-and-cancel");
        [apps dismissViewControllerAnimated:NO completion:^{
            runCacheBatchFixtures(self.window, ^{ [self beginLifecycleValidation]; });
        }];
        });
    });
}
- (void)beginLifecycleValidation
{
    self.lifecycleTask = [WQScanTask taskNamed:@"clean"];
    [self.lifecycleTask beginFresh:YES cancel:^{}];
    self.waitingForForeground = YES;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    check([NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil], @"create-lifecycle-fixture-directory");
    check([self.lifecycleTask.identifier writeToFile:[documents stringByAppendingPathComponent:@"lifecycle-id"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"record-fixture-task-identity");
    marker(@"ready-for-background");
}
- (void)sceneDidEnterBackground:(UIScene *)scene
{
    (void)scene;
    if (!self.waitingForForeground) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        check(self.lifecycleTask.paused && self.lifecycleTask.running, @"real-background-event-pauses-task");
        marker(@"background-paused");
    });
}
- (void)sceneDidBecomeActive:(UIScene *)scene
{
    (void)scene;
    if (!self.waitingForForeground) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        check(!self.lifecycleTask.paused && self.lifecycleTask.running, @"real-foreground-event-resumes-task");
        self.waitingForForeground = NO;
        marker(@"ready-to-terminate");
    });
}

@end
@interface CHFixtureDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation CHFixtureDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)application; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"fixtures" sessionRole:session.role];
    configuration.delegateClass = CHFixtureScene.class;
    return configuration;
}
@end
int main(int argc, char *argv[])
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CHFixtureDelegate.class)); }
}
