//
//  WQApps.m
//  WQ Files app data manager
//  GPL-3.0-or-later.
//

#import "WQApps.h"
#import "WQUI.h"
#import "WQScanTask.h"
#import "WQScanJournal.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQAppsSupport.h"
#import "WQCacheSafety.h"
#import "CHAppData.h"
#import <errno.h>
#import <sys/stat.h>

#pragma mark - Apps manager

@interface WQAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL sizeKnown;
@property (nonatomic) BOOL hasAccess;
@property (nonatomic) BOOL hasIdentity;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) NSInteger installState;   // WQInstallState
@end
@implementation WQAppItem
@end


@interface WQAppsViewController ()
@property (nonatomic) BOOL sortByName;
@property (nonatomic) NSInteger filter;
@end

@implementation WQAppsViewController {
    WQScanTask *_scanTask;
    NSDictionary *_shownScanResult;
    BOOL _resumeScan;

    NSArray<WQAppItem *> *_apps;
    NSArray<WQAppItem *> *_visibleApps;
    NSString *_query;
    NSString *_status;
    float _fraction;   // progress bar under the status; negative hides it
    BOOL _busy;

    NSUInteger _scanGeneration;
    BOOL _scanning;
    BOOL _clearResultDeliveryScheduled;
    NSString *_pendingClearTitle, *_pendingClearMessage;
    NSArray<NSString *> *_indexTitles;
    NSDictionary<NSString *, NSNumber *> *_indexRows;
}

// Session filters cover all, Apple, other, installed and offloaded apps.

typedef NS_ENUM(NSInteger, WQInstallState) { WQInstallUnknown = 0, WQInstallInstalled, WQInstallOffloaded };

// An offloaded app keeps a placeholder bundle (Info.plist and icons) but its
// executable is removed. The bundle path comes from the LaunchServices
static WQInstallState wq_app_install_state(NSString *bundleID)
{
    NSString *path = bundleID.length ? wq_bundle_path_for_id(bundleID) : nil;
    if (!path.length) return WQInstallUnknown;
    // Built-in apps live on the read-only system volume, which this app can't
    // read; they can't be offloaded (removable Apple apps live in bundle
    // containers like everyone else's).
    if ([path hasPrefix:@"/Applications/"] || [path hasPrefix:@"/System/"]) {
        return WQInstallInstalled;
    }
    // Checking whether a path exists works even where reading is refused
    // (iOS 26): the program is almost always named like the bundle
    // (Drive.app/Drive), so finding it there settles "installed" without
    // Info.plist.
    struct stat guessed;
    NSString *guess = [path stringByAppendingPathComponent:path.lastPathComponent.stringByDeletingPathExtension];
    if (lstat(guess.fileSystemRepresentation, &guessed) == 0 && S_ISREG(guessed.st_mode)) {
        return WQInstallInstalled;
    }
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    // Installed apps' bundles refuse reading (iOS 26 and 27.0.1), while an
    // offloaded app's placeholder bundle can be read. Try a plain read first.
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    static NSInteger tokenAttempts, tokenSuccesses;
    BOOL tryToken = NO;
    @synchronized ([WQAppItem class]) { tryToken = !data && (tokenSuccesses > 0 || tokenAttempts < 3); }
    if (tryToken) {
        data = (wq_grant(path.stringByDeletingLastPathComponent) || wq_grant(path)) ? wq_read(plistPath, 4 * 1024 * 1024, NULL) : nil;
        @synchronized ([WQAppItem class]) { tokenAttempts++; if (data) tokenSuccesses++; }
    }
    id info = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![info isKindOfClass:NSDictionary.class]) return WQInstallUnknown;
    NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
    if (!executable.length || [executable containsString:@"/"]) return WQInstallUnknown;
    NSString *exePath = [path stringByAppendingPathComponent:executable];
    struct stat st;
    if (lstat(exePath.fileSystemRepresentation, &st) == 0) return WQInstallInstalled;
    int err = errno;
    if (wq_stat(exePath, &st)) return WQInstallInstalled;
    if (err == ENOENT) return WQInstallOffloaded;
    return WQInstallUnknown;
}

static BOOL wq_app_is_apple(WQAppItem *app)
{
    return [app.bundleID hasPrefix:@"com.apple."];
}

static NSString *wq_apps_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

static BOOL wq_dir_size_cancellable(NSString *dir, NSString *taskID, WQScanCancellation *cancellation,
                                     unsigned long long *sizeOut, BOOL *completeOut)
{
    if (completeOut) *completeOut = NO;
    if (sizeOut) *sizeOut = 0;
    if (cancellation.isCancelled) return NO;
    unsigned long long total = 0;
    WQMeasureResult result = wq_measure_tree_resumable(dir, @"apps", taskID, cancellation, &total, ^(void (^work)(void)) { wq_scan_read(work); });
    if (result == WQMeasureResultCancelled) return NO;
    if (sizeOut) *sizeOut = total;
    if (completeOut) *completeOut = result != WQMeasureResultLimited;
    return YES;
}


- (NSDictionary *)snapshotRows:(NSArray<WQAppItem *> *)rows note:(NSString *)note
{
    NSMutableArray *saved = [NSMutableArray new];
    for (WQAppItem *item in rows) {
        NSMutableDictionary *encoded = [WQScanEncode(item, @[@"container", @"bundleID", @"name", @"bytes", @"sizeKnown", @"hasAccess", @"hasIdentity", @"containerDevice", @"containerInode", @"installState"]) mutableCopy];
        [saved addObject:encoded];
    }
    return @{@"rows": saved, @"note": note ?: @""};
}

- (void)scanTaskChanged:(NSNotification *__unused)notification
{
    if (_busy && !_scanning && !_scanTask.running) return; // preserve mutation progress
    NSDictionary *result = _scanTask.result;
    BOOL resultChanged = result && result != _shownScanResult;
    if (resultChanged) {
        NSMutableArray *rows = [NSMutableArray new];
        for (id encoded in [result[@"rows"] isKindOfClass:NSArray.class] ? result[@"rows"] : @[]) {
            if (![encoded isKindOfClass:NSDictionary.class]) continue;
            WQAppItem *item = [WQAppItem new];
            WQScanDecode(item, encoded, @[@"container", @"bundleID", @"name"], @[@"bytes", @"sizeKnown", @"hasAccess", @"hasIdentity", @"containerDevice", @"containerInode", @"installState"]);
            if (!item.hasAccess || !item.hasIdentity) continue;
            [rows addObject:item];
        }
        _apps = rows;
        _shownScanResult = result;
        [self rebuildVisibleApps];
    }
    _scanning = _scanTask.running;
    _fraction = _scanning && !_scanTask.paused ? _scanTask.fraction : -1;
    NSString *note = [result[@"note"] isKindOfClass:NSString.class] ? result[@"note"] : nil;
    if (!note.length) note = nil;
    _status = _scanning ? (_scanTask.paused ? WQLocalized(@"Scan paused") :
        (_scanTask.status.length ? WQLocalized(_scanTask.status) : WQLocalized(@"Scan queued; previous results kept"))) :
        (_scanTask.status.length ? WQLocalized(_scanTask.status) : note);
    _busy = _scanning;
    if (!_scanning) [self.refreshControl endRefreshing];
    [self updatePresentation];
}

- (void)updatePresentation
{
    NSString *message = [self statusText];
    if (!self.visibleApps.count && !message.length) {
        message = (_query.length || _filter > 0) ? @"No results" :
            (_shownScanResult ? @"No accessible apps" : @"Refresh to update");
    }
    wq_empty_message(self.tableView, self.visibleApps.count ? nil : message, _scanning && !_scanTask.paused ? _fraction : -1);
    [self.tableView reloadData];
    [self updateButtons];
}

- (NSString *)statusText
{
    NSString *status = _status.length ? _status : (_scanTask.interrupted ? @"Scan interrupted. Resume to continue." : nil);
    if (_scanTask.persistenceFailed) return status.length ? [status stringByAppendingString:@"\nCould not save scan state. Keep charony open."] : @"Could not save scan state. Keep charony open.";
    return status;
}

- (void)updateButtons
{
    UIBarButtonItem *menu = [self sortButton];
    menu.accessibilityLabel = @"Filters and scan controls";
    menu.accessibilityIdentifier = @"filters";
    menu.enabled = !_busy || _scanning;
    self.navigationItem.rightBarButtonItems = @[menu, wq_refresh_button(self, @selector(userRefresh), !_busy || _scanning)];
}

- (void)toggleScan
{
    if (_scanTask.running) [_scanTask pause];
    else { _resumeScan = YES; [self scan]; }
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _fraction = -1;
    wq_prepare_list(self, @"Apps");
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = WQLocalizedNullable(@"Search apps");
    search.searchBar.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    search.searchBar.searchTextField.maximumContentSizeCategory = UIContentSizeCategoryLarge;
    search.searchBar.searchTextField.adjustsFontForContentSizeCategory = YES;
    search.searchBar.searchTextField.font = wq_font(UIFontTextStyleBody, self.traitCollection);
    _contextSearchController = search;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    _scanTask = [WQScanTask taskNamed:@"apps"];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scanTaskChanged:) name:WQScanTaskChangedNotification object:_scanTask];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self scanTaskChanged:nil];
}

- (void)contentSizeChanged:(NSNotification *)notification
{
    [self updatePresentation];
    _contextSearchController.searchBar.searchTextField.font = wq_font(UIFontTextStyleBody, self.traitCollection);
    ((UILabel *)self.navigationItem.leftBarButtonItem.customView).font = wq_font(UIFontTextStyleHeadline, self.traitCollection);
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self scanTaskChanged:nil];
 }

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    _fraction = -1;
    [self updatePresentation];
}
- (void)scan
{
    if (_busy && !_scanning) { [self.refreshControl endRefreshing]; return; }
    WQScanCancellation *cancellation = [WQScanCancellation new];
    NSUInteger taskGeneration = [_scanTask beginFresh:!_resumeScan cancel:^{ [cancellation cancel]; }];
    _resumeScan = NO;
    if (!taskGeneration) return;
    NSString *taskID = _scanTask.identifier;

    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    [self setBusy:YES status:@"Finding apps…"];
    dispatch_async(wq_scan_queue(), ^{
        NSArray *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, cancellation,
            ^(int64_t done, int64_t total, NSUInteger __unused found) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    [self->_scanTask progress:@"Finding apps…" fraction:total ? (float)((double)done / total) : 0 generation:taskGeneration];
                });
            });
        if (cancellation.isCancelled) return;
        wq_load_display_names();
        NSMutableArray *apps = [NSMutableArray new];
        NSUInteger index = 0;
        NSString *home = NSHomeDirectory().stringByResolvingSymlinksInPath;
        for (NSString *container in containers) {
            if (cancellation.isCancelled) return;
            index++;
            if ([container.stringByResolvingSymlinksInPath isEqualToString:home] || !wq_grant(container)) continue;
            NSString *bundle = wq_container_label(container);
            struct stat identity;
            if (!WQAppsSupportBundleIDValid(bundle) || !wq_stat(container, &identity) || !S_ISDIR(identity.st_mode) ||
                !WQCacheSafetyHasNoSymlinkAncestry(container, NO) || !wq_stat_readable(&identity) || !wq_list(container, NULL)) continue;
            WQAppItem *app = [WQAppItem new];
            app.container = container;
            app.bundleID = bundle;
            app.name = wq_display_name(bundle) ?: bundle;
            app.hasAccess = YES;
            app.hasIdentity = YES;
            app.containerDevice = identity.st_dev;
            app.containerInode = identity.st_ino;
            (void)wq_app_icon(bundle);
            app.installState = wq_app_install_state(bundle);
            unsigned long long bytes = 0;
            BOOL complete = NO;
            if (!wq_dir_size_cancellable(container, taskID, cancellation, &bytes, &complete)) return;
            app.bytes = bytes;
            app.sizeKnown = complete;
            [apps addObject:app];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                [self->_scanTask progress:@"Measuring apps…" fraction:containers.count ? (float)index / containers.count : 0 generation:taskGeneration];
            });
        }
        NSString *note = !wq_app_group() ? @"An App Group is required. Re-sign charony with a tool that preserves its App Group entitlement." :
            !containers ? @"App discovery failed or was cancelled. Refresh to retry." : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            NSMutableDictionary *snapshot = [[self snapshotRows:apps note:note] mutableCopy];
            snapshot[@"complete"] = @(containers != nil);
            [self->_scanTask finish:snapshot generation:taskGeneration];
            wq_offer_access_recovery(self);
        });
    });
}

- (NSArray<WQAppItem *> *)visibleApps
{
    return _visibleApps ?: @[];
}

- (void)rebuildVisibleApps
{
    NSArray<WQAppItem *> *shown = _apps ?: @[];
    NSInteger filter = _filter;
    if (filter > 0) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            if (filter == 1) return wq_app_is_apple(a);
            if (filter == 2) return !wq_app_is_apple(a);
            if (filter == 3) return a.installState == WQInstallInstalled;
            if (filter == 4) return a.installState == WQInstallOffloaded;
            return YES;
        }]];
    }
    if (_query.length) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            return [a.name localizedCaseInsensitiveContainsString:self->_query] ||
                   [a.bundleID localizedCaseInsensitiveContainsString:self->_query];
        }]];
    }
    BOOL byName = _sortByName;
    _visibleApps = [shown sortedArrayUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
        NSComparisonResult names = [(a.name ?: @"") localizedStandardCompare:(b.name ?: @"")];
        if (byName || a.bytes == b.bytes) return names;
        return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
    }];
    // Alphabet sidebar when sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (byName && _visibleApps.count >= 25) {
        [_visibleApps enumerateObjectsUsingBlock:^(WQAppItem *app, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_apps_index_letter(app.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return (_busy && !_apps.count) ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < self.visibleApps.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (UIBarButtonItem *)sortButton
{
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        BOOL byName = weakSelf.sortByName;
        UIAction *size = [UIAction actionWithTitle:WQLocalizedNullable(@"Size") image:nil identifier:nil handler:^(UIAction *__unused a) {
            weakSelf.sortByName = NO;
            [weakSelf resortApps];
        }];
        UIAction *name = [UIAction actionWithTitle:WQLocalizedNullable(@"Name") image:nil identifier:nil handler:^(UIAction *__unused a) {
            weakSelf.sortByName = YES;
            [weakSelf resortApps];
        }];
        size.state = byName ? UIMenuElementStateOff : UIMenuElementStateOn;
        name.state = byName ? UIMenuElementStateOn : UIMenuElementStateOff;
        size.subtitle = WQLocalized(@"Largest first");
        name.subtitle = WQLocalized(@"A–Z");
        UIMenu *sort = [UIMenu menuWithTitle:WQLocalizedNullable(@"Sort By") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[size, name]];
        NSInteger current = weakSelf.filter;
        NSArray *titles = @[WQLocalized(@"All Apps"), WQLocalized(@"Apple Apps"), WQLocalized(@"Other Apps"), WQLocalized(@"Installed"), WQLocalized(@"Offloaded")];
        // Installed/Offloaded only where bundles could be checked (not on iOS 26).
        WQAppsViewController *strongSelf = weakSelf;
        // Only offer Installed/Offloaded when nearly every app's state is
        // known; otherwise those filters would quietly hide the unknown ones.
        NSArray<WQAppItem *> *all = strongSelf ? strongSelf->_apps : @[];
        NSUInteger unknown = 0;
        for (WQAppItem *app in all) if (app.installState == WQInstallUnknown) unknown++;
        BOOL installKnown = all.count > 0 && unknown * 10 <= all.count;
        NSMutableArray *filters = [NSMutableArray new];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            if (i >= 3 && !installKnown && i != current) continue;
            UIAction *f = [UIAction actionWithTitle:WQLocalizedNullable(titles[(NSUInteger)i]) image:nil identifier:nil handler:^(UIAction *__unused a) {
                weakSelf.filter = i;
                [weakSelf resortApps];
            }];
            f.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [filters addObject:f];
        }
        UIMenu *show = [UIMenu menuWithTitle:WQLocalizedNullable(@"Show") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:filters];
        NSMutableArray<UIMenuElement *> *sections = [NSMutableArray arrayWithObjects:sort, show, nil];
        if (strongSelf && (strongSelf->_scanTask.running || strongSelf->_scanTask.userPaused || strongSelf->_scanTask.interrupted)) {
            UIAction *scan = [UIAction actionWithTitle:strongSelf->_scanTask.running ? @"Pause Scan" : @"Resume Scan" image:nil identifier:nil handler:^(UIAction *__unused action) { [weakSelf toggleScan]; }];
            [sections addObject:scan];
        }
        completion(sections);
    }];
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"]
                                             menu:[UIMenu menuWithChildren:@[items]]];
}

- (void)resortApps
{
    [self rebuildVisibleApps];
    [self updatePresentation];
    [self.tableView reloadSectionIndexTitles];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleApps];
    [self updatePresentation];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Progress belongs to the section header. Every advertised row must have
    // an app model, including the first scan and a refresh of an empty list.
    return (NSInteger)self.visibleApps.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    (void)section;
    NSString *status = [self statusText];
    if (!self.visibleApps.count || !status.length) return nil;
    WQProgressHeaderView *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"progress"]
        ?: [[WQProgressHeaderView alloc] initWithReuseIdentifier:@"progress"];
    [header setText:status fraction:_fraction];
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = app.name;
    NSString *size = app.sizeKnown ? wq_size_text(app.bytes) : [NSString stringWithFormat:@"%@ measured · size incomplete", wq_size_text(app.bytes)];
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@%@", app.bundleID, size, app.installState == WQInstallOffloaded ? @" · offloaded" : @""];
    content.textProperties.font = wq_font(UIFontTextStyleBody, self.traitCollection);
    content.secondaryTextProperties.font = wq_font(UIFontTextStyleFootnote, self.traitCollection);
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    content.image = wq_app_icon(app.bundleID);
    content.imageProperties.maximumSize = CGSizeMake(40, 40);
    cell.contentConfiguration = content;
    cell.accessibilityIdentifier = [@"app." stringByAppendingString:app.bundleID];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy || _scanTask.userPaused) return;
    if (_pendingClearTitle) { [self presentPendingClearResult]; return; }
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    UIAlertController *alert = wq_alert_controller([NSString stringWithFormat:@"Clear %@?", app.name],
        @"Permanently empties Documents, Library and tmp. Logins, settings and offline content will be lost. No backup is created. Close the app first. Safari and Messages cleanup is best effort; other data may remain.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Clear Data", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused action) {
        [self dismissViewControllerAnimated:YES completion:^{ [self clear:app]; }];
    })];
    wq_present_confirmation(self, alert);
}
- (void)clear:(WQAppItem *)app
{
    if (_busy || _scanTask.userPaused) return;
    if (!wq_begin_mutation(self)) return;
    [self setBusy:YES status:@"Clearing data…"];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        unsigned long long freed = 0;
        BOOL ok = CHClearAppData(app.container, app.bundleID, app.containerDevice, app.containerInode, &freed, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            wq_end_mutation();
            [self setBusy:NO status:nil];
            [self scan];
            self->_pendingClearTitle = ok ? @"Data cleared" : @"Clear incomplete";
            self->_pendingClearMessage = [NSString stringWithFormat:@"Freed about %@. %@", wq_size_text(freed), error ?: @"Other containers and system-managed data may remain."];
            [self presentPendingClearResult];
        });
    });
}
- (void)presentPendingClearResult
{
    if (!_pendingClearTitle || !self.view.window ||
        self.navigationController.topViewController != self ||
        self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive) return;
    BOOL modal = NO;
    for (UIViewController *host = self; host; host = host.parentViewController)
        if (host.presentedViewController) { modal = YES; break; }
    if (modal) {
        // UIAlert dismissal does not reliably call the presenting screen's
        // viewDidAppear. Retain the outcome and retry only while this screen
        // is visible/active; navigation/foreground callbacks resume delivery.
        if (!_clearResultDeliveryScheduled) {
            _clearResultDeliveryScheduled = YES;
            __weak WQAppsViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                WQAppsViewController *controller = weakSelf;
                if (!controller) return;
                controller->_clearResultDeliveryScheduled = NO;
                [controller presentPendingClearResult];
            });
        }
        return;
    }
    wq_alert(self, _pendingClearTitle, _pendingClearMessage);
    _pendingClearTitle = nil;
    _pendingClearMessage = nil;
}
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self presentPendingClearResult];
    wq_offer_access_recovery(self);
}
- (void)applicationDidBecomeActive:(NSNotification *__unused)notification
{
    [self presentPendingClearResult];
    wq_offer_access_recovery(self);
}
@end
