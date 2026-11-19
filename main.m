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
@interface CHTabs : UITabBarController <UITabBarControllerDelegate, UISearchControllerDelegate>
@property (nonatomic, strong) UITab *contextTab;
@property (nonatomic, strong) UISearchTab *searchTab;
@property (nonatomic, strong) UINavigationController *contextNavigation;
@property (nonatomic, strong) UINavigationController *searchNavigation;
@property (nonatomic, strong) UITableViewController *searchRoot;
@end
@implementation CHTabs
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.mode = UITabBarControllerModeTabBar;
    UINavigationController *apps = [[UINavigationController alloc] initWithRootViewController:[WQAppsViewController new]];
    UINavigationController *caches = [[UINavigationController alloc] initWithRootViewController:[WQCacheCleanerViewController new]];
    UITab *appsTab = [[UITab alloc] initWithTitle:@"Apps" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:@"apps" viewControllerProvider:^UIViewController *(UITab *__unused tab) { return apps; }];
    UITab *cachesTab = [[UITab alloc] initWithTitle:@"Caches" image:[UIImage systemImageNamed:@"sparkles"] identifier:@"caches" viewControllerProvider:^UIViewController *(UITab *__unused tab) { return caches; }];
    self.searchNavigation = [[UINavigationController alloc] initWithRootViewController:[UIViewController new]];
    __weak CHTabs *weakSelf = self;
    self.searchTab = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *__unused tab) { return weakSelf.searchNavigation; }];
    self.tabs = @[appsTab, cachesTab, self.searchTab];
    self.selectedTab = appsTab;
}
- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectTab:(UITab *)tab
{
    (void)tabBarController;
    if (tab == self.searchTab && self.selectedTab != self.searchTab) {
        self.contextTab = self.selectedTab;
        self.contextNavigation = (UINavigationController *)self.selectedViewController;
        self.searchRoot = (UITableViewController *)self.contextNavigation.topViewController;
        [self.searchRoot loadViewIfNeeded];
        self.searchRoot.navigationItem.searchController = [(id<CHSearchable>)self.searchRoot contextSearchController];
        self.searchRoot.navigationItem.searchController.delegate = self;
        self.contextNavigation.viewControllers = @[[UIViewController new]];
        self.searchNavigation.viewControllers = @[self.searchRoot];
    } else if (tab != self.searchTab && self.searchRoot) {
        [self restoreContext];
    }
    return YES;
}
- (void)tabBarController:(UITabBarController *)tabBarController didSelectTab:(UITab *)selectedTab previousTab:(UITab *)previousTab
{
    (void)tabBarController;
    (void)previousTab;
    if (selectedTab == self.searchTab) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.searchRoot.navigationItem.searchController.active = YES;
            [self.searchRoot.navigationItem.searchController.searchBar becomeFirstResponder];
        });
    }
}
- (void)restoreContext
{
    UITableViewController *root = self.searchRoot;
    self.searchRoot = nil;
    root.navigationItem.searchController.delegate = nil;
    root.navigationItem.searchController.active = NO;
    root.navigationItem.searchController = nil;
    self.searchNavigation.viewControllers = @[[UIViewController new]];
    self.contextNavigation.viewControllers = @[root];
}
- (void)didDismissSearchController:(UISearchController *)searchController
{
    (void)searchController;
    if (self.searchRoot) {
        UITab *context = self.contextTab;
        [self restoreContext];
        self.selectedTab = context;
    }
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
    NSString *failure = wq_access_capability_failure();
    if (failure) {
        UIViewController *blocked = [UIViewController new];
        blocked.view.backgroundColor = UIColor.systemBackgroundColor;
        UILabel *message = [UILabel new];
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
