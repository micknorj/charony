// Real UIKit and mutation engines; only disposable, owned fixture containers.
#import <UIKit/UIKit.h>
#import "../WQScanTask.h"
#import "../WQApps.h"
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#define WQ_CACHE_TESTING 1
#import "../WQCache.m"
#import "../WQUI.h"
static NSString *CHFixtureContainers;
static BOOL CHFixtureGrant(NSString *path)
{
    return CHFixtureContainers.length && [path hasPrefix:[CHFixtureContainers stringByAppendingString:@"/"]];
}
#define wq_grant CHFixtureGrant
#import "../CHAppData.m"
#undef wq_grant
#define main CHProductionMain
#import "../main.m"
#undef main
static void marker(NSString *name)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    [@"ok" writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void phase(NSString *name)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    [name writeToFile:[documents stringByAppendingPathComponent:@"ui-phase.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void fixtureException(NSException *exception)
{
    marker(@"FAIL-unhandled-exception");
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ui-exception.log"];
    [[NSString stringWithFormat:@"%@: %@\n%@", exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void check(BOOL condition, NSString *name)
{
    if (!condition) { marker([@"FAIL-" stringByAppendingString:name]); abort(); }
}
static NSString *visibleLabelText(UIView *view)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)
        [parts addObject:((UILabel *)view).text];
    for (UIView *child in view.subviews) [parts addObject:visibleLabelText(child)];
    return [parts componentsJoinedByString:@" "];
}
static UIProgressView *findProgress(UIView *view)
{
    if ([view isKindOfClass:UIProgressView.class]) return (UIProgressView *)view;
    for (UIView *child in view.subviews) { UIProgressView *progress = findProgress(child); if (progress) return progress; }
    return nil;
}
static void checkRowLayout(UITableView *table, NSIndexPath *index)
{
    [table scrollToRowAtIndexPath:index atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    [table layoutIfNeeded];
    UITableViewCell *cell = [table cellForRowAtIndexPath:index];
    check(cell.window != nil && CGRectGetHeight(cell.bounds) >= 70, @"comfortable-row-is-rendered-in-the-actual-window");
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    check(content.textProperties.font.pointSize <= 17.01 && content.secondaryTextProperties.font.pointSize <= 13.01,
          @"app-controlled-row-fonts-are-capped-at-normal-size");
    check(content.textProperties.numberOfLines == 0 && content.secondaryTextProperties.numberOfLines == 0,
          @"name-identifier-and-size-can-wrap");
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell.contentView];
    NSUInteger labels = 0;
    while (pending.count) {
        UIView *view = pending.lastObject; [pending removeLastObject];
        [pending addObjectsFromArray:view.subviews];
        if (![view isKindOfClass:UILabel.class] || view.hidden) continue;
        UILabel *label = (UILabel *)view;
        if (!label.text.length) continue;
        labels++;
        check(label.font.pointSize <= 17.01, @"rendered-row-label-never-exceeds-normal-system-size");
        CGSize needed = [label sizeThatFits:CGSizeMake(label.bounds.size.width, CGFLOAT_MAX)];
        CGRect rect = [label convertRect:label.bounds toView:cell.contentView];
        check(needed.height <= label.bounds.size.height + 1 && CGRectGetMinX(rect) >= -1 &&
              CGRectGetMaxX(rect) <= cell.contentView.bounds.size.width + 1 &&
              CGRectGetMaxY(rect) <= cell.contentView.bounds.size.height + 1,
              @"rendered-row-text-fits-without-clipping");
    }
    check(labels >= 2, @"actual-name-identifier-and-size-labels-are-present");
}
static void runTypographyFixtures(UIWindow *window, UITableViewController *controller)
{
    phase(@"runTypographyFixtures");
    // Emulate both system extremes. The workflow also sets the real simulator
    // preference before launch. These are assertions, not image captures.
    [NSNotificationCenter.defaultCenter postNotificationName:UIContentSizeCategoryDidChangeNotification object:nil userInfo:
        @{UIContentSizeCategoryNewValueKey:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge}];
    [window layoutIfNeeded];
    check(UIContentSizeCategoryCompareToCategory(window.traitCollection.preferredContentSizeCategory, UIContentSizeCategoryLarge) != NSOrderedDescending,
          @"system-accessibility-category-is-capped-through-the-real-window-policy");
    [controller.tableView reloadData];
    checkRowLayout(controller.tableView, [NSIndexPath indexPathForRow:0 inSection:0]);
    UILabel *title = (UILabel *)controller.navigationItem.leftBarButtonItem.customView;
    NSDictionary *layout = @{@"titleFont":@(title.font.pointSize), @"title":controller.navigationItem.title ?: @"nil",
        @"leadingTitle":title.text ?: @"nil", @"category":title.traitCollection.preferredContentSizeCategory,
        @"windowCategory":window.traitCollection.preferredContentSizeCategory};
    NSString *log = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ui-layout.log"];
    [[NSJSONSerialization dataWithJSONObject:layout options:NSJSONWritingPrettyPrinted error:nil] writeToFile:log atomically:YES];
    check(title.font.pointSize <= 17.01, @"leading-title-never-exceeds-normal-size");
    check([controller.navigationItem.title isEqualToString:@""], @"leading-title-replaces-centered-title");
    UIFont *large = wq_font(UIFontTextStyleBody, [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge]);
    UIFont *small = wq_font(UIFontTextStyleBody, [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryExtraSmall]);
    check(large.pointSize == 17 && small.pointSize < large.pointSize, @"font-limit-allows-smaller-system-sizes");
    [NSNotificationCenter.defaultCenter postNotificationName:UIContentSizeCategoryDidChangeNotification object:nil userInfo:
        @{UIContentSizeCategoryNewValueKey:UIContentSizeCategoryExtraSmall}];
    [window layoutIfNeeded];
    [controller.tableView reloadData];
    UITableViewCell *cell = [controller tableView:controller.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    check(content.textProperties.font.pointSize < 17, @"actual-list-respects-smaller-user-text-size");
    [NSNotificationCenter.defaultCenter postNotificationName:UIContentSizeCategoryDidChangeNotification object:nil userInfo:
        @{UIContentSizeCategoryNewValueKey:window.windowScene.traitCollection.preferredContentSizeCategory}];
    [window layoutIfNeeded];
    [controller.tableView reloadData];
}

// Rescanning is supplied by fixtures. The real batch mutation implementation runs.
@interface CHFixtureCaches : WQCacheCleanerViewController
@property (nonatomic) NSUInteger scanRequests;
@property (nonatomic) BOOL fixtureAppeared;
@end
@implementation CHFixtureCaches
- (void)scan { self.scanRequests++; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.fixtureAppeared = YES; }
@end
@interface CHFixtureApps : WQAppsViewController
@property (nonatomic) NSUInteger scanRequests;
@property (nonatomic) BOOL fixtureAppeared;
@end
@implementation CHFixtureApps
- (void)scan { self.scanRequests++; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.fixtureAppeared = YES; }
@end
@interface WQAppsViewController (CHPresentationFixtures)
- (void)presentPendingClearResult;
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
static void awaitUIKitState(BOOL (^ready)(void), NSUInteger remaining, NSString *assertion,
                            NSDictionary *(^diagnostics)(void), dispatch_block_t next)
{
    if (ready()) { next(); return; }
    if (!remaining) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:diagnostics() options:NSJSONWritingPrettyPrinted error:nil];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [data writeToFile:[documents stringByAppendingPathComponent:@"search-navigation.log"] atomically:YES];
        check(NO, assertion);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        awaitUIKitState(ready, remaining - 1, assertion, diagnostics, next);
    });
}
static void runDeferredClearResultFixture(UIWindow *window, dispatch_block_t next)
{
    phase(@"runDeferredClearResultFixture");
    CHFixtureApps *controller = [CHFixtureApps new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [window layoutIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = controller.navigationController;
        wq_alert(presenter, @"Fixture blocking alert", @"Disposable presentation fixture; no app data is cleared.");
        NSDictionary *(^diagnostics)(void) = ^NSDictionary *{
            return @{@"alert":presenter.presentedViewController.title ?: @"nil",
                @"pending":[controller valueForKey:@"pendingClearTitle"] ?: @"nil",
                @"attached":@(controller.view.window != nil)};
        };
        awaitUIKitState(^BOOL { return [presenter.presentedViewController.title isEqualToString:@"Fixture blocking alert"] &&
                                      !presenter.presentedViewController.isBeingPresented; },
            150, @"blocking-alert-is-actually-presented", diagnostics, ^{
            [controller setValue:@"Clear incomplete" forKey:@"pendingClearTitle"];
            [controller setValue:@"Disposable result-presentation fixture." forKey:@"pendingClearMessage"];
            [controller presentPendingClearResult];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                check([presenter.presentedViewController.title isEqualToString:@"Fixture blocking alert"] &&
                      [[controller valueForKey:@"pendingClearTitle"] isEqualToString:@"Clear incomplete"],
                      @"clear-outcome-waits-without-replacing-the-current-alert");
                [presenter dismissViewControllerAnimated:NO completion:^{
                    awaitUIKitState(^BOOL { return [controller.presentedViewController.title isEqualToString:@"Clear incomplete"] &&
                                                  !controller.presentedViewController.isBeingPresented; },
                        150, @"deferred-clear-result-appears-after-modal-dismissal", diagnostics, ^{
                        check([controller valueForKey:@"pendingClearTitle"] == nil, @"delivered-clear-result-is-consumed-once");
                        [controller dismissViewControllerAnimated:NO completion:next];
                    });
                }];
            });
        });
    });
}
static void runActiveSearchNavigationFixtures(UITabBarController *tabs, WQAppsViewController *apps,
                                               UINavigationController *appsNav, dispatch_block_t next)
{
    phase(@"runActiveSearchNavigationFixtures");
    UITab *search = tabs.tabs[2], *appsTab = tabs.tabs[0], *cachesTab = tabs.tabs[1];
    UISearchController *controller = apps.contextSearchController;
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{
        id pending = [tabs respondsToSelector:NSSelectorFromString(@"pendingTab")] ? [tabs valueForKey:@"pendingTab"] : nil;
        return @{@"selectedTab":tabs.selectedTab.identifier ?: @"nil", @"pendingTab":[pending valueForKey:@"identifier"] ?: @"nil",
            @"appsTop":NSStringFromClass(appsNav.topViewController.class) ?: @"nil",
            @"appsIsTop":@(appsNav.topViewController == apps), @"appsVisible":@(apps.view.window != nil),
            @"searchActive":@(controller.active), @"searchPresenting":@(controller.isBeingPresented),
            @"searchDismissing":@(controller.isBeingDismissed), @"searchDelegate":NSStringFromClass([(id)controller.delegate class]) ?: @"nil"};
    };
    BOOL (^searchReady)(void) = ^BOOL { return controller.active && apps.view.window && !controller.isBeingPresented; };
    check([tabs.delegate tabBarController:tabs shouldSelectTab:search], @"search-selection-allowed");
    UITab *previous = tabs.selectedTab;
    tabs.selectedTab = search;
    [tabs.delegate tabBarController:tabs didSelectTab:search previousTab:previous];
    awaitUIKitState(searchReady, 150, @"search-is-actually-presented", diagnostics, ^{
        check(searchReady(), @"search-is-actually-presented");
        check(controller.searchBar.searchTextField.font.pointSize <= 17.01, @"native-search-field-text-is-capped-at-normal-size");
        controller.searchBar.text = @"no-match";
        [apps updateSearchResultsForSearchController:controller];
        check([apps.tableView numberOfRowsInSection:0] == 0, @"apps-search-filters-current-context");
        controller.searchBar.text = @"fixture";
        [apps updateSearchResultsForSearchController:controller];
        check([apps.tableView numberOfRowsInSection:0] == 1, @"bundle-and-name-search");
        selectFixtureTab(tabs, appsTab);
        awaitUIKitState(^BOOL {return tabs.selectedTab == appsTab && appsNav.topViewController == apps &&
                                  apps.view.window && [apps.view isDescendantOfView:appsNav.view];},
                         150, @"same-search-context-restored", diagnostics, ^{
            check(tabs.selectedTab == appsTab && appsNav.topViewController == apps, @"same-search-context-restored");
            check(apps.view.window != nil && [apps.view isDescendantOfView:appsNav.view], @"apps-content-remains-visible-after-active-search");
            selectFixtureTab(tabs, search);
            awaitUIKitState(searchReady, 150, @"search-reopens-after-restoration", diagnostics, ^{
                check(searchReady(), @"search-reopens-after-restoration");
                [apps tableView:apps.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
                awaitUIKitState(^BOOL { return [apps.presentedViewController isKindOfClass:UIAlertController.class] && !apps.presentedViewController.isBeingPresented; },
                    150, @"clear-confirmation-is-reachable-from-active-search", diagnostics, ^{
                [apps dismissViewControllerAnimated:NO completion:^{
                selectFixtureTab(tabs, cachesTab);
                awaitUIKitState(^BOOL {return tabs.selectedTab == cachesTab && appsNav.topViewController == apps &&
                    ((UINavigationController *)tabs.selectedViewController).topViewController.view.window != nil;},
                    150, @"original-context-restored", diagnostics, ^{
                    check(tabs.selectedTab == cachesTab && appsNav.topViewController == apps, @"original-context-restored");
                    check(tabs.selectedViewController.view.window != nil, @"cache-content-visible-after-active-search");
                    next();
                });
                }];
                });
            });
        });
    });
}
static void runCacheSearchConfirmationFixture(UITabBarController *tabs, WQCacheCleanerViewController *caches, dispatch_block_t next)
{
    phase(@"runCacheSearchConfirmationFixture");
    NSArray *items = [caches valueForKey:@"items"];
    id item = items.firstObject;
    [item setValue:@NO forKey:@"limited"];
    [caches tableView:caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    selectFixtureTab(tabs, tabs.tabs[2]);
    UISearchController *search = caches.contextSearchController;
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{ return @{@"selected":tabs.selectedTab.identifier ?: @"nil", @"active":@(search.active), @"alert":caches.presentedViewController.title ?: @"nil"}; };
    awaitUIKitState(^BOOL { return search.active && !search.isBeingPresented && caches.view.window; },
        150, @"cache-search-is-actually-active", diagnostics, ^{
        search.searchBar.text = @"no-matching-fixture";
        [caches updateSearchResultsForSearchController:search];
        check([caches.tableView numberOfRowsInSection:0] == 0 && [visibleLabelText(caches.tableView.backgroundView) containsString:@"No results"], @"cache-search-no-results-is-distinct");
        search.searchBar.text = @"fixture";
        [caches updateSearchResultsForSearchController:search];
        check([caches.tableView numberOfRowsInSection:0] == 1, @"cache-context-search-finds-fixture");
        [caches confirmClean];
        awaitUIKitState(^BOOL { return [caches.presentedViewController.title isEqualToString:@"Clean caches?"] && !caches.presentedViewController.isBeingPresented; },
            150, @"cache-confirmation-is-reachable-from-active-search", diagnostics, ^{
            NSDictionary *context = @{@"selectedTab":tabs.selectedTab.identifier ?: @"nil", @"expectedTab":tabs.tabs[1].identifier,
                @"selected":[item valueForKey:@"selected"], @"query":search.searchBar.text ?: @"nil",
                @"modelQuery":[caches valueForKey:@"query"] ?: @"nil", @"searchActive":@(search.active),
                @"tabController":NSStringFromClass(caches.tabBarController.class) ?: @"nil",
                @"windowRoot":NSStringFromClass(caches.view.window.rootViewController.class) ?: @"nil",
                @"sameItem":@([[caches valueForKey:@"items"] firstObject] == item),
                @"contextRootStillAttached":@(((CHTabs *)tabs).searchRoot == caches)};
            NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ui-search-context.log"];
            [[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
            check(tabs.selectedTab == tabs.tabs[1], @"cache-confirmation-restores-the-original-tab");
            check([[item valueForKey:@"selected"] boolValue], @"cache-confirmation-retains-manual-selection");
            check([search.searchBar.text isEqualToString:@"fixture"], @"cache-confirmation-retains-the-query");
            [caches dismissViewControllerAnimated:NO completion:^{
                [caches tableView:caches.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
                search.searchBar.text = @"";
                [caches updateSearchResultsForSearchController:search];
                next();
            }];
        });
    });
}

// Drive real scan notifications without container access. The original
// harness seeded a completed result before showing Apps, missing first scans.
static void checkRefreshControls(UITableViewController *controller)
{
    UIBarButtonItem *refresh = nil, *filters = nil;
    for (UIBarButtonItem *button in controller.navigationItem.rightBarButtonItems) {
        if ([button.accessibilityIdentifier isEqualToString:@"refresh"]) refresh = button;
        if ([button.accessibilityIdentifier isEqualToString:@"filters"]) filters = button;
    }
    check(refresh && filters && refresh != filters && filters.menu != nil, @"refresh-and-ellipsis-menu-are-separate-native-controls");
    check([[controller valueForKey:@"scanRequests"] unsignedIntegerValue] == 0, @"opening-a-tab-does-not-request-scanning");
    check([UIApplication.sharedApplication sendAction:refresh.action to:refresh.target from:refresh forEvent:nil], @"native-refresh-control-invokes-its-real-action");
    check([[controller valueForKey:@"scanRequests"] unsignedIntegerValue] == 1, @"refresh-action-reaches-the-scan-entry-point");
}
static void runAppListStateFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runAppListStateFixtures");
    CHFixtureApps *controller = [CHFixtureApps new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [window makeKeyAndVisible];
    [controller loadViewIfNeeded];
    awaitUIKitState(^BOOL { return controller.fixtureAppeared; }, 150, @"list-fixture-has-completed-native-appearance", ^NSDictionary *{ return @{@"controller":NSStringFromClass(controller.class)}; }, ^{
    check([[visibleLabelText(controller.tableView.backgroundView) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"Refresh to update"], @"initial-apps-explicit-refresh-message");
    check(![WQScanTask taskNamed:@"apps"].running, @"opening-apps-does-not-start-a-scan");
    checkRefreshControls(controller);
    WQScanTask *task = [WQScanTask taskNamed:@"apps"];
    NSUInteger generation = [task beginFresh:YES cancel:^{}];
    [task progress:@"Finding apps…" fraction:0.25 generation:generation];
    check([controller.tableView numberOfRowsInSection:0] == 0, @"first-app-scan-has-no-phantom-row");
    check([visibleLabelText(controller.tableView.backgroundView) containsString:@"Finding apps"], @"initial-loading-is-distinct-from-empty");
    UIProgressView *progress = findProgress(controller.tableView.backgroundView);
    check(progress && fabs(progress.progress - 0.25) < 0.001, @"first-app-scan-renders-real-progress-without-phantom-rows");
    [task finish:@{@"rows":@[], @"complete":@YES} generation:generation];
    check([controller.tableView numberOfRowsInSection:0] == 0 && [visibleLabelText(controller.tableView.backgroundView) containsString:@"No accessible apps"], @"genuine-empty-app-list-is-distinct");
    generation = [task beginFresh:YES cancel:^{}];
    check([controller.tableView numberOfRowsInSection:0] == 0, @"empty-app-refresh-has-no-phantom-row");
    NSDictionary *row = @{@"name":@"Read-only Fixture", @"bundleID":@"com.example.fixture.with.a.long.identifier", @"bytes":@123,
        @"hasAccess":@YES, @"hasIdentity":@YES, @"sizeKnown":@YES};
    [task finish:@{@"rows":@[row], @"note":@"", @"complete":@YES} generation:generation];
    check([controller.tableView numberOfRowsInSection:0] == 1 && !controller.tableView.backgroundView, @"completed-app-model-is-visible-without-empty-banner");
    generation = [task beginFresh:YES cancel:^{}];
    NSMutableDictionary *partial = [row mutableCopy]; partial[@"sizeKnown"] = @NO;
    [task finish:@{@"rows":@[partial], @"note":@"", @"complete":@YES} generation:generation];
    UITableViewCell *cell = [controller tableView:controller.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    check([content.secondaryText containsString:@"size incomplete"] && [content.secondaryText containsString:row[@"bundleID"]], @"partial-storage-is-labelled-on-the-row");
    runTypographyFixtures(window, controller);
    generation = [task beginFresh:YES cancel:^{}];
    check([controller.tableView numberOfRowsInSection:0] == 1, @"refresh-keeps-real-app-row");
    [task finish:@{@"rows":@[], @"complete":@YES} generation:generation];
    generation = [task beginFresh:YES cancel:^{}];
    NSString *error = @"App discovery failed. Refresh to retry.";
    [task finish:@{@"rows":@[], @"complete":@NO, @"note":error} generation:generation];
    check([visibleLabelText(controller.tableView.backgroundView) containsString:error], @"discovery-failure-is-visible-and-distinct-from-empty");
    [task setValue:@YES forKey:@"persistenceFailed"];
    [NSNotificationCenter.defaultCenter postNotificationName:WQScanTaskChangedNotification object:task];
    check([visibleLabelText(controller.tableView.backgroundView) containsString:@"Could not save"], @"checkpoint-failure-remains-visible-without-a-scan-date-banner");
    [task setValue:@NO forKey:@"persistenceFailed"];
    next();
    });
}

static void runCacheListStateFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runCacheListStateFixtures");
    CHFixtureCaches *controller = [CHFixtureCaches new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [window layoutIfNeeded];
    [controller loadViewIfNeeded];
    awaitUIKitState(^BOOL { return controller.fixtureAppeared; }, 150, @"list-fixture-has-completed-native-appearance", ^NSDictionary *{ return @{@"controller":NSStringFromClass(controller.class)}; }, ^{
    check([visibleLabelText(controller.tableView.backgroundView) containsString:@"Refresh to update"] && ![WQScanTask taskNamed:@"clean"].running, @"initial-caches-waits-for-explicit-refresh");
    checkRefreshControls(controller);
    WQScanTask *task = [WQScanTask taskNamed:@"clean"];
    NSUInteger generation = [task beginFresh:YES cancel:^{}];
    [controller setStatus:@"Finding apps…" progress:0.3];
    check([controller.tableView numberOfRowsInSection:0] == 0 && [visibleLabelText(controller.tableView.backgroundView) containsString:@"Finding apps"], @"cache-loading-is-distinct-from-empty");
    UIProgressView *progress = findProgress(controller.tableView.backgroundView);
    check(progress && fabs(progress.progress - 0.3) < 0.001, @"first-cache-scan-renders-real-progress");
    [task finish:@{@"rows":@[], @"complete":@YES} generation:generation];
    check([visibleLabelText(controller.tableView.backgroundView) containsString:@"No caches found"], @"completed-empty-caches-is-distinct");
    generation = [task beginFresh:YES cancel:^{}];
    [task finish:@{@"rows":@[], @"complete":@NO, @"note":@"Discovery incomplete. Refresh to retry."} generation:generation];
    check([visibleLabelText(controller.tableView.backgroundView) containsString:@"Discovery incomplete"], @"cache-discovery-error-remains-visible");
    next();
    });
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
static void invokeAlertAction(UIAlertController *alert, UIAlertActionStyle style);
static void runCacheBatchFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runCacheBatchFixtures");
    NSString *root = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    WQCacheFixtureRoot = root;
    WQCacheItem *first = cacheFixture(root), *second = cacheFixture(root), *unselected = cacheFixture(root);
    unselected.selected = NO;
    CHFixtureCaches *controller = [CHFixtureCaches new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [controller loadViewIfNeeded];
    [controller setValue:@[first, second, unselected] forKey:@"items"];
    check(WQCacheValidateItem(first, NULL), @"cache-fixture-validation");
    dispatch_block_t verifyBatch = ^{
        waitForBatch(controller, 200, ^{
            check(![[controller valueForKey:@"cleaning"] boolValue], @"batch-finished");
            for (UIBarButtonItem *button in controller.navigationItem.rightBarButtonItems)
                check(![button.title isEqualToString:@"Stop"], @"completed-batch-removes-stop-before-rescan");
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
    };
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{ return @{@"alert":controller.presentedViewController.title ?: @"nil"}; };
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller confirmClean];
        awaitUIKitState(^BOOL { return [controller.presentedViewController isKindOfClass:UIAlertController.class] && !controller.presentedViewController.isBeingPresented; },
            150, @"batch-cancel-confirmation-presented", diagnostics, ^{
            UIAlertController *confirmation = (UIAlertController *)controller.presentedViewController;
            NSUInteger destructive = 0, cancel = 0;
            for (UIAlertAction *action in confirmation.actions) {
                if (action.style == UIAlertActionStyleDestructive) destructive++;
                if (action.style == UIAlertActionStyleCancel) cancel++;
            }
            check(destructive == 1 && cancel == 1, @"one-batch-confirmation-and-cancel");
            check([confirmation.message containsString:@"Library/Caches and tmp"] && [confirmation.message containsString:@"cannot be undone"] &&
                  [confirmation.message containsString:@"No backup"] && [confirmation.message containsString:@"Offline downloads"], @"batch-warning-retains-exact-permanent-scope-and-offline-loss");
            invokeAlertAction(confirmation, UIAlertActionStyleCancel);
            awaitUIKitState(^BOOL { return controller.presentedViewController == nil; }, 150, @"batch-cancel-dismissed", diagnostics, ^{
                check([NSFileManager.defaultManager fileExistsAtPath:[first.targets[0] stringByAppendingPathComponent:@"sentinel"]] && ![[controller valueForKey:@"cleaning"] boolValue], @"actual-cache-cancel-preserves-data-without-worker");
                [controller confirmClean];
                awaitUIKitState(^BOOL { return [controller.presentedViewController isKindOfClass:UIAlertController.class] && !controller.presentedViewController.isBeingPresented; },
                    150, @"batch-accept-confirmation-presented", diagnostics, ^{
                    unselected.selected = YES; // Changes after the actual confirmation captured its batch.
                    invokeAlertAction((UIAlertController *)controller.presentedViewController, UIAlertActionStyleDestructive);
                    awaitUIKitState(^BOOL { return [[controller valueForKey:@"cleaning"] boolValue] || [[controller valueForKey:@"result"] hasPrefix:@"Freed "]; },
                        150, @"actual-cache-confirm-action-starts-worker", diagnostics, verifyBatch);
                });
            });
        });
    });
}

static void invokeAlertAction(UIAlertController *alert, UIAlertActionStyle style)
{
    check([alert isKindOfClass:UIAlertController.class], @"real-confirmation-is-visible");
    for (UIAlertAction *action in alert.actions) if (action.style == style) {
        // UIKit exposes no public API to send a tap to an UIAlertAction.
        // Invoke its actual registered handler; never substitute the worker.
        void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
        if (handler) handler(action);
        else [alert.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    check(NO, @"required-confirmation-action-exists");
}
static _Atomic BOOL CHOperationReached, CHHoldOperation;
static dispatch_semaphore_t CHOperationRelease;
static void holdFixturePurge(void)
{
    CHOperationRelease = dispatch_semaphore_create(0);
    atomic_store(&CHOperationReached, NO);
    atomic_store(&CHHoldOperation, YES);
    wq_test_tree_hook = ^(NSString *stage, NSString *__unused path) {
        if ([stage isEqualToString:@"purgeBeforeUnlink"] && atomic_exchange(&CHHoldOperation, NO)) {
            atomic_store(&CHOperationReached, YES);
            dispatch_semaphore_wait(CHOperationRelease, DISPATCH_TIME_FOREVER);
        }
    };
}
static void releaseFixturePurge(void)
{
    dispatch_semaphore_signal(CHOperationRelease);
}
static void runCrashConfirmationFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runCrashConfirmationFixtures");
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    WQCacheFixtureRoot = root;
    WQCacheItem *app = cacheFixture(root);
    NSString *reportRoot = [root stringByAppendingPathComponent:@"CrashReporter"];
    [files createDirectoryAtPath:reportRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *sentinel = [reportRoot stringByAppendingPathComponent:@"disposable.ips"];
    [@"keep" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil];
    WQCacheFixtureCrashRoots = @[reportRoot];
    WQCacheItem *reports = crashFixture(reportRoot); reports.selected = YES;
    CHFixtureCaches *controller = [CHFixtureCaches new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [controller loadViewIfNeeded];
    [controller setValue:@[app, reports] forKey:@"items"];
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{ return @{@"alert":controller.presentedViewController.title ?: @"nil"}; };
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller confirmClean];
        awaitUIKitState(^BOOL { return [controller.presentedViewController isKindOfClass:UIAlertController.class] && !controller.presentedViewController.isBeingPresented; },
            150, @"mixed-crash-confirmation-is-presented", diagnostics, ^{
            UIAlertController *alert = (UIAlertController *)controller.presentedViewController;
            check([alert.message containsString:@"Library/Caches and tmp"] && [alert.message containsString:@"plus Crash Logs"] &&
                  [alert.message containsString:@"Offline downloads"] && [alert.message containsString:@"No backup"], @"mixed-confirmation-keeps-both-scopes-and-content-loss-warning");
            invokeAlertAction(alert, UIAlertActionStyleCancel);
            awaitUIKitState(^BOOL { return !controller.presentedViewController; }, 150, @"mixed-crash-cancel-is-dismissed", diagnostics, ^{
                app.selected = NO;
                [controller confirmClean];
                awaitUIKitState(^BOOL { return [controller.presentedViewController isKindOfClass:UIAlertController.class] && !controller.presentedViewController.isBeingPresented; },
                    150, @"crash-only-confirmation-is-presented", diagnostics, ^{
                    UIAlertController *only = (UIAlertController *)controller.presentedViewController;
                    check([only.message containsString:@"Delete Crash Logs"] && [only.message containsString:@"cannot be undone"] && [only.message containsString:@"No backup"] &&
                          ![only.message containsString:@"Library/Caches"] && ![only.message containsString:@"Offline downloads"], @"crash-only-warning-does-not-claim-app-data-deletion");
                    invokeAlertAction(only, UIAlertActionStyleCancel);
                    awaitUIKitState(^BOOL { return !controller.presentedViewController; }, 150, @"crash-only-cancel-is-dismissed", diagnostics, ^{
                        check([files fileExistsAtPath:sentinel] && [files fileExistsAtPath:[app.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"crash-confirmation-cancellation-preserves-all-fixture-data");
                        [files removeItemAtPath:root error:nil];
                        WQCacheFixtureRoot = nil; WQCacheFixtureCrashRoots = nil;
                        next();
                    });
                });
            });
        });
    });
}

static void runRealAppClearFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runRealAppClearFixtures");
    NSFileManager *files = NSFileManager.defaultManager;
    CHFixtureContainers = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHTestApplicationRoot = CHFixtureContainers;
    WQCacheFixtureRoot = CHFixtureContainers;
    WQCacheItem *owned = cacheFixture(CHFixtureContainers), *unrelated = cacheFixture(CHFixtureContainers);
    NSString *documents = [owned.containerPath stringByAppendingPathComponent:@"Documents"];
    [files createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    [@"disposable" writeToFile:[documents stringByAppendingPathComponent:@"sentinel"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    struct stat st = {0};
    check(lstat(owned.containerPath.fileSystemRepresentation, &st) == 0, @"capture-owned-app-identity");
    NSDictionary *row = @{@"name":@"Disposable Fixture", @"bundleID":owned.bundleID, @"container":owned.containerPath,
        @"bytes":@30, @"sizeKnown":@YES, @"hasAccess":@YES, @"hasIdentity":@YES,
        @"containerDevice":@(st.st_dev), @"containerInode":@(st.st_ino)};
    WQScanTask *task = [WQScanTask taskNamed:@"apps"];
    NSUInteger generation = [task beginFresh:YES cancel:^{}];
    [task finish:@{@"rows":@[row], @"complete":@YES} generation:generation];
    CHFixtureApps *apps = [CHFixtureApps new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:apps];
    [window layoutIfNeeded];
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{
        return @{@"alert":apps.presentedViewController.title ?: @"nil", @"busy":[apps valueForKey:@"busy"],
            @"pending":[apps valueForKey:@"pendingClearTitle"] ?: @"nil", @"reached":@(atomic_load(&CHOperationReached))};
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        NSIndexPath *index = [NSIndexPath indexPathForRow:0 inSection:0];
        [apps tableView:apps.tableView didSelectRowAtIndexPath:index];
        awaitUIKitState(^BOOL { return [apps.presentedViewController isKindOfClass:UIAlertController.class] && !apps.presentedViewController.isBeingPresented; },
            150, @"app-cancel-confirmation-visible", diagnostics, ^{
            UIAlertController *alert = (UIAlertController *)apps.presentedViewController;
            check([alert.message containsString:@"Permanently"] && [alert.message containsString:@"No backup"] &&
                  [alert.message containsString:@"Documents, Library and tmp"] && [alert.message containsString:@"Safari and Messages"],
                  @"clear-confirmation-keeps-permanent-scope-and-best-effort-warning");
            invokeAlertAction(alert, UIAlertActionStyleCancel);
            awaitUIKitState(^BOOL { return apps.presentedViewController == nil; }, 150, @"app-cancel-dismissed", diagnostics, ^{
                check([files fileExistsAtPath:[documents stringByAppendingPathComponent:@"sentinel"]] && ![[apps valueForKey:@"busy"] boolValue], @"actual-cancel-does-not-start-deletion");
                [apps tableView:apps.tableView didSelectRowAtIndexPath:index];
                awaitUIKitState(^BOOL { return [apps.presentedViewController isKindOfClass:UIAlertController.class] && !apps.presentedViewController.isBeingPresented; },
                    150, @"app-accept-confirmation-visible", diagnostics, ^{
                    holdFixturePurge();
                    invokeAlertAction((UIAlertController *)apps.presentedViewController, UIAlertActionStyleDestructive);
                    awaitUIKitState(^BOOL { return atomic_load(&CHOperationReached); }, 150, @"actual-confirm-action-starts-real-purge", diagnostics, ^{
                        check([[apps valueForKey:@"busy"] boolValue], @"real-clear-progress-state");
                        check(!wq_begin_mutation(apps), @"concurrent-mutation-is-refused");
                        awaitUIKitState(^BOOL { return [apps.presentedViewController.title isEqualToString:@"Operation in progress"] && !apps.presentedViewController.isBeingPresented; },
                            150, @"concurrency-refusal-alert-visible", diagnostics, ^{
                            releaseFixturePurge();
                            awaitUIKitState(^BOOL { return ![[apps valueForKey:@"busy"] boolValue] && [[apps valueForKey:@"pendingClearTitle"] isEqualToString:@"Data cleared"]; },
                                150, @"real-worker-outcome-waits-behind-modal", diagnostics, ^{
                                check([apps.presentedViewController.title isEqualToString:@"Operation in progress"], @"result-does-not-replace-active-modal");
                                [apps dismissViewControllerAnimated:NO completion:^{
                                    awaitUIKitState(^BOOL { return [apps.presentedViewController.title isEqualToString:@"Data cleared"] && !apps.presentedViewController.isBeingPresented; },
                                        150, @"real-clear-outcome-delivered-once", diagnostics, ^{
                                        wq_test_tree_hook = nil;
                                        for (NSString *part in @[@"Documents", @"Library", @"tmp"]) {
                                            NSArray *left = [files contentsOfDirectoryAtPath:[owned.containerPath stringByAppendingPathComponent:part] error:nil];
                                            check(left != nil && left.count == 0, @"real-app-clear-retains-empty-part-roots");
                                        }
                                        check([files fileExistsAtPath:[owned.containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]] &&
                                              [files fileExistsAtPath:[unrelated.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"app-clear-preserves-metadata-and-unrelated-container");
                                        check(![files fileExistsAtPath:[CHFixtureContainers stringByAppendingPathComponent:@"Backups"]], @"real-app-clear-creates-no-backup");
                                        [apps dismissViewControllerAnimated:NO completion:^{
                                            [@"keep" writeToFile:[documents stringByAppendingPathComponent:@"sentinel"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                                            [@{@"MCMMetadataIdentifier":@"com.example.changed"} writeToFile:[owned.containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] atomically:YES];
                                            [apps tableView:apps.tableView didSelectRowAtIndexPath:index];
                                            awaitUIKitState(^BOOL { return [apps.presentedViewController isKindOfClass:UIAlertController.class] && !apps.presentedViewController.isBeingPresented; },
                                                150, @"changed-app-confirmation-visible", diagnostics, ^{
                                                invokeAlertAction((UIAlertController *)apps.presentedViewController, UIAlertActionStyleDestructive);
                                                awaitUIKitState(^BOOL { return [apps.presentedViewController.title isEqualToString:@"Clear incomplete"] && !apps.presentedViewController.isBeingPresented; },
                                                    150, @"changed-app-identity-refused-by-real-action", diagnostics, ^{
                                                    check([files fileExistsAtPath:[documents stringByAppendingPathComponent:@"sentinel"]], @"identity-failure-preserves-data");
                                                    [apps dismissViewControllerAnimated:NO completion:^{
                                                        [files removeItemAtPath:CHFixtureContainers error:nil];
                                                        CHTestApplicationRoot = nil; CHFixtureContainers = nil; WQCacheFixtureRoot = nil;
                                                        next();
                                                    }];
                                                });
                                            });
                                        }];
                                    });
                                }];
                            });
                        });
                    });
                });
            });
        });
    });
}
static void runCacheStopFixture(UIWindow *window, dispatch_block_t next)
{
    phase(@"runCacheStopFixture");
    NSString *root = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    WQCacheFixtureRoot = root;
    WQCacheItem *first = cacheFixture(root), *second = cacheFixture(root);
    CHFixtureCaches *controller = [CHFixtureCaches new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
    [controller loadViewIfNeeded];
    [controller setValue:@[first, second] forKey:@"items"];
    [controller setValue:@"Previous cleanup outcome" forKey:@"result"];
    holdFixturePurge();
    [controller cleanItems:@[first, second] generation:[[controller valueForKey:@"scanGeneration"] unsignedIntegerValue]];
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{ return @{@"result":[controller valueForKey:@"result"] ?: @"nil"}; };
    awaitUIKitState(^BOOL { return atomic_load(&CHOperationReached); }, 150, @"cache-stop-reaches-real-purge", diagnostics, ^{
        check(![[controller statusText] containsString:@"Previous cleanup outcome"], @"new-clean-progress-does-not-show-a-stale-success");
        [controller stopClean];
        releaseFixturePurge();
        waitForBatch(controller, 200, ^{
            wq_test_tree_hook = nil;
            NSString *result = [controller valueForKey:@"result"];
            check([result hasPrefix:@"Stopped."] && ![result containsString:@"access denied or data changed"], @"user-stop-is-distinct-from-access-failure");
            check([NSFileManager.defaultManager fileExistsAtPath:[second.targets[0] stringByAppendingPathComponent:@"sentinel"]], @"stop-preserves-later-batch-items");
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
            WQCacheFixtureRoot = nil;
            next();
        });
    });
}

static void runRecoveryConsentFixtures(UIWindow *window, dispatch_block_t next)
{
    phase(@"runRecoveryConsentFixtures");
    CHFixtureApps *apps = [CHFixtureApps new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:apps];
    [window layoutIfNeeded];
    NSDictionary *(^diagnostics)(void) = ^NSDictionary *{ return @{@"alert":apps.presentedViewController.title ?: @"nil"}; };
    atomic_store(&gAccessRecoveryNeeded, NO);
    wq_offer_access_recovery(apps);
    check(!apps.presentedViewController, @"reset-access-cache-is-absent-without-a-recoverable-failure");
    atomic_store(&gAccessRecoveryNeeded, YES);
    wq_offer_access_recovery(apps);
    awaitUIKitState(^BOOL { return [apps.presentedViewController.title isEqualToString:@"Access cache needs recovery"] && !apps.presentedViewController.isBeingPresented; },
        150, @"conditional-recovery-interface-is-reachable", diagnostics, ^{
        UIAlertController *alert = (UIAlertController *)apps.presentedViewController;
        UIAlertAction *reset = alert.actions.lastObject;
        check([reset.title isEqualToString:@"Reset Access Cache"], @"conditional-reset-action-exists");
        void (^handler)(UIAlertAction *) = [reset valueForKey:@"handler"];
        check(handler != nil, @"real-reset-action-has-handler");
        [apps dismissViewControllerAnimated:NO completion:^{
            handler(reset);
            awaitUIKitState(^BOOL { return [apps.presentedViewController.title isEqualToString:@"Recovery incomplete"] && !apps.presentedViewController.isBeingPresented; },
                150, @"unsigned-fixture-reset-reports-missing-app-group", diagnostics, ^{
                atomic_store(&gAccessRecoveryNeeded, NO);
                [apps dismissViewControllerAnimated:NO completion:^{
                    __block _Atomic BOOL answered = NO;
                    __block BOOL accepted = YES;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        accepted = CHConfirmFullScan(@"disposable fixture folders", 1200000, 90);
                        atomic_store(&answered, YES);
                    });
                    awaitUIKitState(^BOOL { return [window.rootViewController.presentedViewController.title isEqualToString:@"Scan app containers?"] && !window.rootViewController.presentedViewController.isBeingPresented; },
                        150, @"full-scan-consent-is-reachable", diagnostics, ^{
                        UIAlertController *consent = (UIAlertController *)window.rootViewController.presentedViewController;
                        UIAlertAction *cancel = consent.actions.firstObject;
                        void (^cancelHandler)(UIAlertAction *) = [cancel valueForKey:@"handler"];
                        check(cancel.style == UIAlertActionStyleCancel && cancelHandler != nil, @"full-scan-cancel-has-real-handler");
                        [consent dismissViewControllerAnimated:NO completion:^{
                            cancelHandler(cancel);
                            awaitUIKitState(^BOOL { return atomic_load(&answered); }, 150, @"full-scan-cancel-releases-waiter", diagnostics, ^{
                                check(!accepted, @"cancelled-consent-does-not-authorize-a-scan");
                                next();
                            });
                        }];
                    });
                }];
            });
        }];
    });
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
    phase(@"scene-connect");
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
    wq_configure_window(self.window);
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
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    wq_configure_window(self.window);
    UIImage *neutralBook = wq_app_icon(@"com.example.uninstalled.facebook");
    UIImage *neutralMusic = wq_app_icon(@"com.example.uninstalled.music");
    check(neutralBook != nil && [UIImagePNGRepresentation(neutralBook) isEqual:UIImagePNGRepresentation(neutralMusic)], @"third-party-fallback-icons-do-not-guess-apple-services");
    runAppListStateFixtures(self.window, ^{
    runCacheListStateFixtures(self.window, ^{
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
    UITabBarController *tabs = [NSClassFromString(@"CHTabs") new];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSString *appearance = NSProcessInfo.processInfo.environment[@"CH_EXPECTED_APPEARANCE"];
        UIUserInterfaceStyle expected = [appearance isEqualToString:@"dark"] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        check(self.window.traitCollection.userInterfaceStyle == expected, @"real-simulator-system-appearance-is-applied");
        CGRect bar = [tabs.tabBar convertRect:tabs.tabBar.bounds toView:self.window];
        check(!tabs.tabBar.hidden && CGRectGetMinY(bar) > self.window.bounds.size.height / 2 &&
              fabs(CGRectGetMaxY(bar) - self.window.bounds.size.height) < 2, @"native-tabs-and-search-are-at-the-bottom-on-iphone-and-ipad");
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
        check([caches.tableView numberOfRowsInSection:0] == 1, @"apps-query-does-not-filter-caches");
        NSArray *items = [caches valueForKey:@"items"];
        check([caches valueForKey:@"status"] == nil, @"empty-completed-cache-note-is-normalized");
        [caches setValue:@"Freed fixture data." forKey:@"result"];
        [caches updatePresentation];
        check([[caches statusText] isEqualToString:@"Freed fixture data."], @"normal-empty-note-does-not-hide-clean-outcome");
        [caches setValue:nil forKey:@"result"];
        id item = items.firstObject;
        NSNumber *cacheKnown = [item valueForKey:@"cacheKnown"];
        [item setValue:@NO forKey:@"cacheKnown"];
        UITableViewCell *partialCell = [caches tableView:caches.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIListContentConfiguration *partialContent = (UIListContentConfiguration *)partialCell.contentConfiguration;
        check([partialContent.secondaryText containsString:@"incomplete"], @"partial-cache-size-is-labelled-incomplete");
        [item setValue:cacheKnown forKey:@"cacheKnown"];
        [item setValue:@NO forKey:@"limited"];
        NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:0];
        UITableViewCell *cacheCell = [caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check(cacheCell.isAccessibilityElement && [cacheCell.accessibilityValue isEqualToString:@"Not selected"], @"cache-row-exposes-unselected-state");
        check([cacheCell.accessibilityLabel containsString:@"Disposable Fixture"] && (cacheCell.accessibilityTraits & UIAccessibilityTraitButton), @"cache-row-groups-name-and-action");
        runTypographyFixtures(self.window, caches);
        [caches tableView:caches.tableView didSelectRowAtIndexPath:cacheRow];
        check([[item valueForKey:@"selected"] boolValue], @"manual-cache-selection");
        [caches.tableView layoutIfNeeded];
        cacheCell = [caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Selected"] && (cacheCell.accessibilityTraits & UIAccessibilityTraitSelected), @"cache-row-exposes-selected-state");
        [caches tableView:caches.tableView didSelectRowAtIndexPath:cacheRow];
        check(![[item valueForKey:@"selected"] boolValue], @"manual-cache-deselection");
        [caches.tableView layoutIfNeeded];
        cacheCell = [caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Not selected"] && !(cacheCell.accessibilityTraits & UIAccessibilityTraitSelected), @"cache-row-clears-selected-accessibility-state");
        [item setValue:@YES forKey:@"limited"];
        cacheCell = [caches tableView:caches.tableView cellForRowAtIndexPath:cacheRow];
        check([cacheCell.accessibilityValue isEqualToString:@"Access limited"], @"limited-cache-row-exposes-refusal-state");
        check(![[items.firstObject valueForKey:@"selected"] boolValue], @"cache-fixture-not-preselected");
        runCacheSearchConfirmationFixture(tabs, caches, ^{
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
        self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        [self.window layoutIfNeeded];
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
            runCacheBatchFixtures(self.window, ^{
                runRealAppClearFixtures(self.window, ^{ runCacheStopFixture(self.window, ^{
                    runCrashConfirmationFixtures(self.window, ^{ runDeferredClearResultFixture(self.window, ^{ runRecoveryConsentFixtures(self.window, ^{ [self beginLifecycleValidation]; }); }); });
                }); });
            });
        }];
        });
        });
    });
    });
    });
}
- (void)beginLifecycleValidation
{
    phase(@"background-and-cold-relaunch");
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
    @autoreleasepool { NSSetUncaughtExceptionHandler(fixtureException); return UIApplicationMain(argc, argv, nil, NSStringFromClass(CHFixtureDelegate.class)); }
}
