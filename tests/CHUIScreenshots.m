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
static _Atomic BOOL CHHold, CHReached, CHReleased;
static dispatch_semaphore_t CHRelease;
static void CHArmOperation(void)
{
    CHRelease = dispatch_semaphore_create(0);
    atomic_store(&CHReached, NO);
    atomic_store(&CHReleased, NO);
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
    atomic_store(&CHReleased, YES);
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
static UIScrollView *CHScrollableWarning(UIView *view)
{
    if (view.hidden || view.alpha < 0.01) return nil;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGFloat bottom = MAX(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.size.height + scroll.adjustedContentInset.bottom);
        if (scroll.scrollEnabled && scroll.bounds.size.height > 20 && bottom - scroll.contentOffset.y > 1)
            return scroll;
    }
    for (UIView *child in view.subviews) {
        UIScrollView *scroll = CHScrollableWarning(child);
        if (scroll) return scroll;
    }
    return nil;
}
static BOOL CHHasMenuView(UIView *view)
{
    if (view.hidden || view.alpha < 0.01) return NO;
    if ([NSStringFromClass(view.class) containsString:@"ContextMenu"] && view.window && view.bounds.size.width > 1) return YES;
    for (UIView *child in view.subviews) if (CHHasMenuView(child)) return YES;
    return NO;
}
static void CHMenuInteractions(UIView *view, NSMutableArray<UIContextMenuInteraction *> *found)
{
    for (id<UIInteraction> interaction in view.interactions)
        if ([(id)interaction isKindOfClass:UIContextMenuInteraction.class]) [found addObject:(id)interaction];
    for (UIView *child in view.subviews) CHMenuInteractions(child, found);
}
static BOOL CHActivateMenu(UIView *view)
{
    for (UIView *child in view.subviews) if (CHActivateMenu(child)) return YES;
    return [view isKindOfClass:UIControl.class] && [view accessibilityActivate];
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
@property (nonatomic) NSUInteger captureOrdinal, warningPage;
@property (nonatomic, copy) NSString *captureIdentifier, *captureTitle, *captureNote;
@property (nonatomic) BOOL keyboardVisible;
@property (nonatomic) BOOL keepAlertAfterCapture;
@property (nonatomic) BOOL pendingUIAction;
@property (nonatomic, copy) dispatch_block_t afterCapture;
@property (nonatomic, strong) UISceneConnectionOptions *connectionOptions;
@end
@implementation CHGalleryScene
- (void)fail:(NSString *)reason
{
    UIViewController *top = CHTop(self.window.rootViewController);
    NSDictionary *details = @{@"reason":reason, @"sequence":@(self.sequence),
        @"topClass":NSStringFromClass(top.class) ?: @"nil", @"topTitle":top.title ?: @"nil",
        @"appsVisible":@(self.apps.view.window != nil), @"appsIsTop":@(self.apps.navigationController.topViewController == self.apps),
        @"appBusy":[self.apps valueForKey:@"busy"] ?: @NO,
        @"pendingClearTitle":[self.apps valueForKey:@"pendingClearTitle"] ?: @"nil",
        @"pendingClearMessage":[self.apps valueForKey:@"pendingClearMessage"] ?: @"nil",
        @"cacheCleaning":[self.caches valueForKey:@"cleaning"] ?: @NO,
        @"cacheResult":[self.caches valueForKey:@"result"] ?: @"nil",
        @"operationReached":@(atomic_load(&CHReached)), @"operationReleased":@(atomic_load(&CHReleased)),
        @"pendingUIAction":@(self.pendingUIAction), @"missing":self.missing ?: @[]};
    CHWrite(@"capture-failed.json", details);
    CHReleaseOperation();
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
        UIViewController *top = CHTop(self.window.rootViewController);
        UIScrollView *warning = [top isKindOfClass:UIAlertController.class] ? CHScrollableWarning(top.view) : nil;
        if (warning) {
            if (self.warningPage >= 30) { [self fail:@"Native warning scrolling did not reach the end"]; return; }
            CGFloat bottom = MAX(-warning.adjustedContentInset.top,
                warning.contentSize.height - warning.bounds.size.height + warning.adjustedContentInset.bottom);
            CGFloat previous = warning.contentOffset.y;
            [warning setContentOffset:CGPointMake(warning.contentOffset.x,
                MIN(bottom, previous + warning.bounds.size.height * 0.8)) animated:NO];
            [warning layoutIfNeeded];
            if (warning.contentOffset.y <= previous + 0.5) { [self fail:@"Native warning refused the required scroll"]; return; }
            self.warningPage++;
            [self later:^{ [self publishCapture]; }];
            return;
        }
        dispatch_block_t after = self.afterCapture;
        self.afterCapture = nil;
        BOOL keepAlert = self.keepAlertAfterCapture;
        self.keepAlertAfterCapture = NO;
        dispatch_block_t advance = ^{
            if (after) after();
            [self later:^{
                [self until:^BOOL { return !self.pendingUIAction; } attempts:150 then:^{ [self next]; }];
            }];
        };
        // A held mutation may finish as soon as `after` releases it. The
        // preceding alert must have fully dismissed before that happens.
        if (keepAlert) advance();
        else [self dismissThen:advance];
    } else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitAck:identifier]; });
}
- (void)publishCapture
{
    NSString *identifier = self.warningPage ? [self.captureIdentifier stringByAppendingFormat:@"-scroll-%lu", (unsigned long)self.warningPage] : self.captureIdentifier;
    NSString *title = self.warningPage ? [self.captureTitle stringByAppendingFormat:@" — warning scrolled %lu", (unsigned long)self.warningPage] : self.captureTitle;
    NSString *note = self.warningPage ? [self.captureNote stringByAppendingString:@"; actual native alert scrolled to expose additional warning text"] : self.captureNote;
    CHWrite(@"capture-state.json", @{@"id":identifier, @"base_id":self.captureIdentifier, @"title":title, @"note":note,
        @"sequence":@(++self.captureOrdinal), @"fixture_step":@(self.sequence), @"alert_scroll_page":@(self.warningPage),
        @"fixture":@YES, @"keyboard_visible":@(self.keyboardVisible),
        @"appearance":@(self.window.traitCollection.userInterfaceStyle),
        @"content_size_category":self.window.traitCollection.preferredContentSizeCategory ?: @"unknown"});
    [self awaitAck:identifier];
}
- (void)offer:(NSString *)identifier title:(NSString *)title note:(NSString *)note
{
    [self later:^{
        [self.window layoutIfNeeded];
        NSDictionary *alerts=@{@"app-clear-confirmation":[NSString stringWithFormat:@"Clear %@?", [[[self.apps valueForKey:@"visibleApps"] firstObject] valueForKey:@"name"]], @"cache-clean-confirmation":@"Clean caches?", @"cache-selection-changed":@"Selection changed", @"crash-reports-confirmation":@"Clean caches?", @"crash-reports-only-confirmation":@"Clean caches?", @"operation-in-progress":@"Operation in progress", @"app-clear-deferred-blocker":@"Operation in progress", @"app-clear-result-deferred":@"Operation in progress", @"app-clear-deferred-success":@"Data cleared", @"cache-access-limited":@"Not cleanable", @"full-scan-consent":@"Scan app containers?", @"app-clear-success":@"Data cleared", @"app-clear-failure":@"Clear incomplete", @"access-cache-recovery":@"Access cache needs recovery", @"access-cache-reset-failure":@"Recovery incomplete"};
        NSString *expected=alerts[identifier];
        if (!expected && ![identifier isEqualToString:@"unsupported-build-startup"] && ![identifier isEqualToString:@"apps-sort-filter-menu"]) {
            UIViewController *visible = CHTop(self.window.rootViewController);
            if ([visible isKindOfClass:UISearchController.class]) visible = self.tabs.searchRoot;
            if (visible != self.apps && visible != self.caches) { [self fail:@"Expected a real Apps/Caches controller on screen"]; return; }
            if (!visible.view.window) { [self fail:@"Apps/Caches controller is detached after navigation"]; return; }
        }
        if(expected && ![CHTop(self.window.rootViewController).title isEqualToString:expected]) { [self fail:[NSString stringWithFormat:@"Expected visible alert %@; found %@", expected, CHTop(self.window.rootViewController).title]]; return; }
        self.captureIdentifier = identifier;
        self.captureTitle = title;
        self.captureNote = note ?: @"Disposable fixture data";
        self.warningPage = 0;
        [self publishCapture];
    }];
}
- (void)dismissThen:(dispatch_block_t)completion
{
    UIViewController *top = CHTop(self.window.rootViewController);
    if ([top isKindOfClass:UIAlertController.class]) {
        self.pendingUIAction = YES;
        [top dismissViewControllerAnimated:NO completion:^{
            self.pendingUIAction = NO;
            if (completion) completion();
        }];
    } else if (completion) completion();
}
- (void)dismiss
{
    [self dismissThen:nil];
}

- (void)showTab:(NSUInteger)index
{
    [self dismiss];
    UITab *tab = self.tabs.tabs[index];
    if ([self.tabs tabBarController:self.tabs shouldSelectTab:tab])
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
- (void)seedAlphabetApps
{
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger i = 0; i < 26; i++) {
        NSString *letter = [NSString stringWithFormat:@"%c", 'A' + (int)i];
        NSString *bundle = [@"com.example.gallery." stringByAppendingString:letter.lowercaseString];
        [rows addObject:CHAppRow([letter stringByAppendingString:@" Example (fixture)"], bundle, CHContainer(bundle))];
    }
    self.appRows = rows;
    [self.apps setValue:@YES forKey:@"sortByName"];
    [self publish:@"apps" rows:rows note:nil];
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
    self.pendingUIAction = YES;
    [alert dismissViewControllerAnimated:NO completion:^{
        self.pendingUIAction = NO;
        if (handler) handler(action);
        else [self fail:@"UIKit did not expose the fixture-driven alert action; no outcome was invented"];
    }];
}
- (void)captureFilterMenu
{
    UIView *button = nil;
    for (UIBarButtonItem *item in self.apps.navigationItem.rightBarButtonItems) {
        if (!item.menu.children.count) continue;
        @try { button = [item valueForKey:@"view"]; } @catch (NSException *__unused exception) {}
    }
    NSMutableArray<UIContextMenuInteraction *> *interactions = [NSMutableArray new];
    if (button) { CHMenuInteractions(button, interactions); (void)CHActivateMenu(button); }
    [self later:^{
        BOOL visible = NO;
        for (UIWindow *window in self.window.windowScene.windows)
            if (!window.hidden && CHHasMenuView(window)) visible = YES;
        if (!visible) {
            for (UIContextMenuInteraction *interaction in interactions) [interaction dismissMenu];
            [self.missing addObject:@{@"state":@"sort-filter-menu-popup", @"reason":@"The native button did not expose a visible menu through accessibility activation; no replacement menu was constructed"}];
            [self next];
            return;
        }
        self.afterCapture = ^{ for (UIContextMenuInteraction *interaction in interactions) [interaction dismissMenu]; };
        [self offer:@"apps-sort-filter-menu" title:@"Apps — native Sort and Filter menu" note:@"Actual production bar-button menu, opened through accessibility activation"];
    }];
}
- (void)captureAccessibleCacheRows:(NSString *)identifier title:(NSString *)title
{
    if (!UIContentSizeCategoryIsAccessibilityCategory(self.window.traitCollection.preferredContentSizeCategory)) {
        [self next]; // Extra scroll frame is only meaningful for enlarged rows.
        return;
    }
    UITableView *table = self.caches.tableView;
    CGPoint original = table.contentOffset;
    [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    self.afterCapture = ^{ [table setContentOffset:original animated:NO]; };
    [self offer:identifier title:title note:@"Actual table scrolled to the enlarged cache rows; summary is captured separately"];
}
- (void)add:(dispatch_block_t)step { [self.steps addObject:[step copy]]; }
- (void)buildSteps
{
    __weak CHGalleryScene *gallery = self;
    [gallery add:^{ [gallery showTab:0]; [gallery publish:@"apps" rows:@[] note:nil]; [gallery offer:@"apps-initial" title:@"Apps — initial idle fixture" note:nil]; }];
    [gallery add:^{ WQScanTask *task=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[task beginFresh:YES cancel:^{}]; [task progress:@"Finding apps…" fraction:0.28 generation:g]; [gallery offer:@"apps-loading" title:@"Apps — first scan loading" note:@"Fixture scan progress, no completed app model"]; }];
    [gallery add:^{ [gallery seedApps]; [gallery offer:@"apps-populated" title:@"Apps — populated storage rows" note:@"Bundle IDs and sizes are for disposable fixture containers; there is no separate details screen"]; }];
    [gallery add:^{
        UITableView *table = gallery.apps.tableView;
        [table layoutIfNeeded];
        CGFloat bottom = MAX(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
        if (bottom <= table.contentOffset.y + 1) { [gallery next]; return; }
        CGPoint original = table.contentOffset;
        [table setContentOffset:CGPointMake(original.x, bottom) animated:NO];
        gallery.afterCapture = ^{ [table setContentOffset:original animated:NO]; };
        [gallery offer:@"apps-safety-guidance-scrolled" title:@"Apps — guidance after the list" note:@"Actual nonfloating safety footer reached by scrolling the table"];
    }];
    [gallery add:^{ [gallery captureFilterMenu]; }];
    [gallery add:^{ [gallery seedAlphabetApps]; gallery.afterCapture=^{[gallery.apps setValue:@NO forKey:@"sortByName"];}; [gallery offer:@"apps-alphabet-index" title:@"Apps — name sort and alphabet index" note:@"26 distinct disposable containers; actual alphabetical sidebar appears for name-sorted lists of at least 25 rows"]; }];
    [gallery add:^{ NSMutableArray *rows=[gallery.appRows mutableCopy]; NSMutableDictionary *partial=[rows[0] mutableCopy]; partial[@"sizeKnown"]=@NO; rows[0]=partial; [gallery publish:@"apps" rows:rows note:nil]; [gallery offer:@"apps-storage-incomplete" title:@"Apps — incomplete storage measurement" note:@"Fixture measurement has unknown portions; aggregate must be labelled incomplete"]; }];
    [gallery add:^{ [gallery publish:@"apps" rows:@[] note:nil]; [gallery offer:@"apps-empty" title:@"Apps — completed empty list" note:nil]; }];
    [gallery add:^{ WQScanTask *t=[WQScanTask taskNamed:@"apps"]; [t setValue:nil forKey:@"result"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t finish:@{@"rows":@[],@"complete":@NO,@"note":@"App discovery failed or was cancelled. Pull to refresh to try again."} generation:g]; [gallery offer:@"apps-error" title:@"Apps — discovery error" note:@"Injected discovery failure; actual controller error presentation"]; }];
    [gallery add:^{ [gallery seedApps]; WQScanTask *task=[WQScanTask taskNamed:@"apps"]; [task setValue:@YES forKey:@"persistenceFailed"]; [NSNotificationCenter.defaultCenter postNotificationName:WQScanTaskChangedNotification object:task]; gallery.afterCapture=^{[task setValue:@NO forKey:@"persistenceFailed"]; [NSNotificationCenter.defaultCenter postNotificationName:WQScanTaskChangedNotification object:task];}; [gallery offer:@"scan-checkpoint-save-failure" title:@"Apps — checkpoint save warning" note:@"Injected persistence failure flag drives the real Keep charony open navigation prompt"]; }];
    [gallery add:^{ [gallery seedApps]; [gallery search:gallery.apps query:@""]; [gallery offer:@"apps-search-active" title:@"Apps — native Search active" note:nil]; }];
    [gallery add:^{ [gallery search:gallery.apps query:@"Notes"]; [gallery offer:@"apps-search-results" title:@"Apps — search matches" note:nil]; }];
    [gallery add:^{ [gallery search:gallery.apps query:@"no-matching-fixture"]; [gallery offer:@"apps-search-no-results" title:@"Apps — search without matches" note:nil]; }];
    [gallery add:^{ [gallery showTab:0]; gallery.apps.contextSearchController.searchBar.text=@""; [gallery.apps updateSearchResultsForSearchController:gallery.apps.contextSearchController]; [gallery seedApps]; [gallery offer:@"apps-search-dismissed" title:@"Apps — Search dismissed" note:@"Actual contextual controller must be restored and visible"]; }];
    [gallery add:^{ [gallery showTab:0]; gallery.apps.contextSearchController.searchBar.text=@""; [gallery.apps updateSearchResultsForSearchController:gallery.apps.contextSearchController]; [gallery seedApps]; [gallery.apps tableView:gallery.apps.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]; [gallery offer:@"app-clear-confirmation" title:@"Apps — permanent clearing confirmation" note:@"Actual confirmation; no operation is accepted for this frame"]; }];
    [gallery add:^{ [gallery dismiss]; CHArmOperation(); [gallery.apps clear:[[gallery.apps valueForKey:@"visibleApps"] firstObject]]; [gallery until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ [gallery offer:@"app-clear-progress" title:@"Apps — deletion in progress" note:@"Real deletion of disposable files, paused at a safe fixture boundary for capture"]; }]; }];
    [gallery add:^{ (void)wq_begin_mutation(gallery.apps); gallery.afterCapture=^{
        if (gallery.apps.presentedViewController || ![[gallery.apps valueForKey:@"busy"] boolValue]) {
            [gallery fail:@"The held mutation must stay busy until the conflict alert has fully dismissed"]; return;
        }
        CHReleaseOperation();
    }; [gallery offer:@"operation-in-progress" title:@"Concurrent operation refused" note:@"Actual cross-tab mutation reservation alert"]; }];
    [gallery add:^{ [gallery until:^BOOL{return [CHTop(gallery.window.rootViewController).title isEqualToString:@"Data cleared"];} attempts:150 then:^{ [gallery offer:@"app-clear-success" title:@"Apps — clear success" note:@"Actual disposable-file clear outcome; not protected-app validation"]; }]; }];
    [gallery add:^{ [gallery dismiss]; [gallery seedApps]; NSString *path=[[[gallery.apps valueForKey:@"visibleApps"] firstObject] valueForKey:@"container"]; [@{@"MCMMetadataIdentifier":@"com.example.changed"} writeToFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] atomically:YES]; [gallery.apps clear:[[gallery.apps valueForKey:@"visibleApps"] firstObject]]; [gallery until:^BOOL{return [CHTop(gallery.window.rootViewController).title isEqualToString:@"Clear incomplete"];} attempts:150 then:^{ [gallery offer:@"app-clear-failure" title:@"Apps — identity refusal" note:@"Real validator refuses changed fixture identity before deleting data"]; }]; }];
    [gallery add:^{
        [gallery seedApps]; CHArmOperation();
        [gallery.apps clear:[[gallery.apps valueForKey:@"visibleApps"] firstObject]];
        [gallery until:^BOOL { return atomic_load(&CHReached); } attempts:150 then:^{
            (void)wq_begin_mutation(gallery.apps);
            gallery.keepAlertAfterCapture = YES;
            gallery.afterCapture = ^{ CHReleaseOperation(); };
            [gallery offer:@"app-clear-deferred-blocker" title:@"Apps — alert covers a held clear" note:@"Real disposable clear; keep this actual conflict alert open while the worker finishes"];
        }];
    }];
    [gallery add:^{
        [gallery until:^BOOL { return ![[gallery.apps valueForKey:@"busy"] boolValue] &&
            [[gallery.apps valueForKey:@"pendingClearTitle"] isEqualToString:@"Data cleared"]; } attempts:150 then:^{
            [gallery offer:@"app-clear-result-deferred" title:@"Apps — completed result waits behind alert" note:@"Real worker has finished; its outcome must not replace the current modal. Dismiss after this frame"];
        }];
    }];
    [gallery add:^{
        [gallery until:^BOOL { return [CHTop(gallery.window.rootViewController).title isEqualToString:@"Data cleared"]; } attempts:150 then:^{
            [gallery offer:@"app-clear-deferred-success" title:@"Apps — deferred result delivered after dismissal" note:@"Actual disposable-file outcome appears automatically after the blocking modal closes"];
        }];
    }];
    [gallery add:^{ [gallery showTab:1]; [gallery publish:@"clean" rows:@[] note:nil]; [gallery offer:@"caches-initial" title:@"Caches — initial idle fixture" note:nil]; }];
    [gallery add:^{ WQScanTask *t=[WQScanTask taskNamed:@"clean"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t progress:@"Finding apps…" fraction:0.35 generation:g]; [gallery.caches setValue:@0.35 forKey:@"scanProgress"]; [gallery.caches.tableView reloadData]; [gallery offer:@"caches-loading" title:@"Caches — loading" note:@"Fixture-driven scan status"]; }];
    [gallery add:^{ [gallery seedCaches]; [gallery offer:@"caches-populated" title:@"Caches — populated, no selection" note:nil]; }];
    [gallery add:^{ [gallery captureAccessibleCacheRows:@"caches-accessibility-rows" title:@"Caches — enlarged rows, unselected"]; }];
    [gallery add:^{ for(NSUInteger i=0;i<2;i++) [gallery.caches tableView:gallery.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [gallery offer:@"caches-selected" title:@"Caches — manual multiple selection" note:nil]; }];
    [gallery add:^{ [gallery captureAccessibleCacheRows:@"caches-selected-accessibility-rows" title:@"Caches — enlarged rows, selected"]; }];
    [gallery add:^{ [gallery search:gallery.caches query:@""]; [gallery offer:@"caches-search-active" title:@"Caches — contextual Search active" note:nil]; }];
    [gallery add:^{ [gallery search:gallery.caches query:@"Maps"]; [gallery offer:@"caches-search-results" title:@"Caches — search matches" note:nil]; }];
    [gallery add:^{ [gallery search:gallery.caches query:@"no-matching-fixture"]; [gallery offer:@"caches-search-no-results" title:@"Caches — no search results" note:nil]; }];
    [gallery add:^{ [gallery showTab:1]; gallery.caches.contextSearchController.searchBar.text=@""; [gallery.caches updateSearchResultsForSearchController:gallery.caches.contextSearchController]; [gallery offer:@"caches-search-dismissed" title:@"Caches — Search dismissed" note:@"Original cache selection stays in the same restored controller"]; }];
    [gallery add:^{ [gallery showTab:1]; gallery.caches.contextSearchController.searchBar.text=@""; [gallery.caches updateSearchResultsForSearchController:gallery.caches.contextSearchController]; [gallery publish:@"clean" rows:@[] note:nil]; [gallery offer:@"caches-empty" title:@"Caches — completed empty list" note:nil]; }];
    [gallery add:^{ WQScanTask *task=[WQScanTask taskNamed:@"clean"]; NSUInteger g=[task beginFresh:YES cancel:^{}]; [task finish:@{@"rows":@[], @"complete":@NO, @"note":@"Scan incomplete: 1 container enumeration failed; limited rows are excluded; the remaining rows can still be cleaned. Pull to refresh to retry."} generation:g]; [gallery offer:@"caches-scan-error" title:@"Caches — incomplete scan" note:@"Injected failed enumeration uses the production error format; no real protected app was queried"]; }];
    [gallery add:^{ [gallery seedCaches]; gallery.cacheRows[0].limited=YES; gallery.cacheRows[0].cacheKnown=NO; [gallery.caches setValue:gallery.cacheRows forKey:@"items"]; [gallery.caches rebuildVisibleItems]; [gallery.caches.tableView reloadData]; [gallery.caches tableView:gallery.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]]; [gallery offer:@"cache-access-limited" title:@"Caches — limited-access refusal" note:@"Fixture limited flag drives the real refusal dialog"]; }];
    [gallery add:^{ [gallery dismiss]; [gallery seedCaches]; for(NSUInteger i=0;i<2;i++) [gallery.caches tableView:gallery.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [gallery.caches confirmClean]; [gallery offer:@"cache-clean-confirmation" title:@"Caches — one batch confirmation" note:nil]; }];
    [gallery add:^{ [gallery dismiss]; [gallery.caches cleanItems:[gallery.caches valueForKey:@"items"] generation:[[gallery.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]+1]; gallery.afterCapture=^{[gallery dismiss];}; [gallery offer:@"cache-selection-changed" title:@"Caches — stale confirmation refused" note:@"Actual generation mismatch; no mutation worker is started"]; }];
    [gallery add:^{ [gallery dismiss]; CHArmOperation(); NSArray *selected=[gallery.caches valueForKey:@"items"]; [gallery.caches cleanItems:selected generation:[[gallery.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [gallery until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ gallery.afterCapture=^{ CHReleaseOperation(); }; [gallery offer:@"cache-clean-progress" title:@"Caches — batch deletion in progress" note:@"Actual disposable-cache purge, held at a fixture boundary"]; }]; }];
    [gallery add:^{ [gallery until:^BOOL{return ![[gallery.caches valueForKey:@"cleaning"] boolValue] && [[gallery.caches valueForKey:@"result"] hasPrefix:@"Freed "];} attempts:150 then:^{ [gallery.caches.tableView reloadData]; [gallery offer:@"cache-clean-success" title:@"Caches — cleaning success" note:@"Actual disposable-file outcome; discovery rescans are fixture-driven"]; }]; }];
    [gallery add:^{ [gallery seedCaches]; CHArmOperation(); [gallery.caches cleanItems:gallery.cacheRows generation:[[gallery.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [gallery until:^BOOL{return atomic_load(&CHReached);} attempts:150 then:^{ [gallery.caches stopClean]; gallery.afterCapture=^{ CHReleaseOperation(); }; [gallery offer:@"cache-clean-stopping" title:@"Caches — Stop requested" note:@"Actual cooperative cancellation requested during disposable-file cleanup"]; }]; }];
    [gallery add:^{ [gallery until:^BOOL{return ![[gallery.caches valueForKey:@"cleaning"] boolValue] && [[gallery.caches valueForKey:@"result"] hasPrefix:@"Stopped."];} attempts:150 then:^{ if([[gallery.caches valueForKey:@"result"] containsString:@"access denied or data changed"]) { [gallery fail:@"User cancellation must not be reported as an access/data-change failure"]; return; } [gallery.caches.tableView reloadData]; [gallery offer:@"cache-clean-stopped" title:@"Caches — cleaning stopped" note:@"Actual cancellation outcome; partial removal is possible and there is no rollback"]; }]; }];
    [gallery add:^{ [gallery seedCaches]; WQCacheItem *item=gallery.cacheRows[0]; NSString *saved=[item.containerPath stringByAppendingString:@"-preserved"]; rename(item.containerPath.fileSystemRepresentation,saved.fileSystemRepresentation); [NSFileManager.defaultManager createDirectoryAtPath:item.containerPath withIntermediateDirectories:YES attributes:nil error:nil]; [gallery.caches cleanItems:gallery.cacheRows generation:[[gallery.caches valueForKey:@"scanGeneration"] unsignedIntegerValue]]; [gallery until:^BOOL{return ![[gallery.caches valueForKey:@"cleaning"] boolValue] && [[gallery.caches valueForKey:@"result"] hasPrefix:@"Clean cancelled:"];} attempts:150 then:^{ [gallery offer:@"cache-clean-failure" title:@"Caches — changed-container failure" note:@"Real whole-batch preflight refusal; preserved fixture data is not deleted"]; }]; }];
    [gallery add:^{ [gallery seedCaches]; NSString *root=[CHGalleryContainers stringByAppendingPathComponent:@"DisposableCrashReporter"]; [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]; [@"disposable" writeToFile:[root stringByAppendingPathComponent:@"fixture.ips"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; WQCacheFixtureCrashRoots=@[root]; WQCacheItem *reports=[WQCacheItem new]; reports.name=@"Crash Logs"; reports.crashLogs=YES; reports.targets=@[root]; reports.targetRecords=@[WQCacheTargetRecordForPath(root,nil)]; reports.cacheKnown=YES; reports.tempKnown=YES; reports.cacheBytes=4096; [gallery publish:@"clean" rows:[gallery.caches snapshotRows:@[gallery.cacheRows[0],reports] note:nil][@"rows"] note:nil]; for(NSUInteger i=0;i<2;i++) [gallery.caches tableView:gallery.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:1]]; [gallery offer:@"crash-reports-selected" title:@"Caches — app and crash reports selected" note:@"Crash Logs row uses an allowlisted disposable simulator directory"]; }];
    [gallery add:^{ [gallery.caches confirmClean]; gallery.afterCapture=^{[gallery dismiss];}; [gallery offer:@"crash-reports-confirmation" title:@"Caches — diagnostic-report confirmation" note:@"Actual mixed app/cache and Crash Logs warning; canceled after capture"]; }];
    [gallery add:^{ [gallery.caches tableView:gallery.caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]]; [gallery.caches confirmClean]; gallery.afterCapture=^{[gallery dismiss];}; [gallery offer:@"crash-reports-only-confirmation" title:@"Caches — crash reports only confirmation" note:@"Actual report-only permanent deletion warning; canceled after capture"]; }];
    [gallery add:^{ [gallery showTab:0]; [gallery seedApps]; WQScanTask *t=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[t beginFresh:YES cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.61 generation:g]; [gallery offer:@"scan-progress" title:@"Apps — scan progress" note:@"Fixture progress notifications"]; }];
    [gallery add:^{ [[WQScanTask taskNamed:@"apps"] pause]; [gallery offer:@"scan-paused" title:@"Apps — scan paused" note:@"Actual task pause state and Resume control"]; }];
    [gallery add:^{ WQScanTask *t=[WQScanTask taskNamed:@"apps"]; NSUInteger g=[t beginFresh:NO cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.62 generation:g]; [gallery offer:@"scan-resumed" title:@"Apps — scan resumed" note:@"Same task identity, fixture worker progress"]; }];
    [gallery add:^{ [gallery showTab:1]; [gallery seedCaches]; WQScanTask *t=[WQScanTask taskNamed:@"clean"]; [t beginFresh:YES cancel:^{}]; [t pause]; [gallery offer:@"cache-scan-paused" title:@"Caches — scan paused" note:nil]; }];
    [gallery add:^{ WQScanTask *t=[WQScanTask taskNamed:@"clean"]; NSUInteger g=[t beginFresh:NO cancel:^{}]; [t progress:@"Measuring apps…" fraction:0.62 generation:g]; [gallery.caches setValue:@0.62 forKey:@"scanProgress"]; [gallery.caches.tableView reloadData]; [gallery offer:@"cache-scan-resumed" title:@"Caches — scan resumed" note:nil]; }];
    [gallery add:^{ [gallery showTab:0]; [gallery publish:@"apps" rows:@[] note:@"An App Group is required. Re-sign charony with a tool that preserves its App Group entitlement."]; [gallery offer:@"app-group-missing" title:@"Apps — missing App Group" note:@"Fixture result uses the actual application error wording"]; }];
    [gallery add:^{ atomic_store(&gAccessRecoveryNeeded,YES); wq_offer_access_recovery(gallery.apps); gallery.keepAlertAfterCapture=YES; [gallery offer:@"access-cache-recovery" title:@"Conditional Reset Access Cache" note:@"Injected recoverable-cache flag; actual recovery interface"]; }];
    [gallery add:^{ [gallery advanceAction:1]; [gallery until:^BOOL{return [CHTop(gallery.window.rootViewController).title isEqualToString:@"Recovery incomplete"];} attempts:150 then:^{ [gallery offer:@"access-cache-reset-failure" title:@"Access Cache — recovery failure" note:@"Actual reset cannot obtain an App Group in the unsigned fixture environment"]; }]; }];
    [gallery add:^{ atomic_store(&gAccessRecoveryNeeded,NO); [gallery dismiss]; [gallery seedApps]; dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ (void)CHConfirmFullScan(@"the app folders",1200000,90); }); [gallery until:^BOOL{return [CHTop(gallery.window.rootViewController) isKindOfClass:UIAlertController.class];} attempts:150 then:^{ gallery.keepAlertAfterCapture=YES; gallery.afterCapture=^{ [gallery advanceAction:0]; }; [gallery offer:@"full-scan-consent" title:@"Full inode scan consent" note:@"Real consent dialog with fixture estimate; canceled without scanning protected paths"]; }]; }];
    [gallery add:^{ [gallery dismiss]; [gallery seedApps]; NSString *failure=wq_access_capability_failure(); if(!failure){ [gallery.missing addObject:@{@"state":@"unsupported-build-startup",@"reason":@"This simulator host did not trigger the production capability failure"}]; [gallery next]; return; } UIWindow *original=gallery.window; CHSceneDelegate *blocked=[CHSceneDelegate new]; [blocked scene:original.windowScene willConnectToSession:original.windowScene.session options:gallery.connectionOptions]; gallery.window=blocked.window; gallery.afterCapture=^{ blocked.window.hidden=YES; gallery.window=original; [original makeKeyAndVisible]; }; [gallery offer:@"unsupported-build-startup" title:@"Production startup capability failure" note:@"Actual production startup view checks the simulator host kernel; this is not the target iPhone build"]; }];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session;
    self.connectionOptions=options;
    self.missing=[NSMutableArray new]; self.steps=[NSMutableArray new];
    [self.missing addObjectsFromArray:@[
        @{@"state":@"app-details",@"reason":@"No separate app-details screen exists; storage appears in Apps rows"},
        @{@"state":@"successful-real-App-Group-reset",@"reason":@"Simulator fixtures have no authorized protected App Group; actual device access is unverified"},
        @{@"state":@"real-protected-app-discovery",@"reason":@"Discovery and identities are disposable fixtures; no real user data or sandbox tokens"}]];
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
