// charony, derived from WQ Files by kolbicz. GPL-3.0-or-later.
#import <UIKit/UIKit.h>
#import "WQApps.h"
#import "WQCache.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQScanTask.h"

// UISearchTab supplies the native trailing search affordance. The selected
// controller moves into its navigation stack for search, keeping selections
// and scan state in the same controller instance.
@interface CHSearchNavigation : UINavigationController
@property (nonatomic) BOOL contextVisible;
@property (nonatomic, copy) dispatch_block_t contextDidAppear;
@end
@implementation CHSearchNavigation
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    self.contextVisible = YES;
    if (self.contextDidAppear) self.contextDidAppear();
}
- (void)viewWillDisappear:(BOOL)animated
{
    self.contextVisible = NO;
    [super viewWillDisappear:animated];
}
@end
@interface CHTabs : UITabBarController <UITabBarControllerDelegate, UISearchControllerDelegate, CHContextAlertPresentation>
@property (nonatomic, strong) UITab *contextTab;
@property (nonatomic, strong) UITab *pendingTab;
@property (nonatomic, strong) UISearchTab *searchTab;
@property (nonatomic, strong) UINavigationController *contextNavigation;
@property (nonatomic, strong) CHSearchNavigation *searchNavigation;
@property (nonatomic, strong) UITableViewController *searchRoot;
@property (nonatomic, copy) NSString *contextQuery;
@property (nonatomic, strong) UIAlertController *contextAlert;
@property (nonatomic, weak) UIViewController *contextAlertHost;
@property (nonatomic) BOOL contextRestoreScheduled;
@property (nonatomic) BOOL searchActivationPending;
- (void)restoreContext;
- (void)activatePendingSearch;
@end
@implementation CHTabs
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.mode = UITabBarControllerModeTabBar;
    // Keep UIKit's native bottom tabs and trailing Search on supported iPads.
    self.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassCompact;
    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[WQAppsViewController new]];
    UINavigationController *caches = [[UINavigationController alloc] initWithRootViewController:[WQCacheCleanerViewController new]];
    apps.navigationBar.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    caches.navigationBar.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    self.tabBar.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    UITab *appsTab = [[UITab alloc] initWithTitle:@"Apps" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:@"apps" viewControllerProvider:^UIViewController *(UITab *__unused tab) { return apps; }];
    UITab *cachesTab = [[UITab alloc] initWithTitle:@"Caches" image:[UIImage systemImageNamed:@"sparkles"] identifier:@"caches" viewControllerProvider:^UIViewController *(UITab *__unused tab) { return caches; }];
    self.searchNavigation = [[CHSearchNavigation alloc] initWithRootViewController:[UIViewController new]];
    self.searchNavigation.navigationBar.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    __weak CHTabs *weakSelf = self;
    self.searchNavigation.contextDidAppear = ^{ [weakSelf activatePendingSearch]; };
    self.searchTab = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *__unused tab) { return weakSelf.searchNavigation; }];
    self.tabs = @[appsTab, cachesTab, self.searchTab];
    self.selectedTab = appsTab;
}
- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectTab:(UITab *)tab
{
    (void)tabBarController;
    if (tab == self.searchTab && (self.pendingTab || self.contextRestoreScheduled)) return NO;
    if (tab == self.searchTab && self.selectedTab != self.searchTab) {
        self.contextQuery = nil;
        self.searchActivationPending = YES;
        self.contextTab = self.selectedTab;
        self.contextNavigation = (UINavigationController *)self.selectedViewController;
        self.searchRoot = (UITableViewController *)self.contextNavigation.topViewController;
        [self.searchRoot loadViewIfNeeded];
        self.searchRoot.navigationItem.searchController = [(id<CHSearchable>)self.searchRoot contextSearchController];
        self.searchRoot.navigationItem.searchController.delegate = self;
        self.contextNavigation.viewControllers = @[[UIViewController new]];
        self.searchNavigation.viewControllers = @[self.searchRoot];
    } else if (tab != self.searchTab && self.searchRoot) {
        UISearchController *search = self.searchRoot.navigationItem.searchController;
        if (search.active || search.presentingViewController || self.pendingTab || self.contextRestoreScheduled) {
            // UIKit must finish dismissing Search before its presenting
            // controller moves between navigation stacks.
            self.pendingTab = tab;
            if (!self.contextQuery) self.contextQuery = search.searchBar.text ?: @"";
            search.active = NO;
            return NO;
        }
        [self restoreContext];
    }
    return YES;
}
- (void)tabBarController:(UITabBarController *)tabBarController didSelectTab:(UITab *)selectedTab previousTab:(UITab *)previousTab
{
    (void)tabBarController;
    (void)previousTab;
    if (selectedTab == self.searchTab) {
        [self activatePendingSearch];
    }
}
- (void)activatePendingSearch
{
    UITableViewController *root = self.searchRoot;
    dispatch_async(dispatch_get_main_queue(), ^{
        // One queue turn after tab selection is not an appearance guarantee,
        // especially on iPad. viewDidAppear requests this again when ready.
        if (!self.searchActivationPending || self.selectedTab != self.searchTab || self.searchRoot != root ||
            !self.searchNavigation.contextVisible || self.searchNavigation.topViewController != root || !root.view.window)
            return;
        self.searchActivationPending = NO;
        root.navigationItem.searchController.active = YES;
        [root.navigationItem.searchController.searchBar becomeFirstResponder];
    });
}
- (void)restoreContext
{
    self.searchActivationPending = NO;
    UITableViewController *root = self.searchRoot;
    UISearchController *search = root.navigationItem.searchController;
    NSString *query = self.contextQuery ?: search.searchBar.text ?: @"";
    self.contextQuery = nil;
    self.searchRoot = nil;
    root.navigationItem.searchController.delegate = nil;
    root.navigationItem.searchController.active = NO;
    root.navigationItem.searchController = nil;
    self.searchNavigation.viewControllers = @[[UIViewController new]];
    self.contextNavigation.viewControllers = @[root];
    // UIKit clears Search's text/filter during dismissal. Replay the captured
    // query after that cleanup, before a queued confirmation is presented.
    dispatch_async(dispatch_get_main_queue(), ^{
        search.searchBar.text = query;
        [(id<CHSearchable>)root updateSearchResultsForSearchController:search];
    });
}
- (void)willDismissSearchController:(UISearchController *)searchController
{
    if (searchController == [(id<CHSearchable>)self.searchRoot contextSearchController] && !self.contextQuery)
        self.contextQuery = searchController.searchBar.text ?: @"";
}
- (void)didPresentSearchController:(UISearchController *)searchController
{
    // Search installs its text field during presentation; apply the current
    // bounded app style after UIKit has prepared the actual field.
    searchController.searchBar.searchTextField.font = wq_font(UIFontTextStyleBody, self.traitCollection);
}
- (void)didDismissSearchController:(UISearchController *)searchController
{
    if (!self.searchRoot || self.contextRestoreScheduled ||
        searchController != [(id<CHSearchable>)self.searchRoot contextSearchController]) return;
    self.contextRestoreScheduled = YES;
    // UIKit is still finishing its presentation transaction inside this
    // delegate callback. Reparenting here reenters iPad navigation-bar layout.
    // Restore on the next main-queue turn, after that transaction returns.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.searchRoot || searchController != [(id<CHSearchable>)self.searchRoot contextSearchController]) {
            self.contextRestoreScheduled = NO;
            return;
        }
        UITab *context = self.pendingTab ?: self.contextTab;
        self.pendingTab = nil;
        [self restoreContext];
        self.selectedTab = context;
        UIAlertController *alert = self.contextAlert;
        UIViewController *host = self.contextAlertHost;
        self.contextAlert = nil;
        self.contextAlertHost = nil;
        self.contextRestoreScheduled = NO;
        if (alert && host) dispatch_async(dispatch_get_main_queue(), ^{
            // A pending confirmation never follows the user to another tab.
            if (host.view.window && host.navigationController.topViewController == host && !host.presentedViewController)
                [host presentViewController:alert animated:YES completion:nil];
        });
    });
}
- (BOOL)presentContextAlert:(UIAlertController *)alert from:(UIViewController *)host
{
    if (host != self.searchRoot) return NO;
    if (self.contextAlert || self.pendingTab) return YES;
    self.contextAlert = alert;
    self.contextAlertHost = host;
    self.contextQuery = self.searchRoot.navigationItem.searchController.searchBar.text ?: @"";
    self.searchRoot.navigationItem.searchController.active = NO;
    return YES;
}
@end

static BOOL CHConfirmFullScan(NSString *what, int64_t ids, double seconds)
{
    __block BOOL accepted = NO;
    dispatch_semaphore_t answer = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
                window = ((UIWindowScene *)scene).keyWindow;
        UIViewController *host = window.rootViewController;
        while (host.presentedViewController) host = host.presentedViewController;
        if (!host || !window) { dispatch_semaphore_signal(answer); return; }
        NSString *message = [NSString stringWithFormat:@"Finding %@ may scan %lld file identifiers and take about %.0f minutes. You can pause from the current tab. Scanning reads metadata only.", what, (long long)ids, seconds / 60.0];
        UIAlertController *alert = wq_alert_controller(@"Scan app containers?", message, UIAlertControllerStyleAlert);
        [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused action) { dispatch_semaphore_signal(answer); })];
        [alert addAction:wq_alert_action(@"Scan", UIAlertActionStyleDefault, ^(UIAlertAction *__unused action) { accepted = YES; dispatch_semaphore_signal(answer); })];
        [host presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(answer, DISPATCH_TIME_FOREVER);
    return accepted;
}

@interface CHSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation CHSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session;
    (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    wq_configure_window(self.window);
    NSString *failure = wq_access_capability_failure();
    if (failure) {
        UIViewController *blocked = [UIViewController new];
        blocked.view.backgroundColor = UIColor.systemBackgroundColor;
        blocked.view.maximumContentSizeCategory = UIContentSizeCategoryLarge;
        UILabel *message = [UILabel new];
        message.maximumContentSizeCategory = UIContentSizeCategoryLarge;
        message.font = wq_font(UIFontTextStyleBody, self.window.traitCollection);
        message.adjustsFontForContentSizeCategory = YES;
        message.numberOfLines = 0;
        message.text = failure;
        message.translatesAutoresizingMaskIntoConstraints = NO;
        [blocked.view addSubview:message];
        UILayoutGuide *margins = blocked.view.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [message.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [message.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [message.centerYAnchor constraintEqualToAnchor:blocked.view.centerYAnchor]
        ]];
        self.window.rootViewController = blocked;
    } else self.window.rootViewController = [CHTabs new];
    [self.window makeKeyAndVisible];
}
@end
@interface CHAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation CHAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    (void)application;
    (void)options;
    wq_set_container_list_provider(wq_ls_container_paths);
    wq_set_container_label_resolver(wq_bundle_id_for_container);
    wq_set_group_label_resolver(wq_group_id_for_container);
    wq_set_full_scan_ui(CHConfirmFullScan, NULL);
    wq_scan_lifecycle_install();
    // Complete private-state cleanup before either tab can start a worker.
    (void)[WQScanTask taskNamed:@"apps"];
    (void)[WQScanTask taskNamed:@"clean"];
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)application;
    (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"charony" sessionRole:session.role];
    configuration.delegateClass = CHSceneDelegate.class;
    return configuration;
}
@end
int main(int argc, char *argv[])
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CHAppDelegate.class)); }
}
