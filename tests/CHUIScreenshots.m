// Real UIKit state capture with disposable fixtures; never shipped in charony.
#import <UIKit/UIKit.h>
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#define WQ_CACHE_TESTING 1
#import "../WQCache.m"
static NSString *CHGalleryContainers;
static BOOL CHGalleryGrant(NSString *path)
{
    return [path hasPrefix:[CHGalleryContainers stringByAppendingString:@"/"]];
}
#define wq_grant CHGalleryGrant
#import "../CHAppData.m"
#undef wq_grant
#define main CHGalleryProductionMain
#import "../main.m"
#undef main

@interface WQAppsViewController (CHGallery)
- (void)clear:(id)item;
@end
@interface CHGalleryApps : WQAppsViewController
@end
@implementation CHGalleryApps
- (void)scan {} // Discovery is supplied by labelled fixtures, UI is inherited.
@end
@interface CHGalleryCaches : WQCacheCleanerViewController
@end
@implementation CHGalleryCaches
- (void)scan {}
@end

static NSString *CHControl(NSString *name)
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:name];
}
static void CHWrite(NSString *name, id value)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:CHControl(name) options:NSDataWritingAtomic error:nil];
}
static _Atomic BOOL CHHold, CHReached;
static dispatch_semaphore_t CHRelease;
static void CHArmOperation(void)
{
    CHRelease = dispatch_semaphore_create(0);
    atomic_store(&CHReached, NO);
    atomic_store(&CHHold, YES);
    wq_test_tree_hook = ^(NSString *stage, NSString *__unused path) {
        if ([stage isEqualToString:@"purgeBeforeUnlink"] && atomic_exchange(&CHHold, NO)) {
            atomic_store(&CHReached, YES);
            dispatch_semaphore_wait(CHRelease, DISPATCH_TIME_FOREVER);
        }
    };
}
static void CHReleaseOperation(void)
{
    atomic_store(&CHHold, NO);
    if (CHRelease) dispatch_semaphore_signal(CHRelease);
    wq_test_tree_hook = nil;
}
static UIViewController *CHTop(UIViewController *controller)
{
    for (;;) {
        if (controller.presentedViewController) controller = controller.presentedViewController;
        else if ([controller isKindOfClass:UITabBarController.class]) controller = ((UITabBarController *)controller).selectedViewController;
        else if ([controller isKindOfClass:UINavigationController.class]) controller = ((UINavigationController *)controller).topViewController;
        else return controller;
    }
}
static NSString *CHContainer(NSString *bundle)
{
    NSString *path = [CHGalleryContainers stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    for (NSString *part in @[@"Documents", @"Library/Caches", @"tmp"]) {
        NSString *directory = [path stringByAppendingPathComponent:part];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSMutableData dataWithLength:128 * 1024] writeToFile:[directory stringByAppendingPathComponent:@"disposable.bin"] atomically:YES];
    }
    [@{@"MCMMetadataIdentifier": bundle} writeToFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] atomically:YES];
    return path;
}
static NSDictionary *CHAppRow(NSString *name, NSString *bundle, NSString *path)
{
    struct stat st = {0};
    lstat(path.fileSystemRepresentation, &st);
    return @{@"name": name, @"bundleID": bundle, @"container": path, @"bytes": @(384 * 1024),
             @"sizeKnown": @YES, @"hasAccess": @YES, @"hasIdentity": @YES,
             @"containerDevice": @(st.st_dev), @"containerInode": @(st.st_ino)};
}
static WQCacheItem *CHCacheRow(NSString *name, NSString *bundle)
{
    NSString *container = CHContainer(bundle);
    WQCacheItem *item = [WQCacheItem new];
    item.name = name; item.bundleID = bundle; item.containerPath = container;
    item.targets = @[[container stringByAppendingPathComponent:@"Library/Caches"], [container stringByAppendingPathComponent:@"tmp"]];
    item.targetRecords = @[WQCacheTargetRecordForPath(item.targets[0], @"Library/Caches"), WQCacheTargetRecordForPath(item.targets[1], @"tmp")];
    WQCacheCaptureContainerIdentity(item);
    item.cacheBytes = 128 * 1024; item.tempBytes = 128 * 1024;
    item.cacheKnown = YES; item.tempKnown = YES;
    return item;
}

@interface CHGalleryScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CHTabs *tabs;
@property (nonatomic, strong) CHGalleryApps *apps;
@property (nonatomic, strong) CHGalleryCaches *caches;
@property (nonatomic, strong) NSArray *appRows;
@property (nonatomic, strong) NSArray<WQCacheItem *> *cacheRows;
@property (nonatomic, strong) NSMutableArray *steps;
@property (nonatomic, strong) NSMutableArray *missing;
@property (nonatomic) NSUInteger sequence;
@property (nonatomic) BOOL keyboardVisible;
@property (nonatomic, copy) dispatch_block_t afterCapture;
@property (nonatomic, strong) UISceneConnectionOptions *connectionOptions;
@end
@implementation CHGalleryScene
- (void)fail:(NSString *)reason
{
    CHReleaseOperation();
    CHWrite(@"capture-failed.json", @{@"reason":reason, @"sequence":@(self.sequence)});
}
- (void)later:(dispatch_block_t)block
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), block);
}
- (void)until:(BOOL (^)(void))condition attempts:(NSUInteger)remaining then:(dispatch_block_t)block
{
    if (condition()) { block(); return; }
    if (!remaining) { [self fail:@"A real controller/fixture transition timed out"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self until:condition attempts:remaining - 1 then:block]; });
}
- (void)next
{
    self.sequence++;
    if (self.sequence >= self.steps.count) {
        CHReleaseOperation();
        CHWrite(@"capture-done.json", @{@"states":@(self.steps.count), @"missing":self.missing,
            @"fixture":@YES, @"note":@"Actual UIKit screens; discovery and identities use disposable fixtures. No real sandbox-access validation."});
        return;
    }
    dispatch_block_t step = self.steps[self.sequence];
    step();
}
- (void)awaitAck:(NSString *)identifier
{
    NSString *ack = [NSString stringWithContentsOfFile:CHControl(@"capture-ack.txt") encoding:NSUTF8StringEncoding error:nil];
    if ([ack isEqualToString:identifier]) {
        [NSFileManager.defaultManager removeItemAtPath:CHControl(@"capture-ack.txt") error:nil];
        dispatch_block_t after = self.afterCapture;
        self.afterCapture = nil;
        if (after) after();
        [self later:^{ [self next]; }];
    } else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitAck:identifier]; });
}
- (void)offer:(NSString *)identifier title:(NSString *)title note:(NSString *)note
{
    [self later:^{
        [self.window layoutIfNeeded];
        NSDictionary *alerts=@{@"app-clear-confirmation":[NSString stringWithFormat:@"Clear %@?", [[[self.apps valueForKey:@"visibleApps"] firstObject] valueForKey:@"name"]], @"cache-clean-confirmation":@"Clean caches?", @"crash-reports-confirmation":@"Clean caches?", @"operation-in-progress":@"Operation in progress", @"cache-access-limited":@"Not cleanable", @"full-scan-consent":@"Scan app containers?"};
        NSString *expected=alerts[identifier];
        if(expected && ![CHTop(self.window.rootViewController).title isEqualToString:expected]) { [self fail:[@"Expected visible alert: " stringByAppendingString:expected]]; return; }
        CHWrite(@"capture-state.json", @{@"id":identifier, @"title":title, @"note":note ?: @"Disposable fixture data",
            @"sequence":@(self.sequence), @"fixture":@YES, @"keyboard_visible":@(self.keyboardVisible),
            @"appearance":@(self.window.traitCollection.userInterfaceStyle),
            @"content_size_category":self.window.traitCollection.preferredContentSizeCategory ?: @"unknown"});
        [self awaitAck:identifier];
    }];
}
- (void)dismiss
{
    [self.window.rootViewController dismissViewControllerAnimated:NO completion:nil];
    [self.apps dismissViewControllerAnimated:NO completion:nil];
    [self.caches dismissViewControllerAnimated:NO completion:nil];
}
- (void)showTab:(NSUInteger)index
{
    [self dismiss];
    UITab *tab = self.tabs.tabs[index];
    [self.tabs tabBarController:self.tabs shouldSelectTab:tab];
    self.tabs.selectedTab = tab;
    [self.window endEditing:YES];
}
- (void)publish:(NSString *)name rows:(NSArray *)rows note:(NSString *)note
{
    WQScanTask *task = [WQScanTask taskNamed:name];
    NSUInteger generation = [task beginFresh:YES cancel:^{}];
    [task finish:@{@"rows":rows, @"note":note ?: @"", @"complete":@YES} generation:generation];
}
- (void)seedApps
{
    NSString *first = CHContainer(@"com.example.gallery.notes");
    NSString *second = CHContainer(@"com.example.gallery.maps");
    self.appRows = @[CHAppRow(@"Example Notes (fixture)", @"com.example.gallery.notes", first), CHAppRow(@"Example Maps (fixture)", @"com.example.gallery.maps", second)];
    [self publish:@"apps" rows:self.appRows note:nil];
}
- (void)seedCaches
{
    // Match the controller reset performed when a real fresh scan begins.
    [self.caches setValue:@NO forKey:@"cleanRequiresRescan"];
    [self.caches setValue:nil forKey:@"result"];
    self.cacheRows = @[CHCacheRow(@"Example Notes (fixture)", @"com.example.gallery.notes"), CHCacheRow(@"Example Maps (fixture)", @"com.example.gallery.maps")];
    [self publish:@"clean" rows:[self.caches snapshotRows:self.cacheRows note:nil][@"rows"] note:nil];
}
- (void)search:(UIViewController<CHSearchable> *)controller query:(NSString *)query
{
    if (self.tabs.selectedTab != self.tabs.searchTab) {
        UITab *previous = self.tabs.selectedTab;
        [self.tabs tabBarController:self.tabs shouldSelectTab:self.tabs.searchTab];
        self.tabs.selectedTab = self.tabs.searchTab;
        [self.tabs tabBarController:self.tabs didSelectTab:self.tabs.searchTab previousTab:previous];
    }
    controller.contextSearchController.searchBar.text = query;
    [controller updateSearchResultsForSearchController:controller.contextSearchController];
    controller.contextSearchController.active = YES;
    [controller.contextSearchController.searchBar becomeFirstResponder];
}
- (void)advanceAction:(NSUInteger)index
{
    UIAlertController *alert = (UIAlertController *)CHTop(self.window.rootViewController);
    if (![alert isKindOfClass:UIAlertController.class] || index >= alert.actions.count) { [self fail:@"Expected a native alert action"]; return; }
    UIAlertAction *action = alert.actions[index];
    void (^handler)(UIAlertAction *) = nil;
    @try { handler = [action valueForKey:@"handler"]; } @catch (NSException *__unused exception) {}
    [alert dismissViewControllerAnimated:NO completion:^{
        if (handler) handler(action);
        else [self fail:@"UIKit did not expose the fixture-driven alert action; no outcome was invented"];
    }];
}
- (void)add:(dispatch_block_t)step { [self.steps addObject:[step copy]]; }
- (void)buildSteps
{
    [self add:^{ [self showTab:0]; [self publish:@"apps" rows:@[] note:nil]; [self offer:@"apps-initial" title:@"Apps — initial idle fixture" note:nil]; }];
    [self add:^{ WQScanTask *task=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[task beginFresh:YES cancel:^{}]; [task progress:@"Finding apps…" fraction:0.28 generation:g]; [self offer:@"apps-loading" title:@"Apps — first scan loading" note:@"Fixture scan progress, no completed app model"]; }];
    [self add:^{ [self seedApps]; [self offer:@"apps-populated" title:@"Apps — populated storage rows" note:@"Bundle IDs and sizes are for disposable fixture containers; there is no separate details screen"]; }];
    [self add:^{ [self publish:@"apps" rows:@[] note:nil]; [self offer:@"apps-empty" title:@"Apps — completed empty list" note:nil]; }];
    [self add:^{ WQScanTask *t=[WQScanTask taskNamed:@"apps"]; [t setValue:nil forKey:@"result"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t finish:@{@"rows":@[],@"complete":@NO,@"note":@"App discovery failed or was cancelled. Pull to refresh to try again."} generation:g]; [self offer:@"apps-error" title:@"Apps — discovery error" note:@"Injected discovery failure; actual controller error presentation"]; }];
    [self add:^{ [self seedApps]; [self search:self.apps query:@""]; [self offer:@"apps-search-active" title:@"Apps — native Search active" note:nil]; }];
    [self add:^{ [self search:self.apps query:@"Notes"]; [self offer:@"apps-search-results" title:@"Apps — search matches" note:nil]; }];
    [self add:^{ [self search:self.apps query:@"no-matching-fixture"]; [self offer:@"apps-search-no-results" title:@"Apps — search without matches" note:nil]; }];
    [self add:^{ [self showTab:0]; self.apps.contextSearchController.searchBar.text=@""; [self.apps updateSearchResultsForSearchController:self.apps.contextSearchController]; [self seedApps]; [self.apps tableView:self.apps.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]; [self offer:@"app-clear-confirmation" title:@"Apps — permanent clearing confirmation" note:@"Actual confirmation; no operation is accepted for this frame"]; }];
    [self add:^{ [self dismiss]; CHArmOperation(); [self.apps clear:[[self.apps valueForKey:@"visibleApps"] firstObject]]; [self until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ [self offer:@"app-clear-progress" title:@"Apps — deletion in progress" note:@"Real deletion of disposable files, paused at a safe fixture boundary for capture"]; }]; }];
    [self add:^{ (void)wq_begin_mutation(self.apps); self.afterCapture=^{ [self dismiss]; CHReleaseOperation(); }; [self offer:@"operation-in-progress" title:@"Concurrent operation refused" note:@"Actual cross-tab mutation reservation alert"]; }];
    [self add:^{ [self until:^BOOL{return [CHTop(self.window.rootViewController).title isEqualToString:@"Data cleared"];} attempts:150 then:^{ [self offer:@"app-clear-success" title:@"Apps — clear success" note:@"Actual disposable-file clear outcome; not protected-app validation"]; }]; }];
    [self add:^{ [self dismiss]; [self seedApps]; NSString *path=[[[self.apps valueForKey:@"visibleApps"] firstObject] valueForKey:@"container"]; [@{@"MCMMetadataIdentifier":@"com.example.changed"} writeToFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] atomically:YES]; [self.apps clear:[[self.apps valueForKey:@"visibleApps"] firstObject]]; [self until:^BOOL{return [CHTop(self.window.rootViewController).title isEqualToString:@"Clear incomplete"];} attempts:150 then:^{ [self offer:@"app-clear-failure" title:@"Apps — identity refusal" note:@"Real validator refuses changed fixture identity before deleting data"]; }]; }];
    [self add:^{ [self showTab:1]; [self publish:@"clean" rows:@[] note:nil]; [self offer:@"caches-initial" title:@"Caches — initial idle fixture" note:nil]; }];
    [self add:^{ WQScanTask *t=[WQScanTask taskNamed:@"clean"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t progress:@"Finding apps…" fraction:0.35 generation:g]; [self.caches setValue:@0.35 forKey:@"scanProgress"]; [self.caches.tableView reloadData]; [self offer:@"caches-loading" title:@"Caches — loading" note:@"Fixture-driven scan status"]; }];
    [self add:^{ [self seedCaches]; [self offer:@"caches-populated" title:@"Caches — populated, no selection" note:nil]; }];
    [self add:^{ for(NSUInteger i=0;i<2;i++) [self.caches tableView:self.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [self offer:@"caches-selected" title:@"Caches — manual multiple selection" note:nil]; }];
    [self add:^{ [self search:self.caches query:@""]; [self offer:@"caches-search-active" title:@"Caches — contextual Search active" note:nil]; }];
    [self add:^{ [self search:self.caches query:@"Maps"]; [self offer:@"caches-search-results" title:@"Caches — search matches" note:nil]; }];
    [self add:^{ [self search:self.caches query:@"no-matching-fixture"]; [self offer:@"caches-search-no-results" title:@"Caches — no search results" note:nil]; }];
    [self add:^{ [self showTab:1]; self.caches.contextSearchController.searchBar.text=@""; [self.caches updateSearchResultsForSearchController:self.caches.contextSearchController]; [self publish:@"clean" rows:@[] note:nil]; [self offer:@"caches-empty" title:@"Caches — completed empty list" note:nil]; }];
    [self add:^{ [self seedCaches]; self.cacheRows[0].limited=YES; [self.caches setValue:self.cacheRows forKey:@"items"]; [self.caches rebuildVisibleItems]; [self.caches.tableView reloadData]; [self.caches tableView:self.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]]; [self offer:@"cache-access-limited" title:@"Caches — limited-access refusal" note:@"Fixture limited flag drives the real refusal dialog"]; }];
    [self add:^{ [self dismiss]; [self seedCaches]; for(NSUInteger i=0;i<2;i++) [self.caches tableView:self.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [self.caches confirmClean]; [self offer:@"cache-clean-confirmation" title:@"Caches — one batch confirmation" note:nil]; }];
    [self add:^{ [self dismiss]; CHArmOperation(); NSArray *selected=[self.caches valueForKey:@"items"]; [self.caches cleanItems:selected generation:[[self.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [self until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ self.afterCapture=^{ CHReleaseOperation(); }; [self offer:@"cache-clean-progress" title:@"Caches — batch deletion in progress" note:@"Actual disposable-cache purge, held at a fixture boundary"]; }]; }];
    [self add:^{ [self until:^BOOL{return ![[self.caches valueForKey:@"cleaning"] boolValue] && [[self.caches valueForKey:@"result"] hasPrefix:@"Freed "];} attempts:150 then:^{ [self.caches.tableView reloadData]; [self offer:@"cache-clean-success" title:@"Caches — cleaning success" note:@"Actual disposable-file outcome; discovery rescans are fixture-driven"]; }]; }];
    [self add:^{ [self seedCaches]; CHArmOperation(); [self.caches cleanItems:self.cacheRows generation:[[self.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [self until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ [self.caches stopClean]; self.afterCapture=^{ CHReleaseOperation(); }; [self offer:@"cache-clean-stopping" title:@"Caches — Stop requested" note:@"Actual cooperative cancellation requested during disposable-file cleanup"]; }]; }];
    [self add:^{ [self until:^BOOL{return ![[self.caches valueForKey:@"cleaning"] boolValue] && [[self.caches valueForKey:@"result"] hasPrefix:@"Stopped."];} attempts:150 then:^{ [self.caches.tableView reloadData]; [self offer:@"cache-clean-stopped" title:@"Caches — cleaning stopped" note:@"Actual cancellation outcome; partial removal is possible and there is no rollback"]; }]; }];
    [self add:^{ [self seedCaches]; WQCacheItem *item=self.cacheRows[0]; NSString *saved=[item.containerPath stringByAppendingString:@"-preserved"]; rename(item.containerPath.fileSystemRepresentation,saved.fileSystemRepresentation); [NSFileManager.defaultManager createDirectoryAtPath:item.containerPath withIntermediateDirectories:YES attributes:nil error:nil]; [self.caches cleanItems:self.cacheRows generation:[[self.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [self until:^BOOL{return ![[self.caches valueForKey:@"cleaning"] boolValue] && [[self.caches valueForKey:@"result"] hasPrefix:@"Clean cancelled:"];} attempts:150 then:^{ [self offer:@"cache-clean-failure" title:@"Caches — changed-container failure" note:@"Real whole-batch preflight refusal; preserved fixture data is not deleted"]; }]; }];
    [self add:^{ [self seedCaches]; NSString *root=[CHGalleryContainers stringByAppendingPathComponent:@"DisposableCrashReporter"]; [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]; [@"disposable" writeToFile:[root stringByAppendingPathComponent:@"fixture.ips"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; WQCacheFixtureCrashRoots=@[root]; WQCacheItem *reports=[WQCacheItem new]; reports.name=@"Crash Logs"; reports.crashLogs=YES; reports.targets=@[root]; reports.targetRecords=@[WQCacheTargetRecordForPath(root,nil)]; reports.cacheKnown=YES; reports.tempKnown=YES; reports.cacheBytes=4096; [self publish:@"clean" rows:[self.caches snapshotRows:@[self.cacheRows[0],reports] note:nil][@"rows"] note:nil]; for(NSUInteger i=0;i<2;i++) [self.caches tableView:self.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [self offer:@"crash-reports-selected" title:@"Caches — app and crash reports selected" note:@"Crash Logs row uses an allowlisted disposable simulator directory"]; }];
    [self add:^{ [self.caches confirmClean]; self.afterCapture=^{[self dismiss];}; [self offer:@"crash-reports-confirmation" title:@"Caches — diagnostic-report confirmation" note:@"Actual mixed app/cache and Crash Logs warning; canceled after capture"]; }];
    [self add:^{ [self showTab:0]; [self seedApps]; WQScanTask *t=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.61 generation:g]; [self offer:@"scan-progress" title:@"Apps — scan progress" note:@"Fixture progress notifications"]; }];
    [self add:^{ [[WQScanTask taskNamed:@"apps"] pause]; [self offer:@"scan-paused" title:@"Apps — scan paused" note:@"Actual task pause state and Resume control"]; }];
    [self add:^{ WQScanTask *t=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[t beginFresh:NO cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.62 generation:g]; [self offer:@"scan-resumed" title:@"Apps — scan resumed" note:@"Same task identity, fixture worker progress"]; }];
    [self add:^{ [self showTab:1]; [self seedCaches]; WQScanTask *t=[WQScanTask taskNamed:@"clean"]; [t beginFresh:YES cancel:^{}]; [t pause]; [self offer:@"cache-scan-paused" title:@"Caches — scan paused" note:nil]; }];
    [self add:^{ WQScanTask *t=[WQScanTask taskNamed:@"clean"]; NSUInteger g=[t beginFresh:NO cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.62 generation:g]; [self offer:@"cache-scan-resumed" title:@"Caches — scan resumed" note:nil]; }];
    [self add:^{ [self showTab:0]; [self publish:@"apps" rows:@[] note:@"An App Group is required. Re-sign charony with a tool that preserves its App Group entitlement."]; [self offer:@"app-group-missing" title:@"Apps — missing App Group" note:@"Fixture result uses the actual application error wording"]; }];
    [self add:^{ atomic_store(&gAccessRecoveryNeeded,YES); wq_offer_access_recovery(self.apps); [self offer:@"access-cache-recovery" title:@"Conditional Reset Access Cache" note:@"Injected recoverable-cache flag; actual recovery interface"]; }];
    [self add:^{ [self advanceAction:1]; [self until:^BOOL{return [CHTop(self.window.rootViewController).title isEqualToString:@"Recovery incomplete"];} attempts:150 then:^{ [self offer:@"access-cache-reset-failure" title:@"Access Cache — recovery failure" note:@"Actual reset cannot obtain an App Group in the unsigned fixture environment"]; }]; }];
    [self add:^{ atomic_store(&gAccessRecoveryNeeded,NO); [self dismiss]; [self seedApps]; dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ (void)CHConfirmFullScan(@"the app folders",1200000,90); }); [self until:^BOOL{return [CHTop(self.window.rootViewController) isKindOfClass:UIAlertController.class];} attempts:150 then:^{ self.afterCapture=^{ [self advanceAction:0]; }; [self offer:@"full-scan-consent" title:@"Full inode scan consent" note:@"Real consent dialog with fixture estimate; canceled without scanning protected paths"]; }]; }];
    [self add:^{ [self dismiss]; [self seedApps]; NSString *failure=wq_access_capability_failure(); if(!failure){ [self.missing addObject:@{@"state":@"unsupported-build-startup",@"reason":@"This simulator host did not trigger the production capability failure"}]; [self next]; return; } UIWindow *original=self.window; CHSceneDelegate *blocked=[CHSceneDelegate new]; [blocked scene:original.windowScene willConnectToSession:original.windowScene.session options:self.connectionOptions]; self.window=blocked.window; self.afterCapture=^{ blocked.window.hidden=YES; self.window=original; [original makeKeyAndVisible]; }; [self offer:@"unsupported-build-startup" title:@"Production startup capability failure" note:@"Actual production startup view checks the simulator host kernel; this is not the target iPhone build"]; }];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session;
    self.connectionOptions=options;
    self.missing=[NSMutableArray new]; self.steps=[NSMutableArray new];
    [self.missing addObjectsFromArray:@[
        @{@"state":@"app-details",@"reason":@"No separate app-details screen exists; storage appears in Apps rows"},
        @{@"state":@"successful-real-App-Group-reset",@"reason":@"Simulator fixtures have no authorized protected App Group; actual device access is unverified"},
        @{@"state":@"real-protected-app-discovery",@"reason":@"Discovery and identities are disposable fixtures; no real user data or sandbox tokens"},
        @{@"state":@"sort-filter-menu-popup",@"reason":@"The controller exposes the native menu button; popup requires separate touch automation"}]];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    CHGalleryContainers=[WQCacheSafetyCanonicalPath(documents) stringByAppendingPathComponent:[@"GalleryFixtures-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:CHGalleryContainers withIntermediateDirectories:YES attributes:nil error:nil];
    CHTestApplicationRoot=CHGalleryContainers; WQCacheFixtureRoot=CHGalleryContainers;
    for(NSString *name in @[@"apps",@"clean"]) [self publish:name rows:@[] note:nil];
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.tabs=[CHTabs new]; self.window.rootViewController=self.tabs; [self.window makeKeyAndVisible]; [self.tabs loadViewIfNeeded];
    self.apps=[CHGalleryApps new]; self.caches=[CHGalleryCaches new];
    for(NSUInteger i=0;i<2;i++) { UINavigationController *nav=(UINavigationController *)self.tabs.tabs[i].viewController; nav.viewControllers=@[i==0?self.apps:self.caches]; }
    [self.apps loadViewIfNeeded]; [self.caches loadViewIfNeeded];
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note){self.keyboardVisible=YES;}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note){self.keyboardVisible=NO;}];
    wq_scan_lifecycle_install(); [self buildSteps]; self.sequence=0;
    [self later:^{ dispatch_block_t first=self.steps.firstObject; first(); }];
}
@end
@interface CHGalleryDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation CHGalleryDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)application;(void)options;
    UISceneConfiguration *configuration=[[UISceneConfiguration alloc] initWithName:@"Fixture state gallery" sessionRole:session.role];
    configuration.delegateClass=CHGalleryScene.class;
    return configuration;
}
@end
int main(int argc,char *argv[])
{
    @autoreleasepool {return UIApplicationMain(argc,argv,nil,NSStringFromClass(CHGalleryDelegate.class));}
}
