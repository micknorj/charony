//
//  WQCache.m
//  WQ Files cache cleaner
//  GPL-3.0-or-later.
//

#import "WQCache.h"
#import "WQUI.h"
#import "WQScanTask.h"
#import "WQScanJournal.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQCacheSafety.h"
#import "WQAccessSafety.h"

#import <errno.h>
#import <sys/stat.h>

#pragma mark - Cache cleaner

// Where iOS keeps crash and diagnostic reports: mobile's Library (the paths
// in the OS's own code), and the osanalytics system group as a fallback.
// That folder doesn't exist on iOS 27.0.1, which made Crash Logs "limited".
#ifdef WQ_CACHE_TESTING
static NSArray<NSString *> *WQCacheFixtureCrashRoots;
#endif
static NSArray<NSString *> *WQCacheCrashLogCandidates(void)
{
#ifdef WQ_CACHE_TESTING
    if (WQCacheFixtureCrashRoots) return WQCacheFixtureCrashRoots;
#endif
    return @[@"/private/var/mobile/Library/Logs/CrashReporter",
             @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter"];
}

@interface WQCacheTargetRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic) BOOL existed;
@property (nonatomic) BOOL identityKnown;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@property (nonatomic) mode_t mode;
@end
@implementation WQCacheTargetRecord
@end

@interface WQCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL cacheKnown;
@property (nonatomic) BOOL tempKnown;
@property (nonatomic) BOOL limited;
@property (nonatomic) BOOL crashLogs;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic) BOOL containerIdentityKnown;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) mode_t containerMode;
@property (nonatomic, copy) NSArray<WQCacheTargetRecord *> *targetRecords;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end
@implementation WQCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

static void WQCacheSelectionCategories(NSArray<WQCacheItem *> *items,
                                       BOOL *hasApps,
                                       BOOL *hasCrashLogs,
                                       NSUInteger *appCount)
{
    BOOL apps = NO, crashLogs = NO;
    NSUInteger count = 0;
    for (WQCacheItem *item in items) {
        if (item.crashLogs) {
            crashLogs = YES;
        } else {
            apps = YES;
            count++;
        }
    }
    if (hasApps) *hasApps = apps;
    if (hasCrashLogs) *hasCrashLogs = crashLogs;
    if (appCount) *appCount = count;
}

static NSString *WQCacheConfirmationScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    NSUInteger appCount = 0;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, &appCount);
    if (hasApps && hasCrashLogs) {
        return WQLocalizedFormat(appCount == 1
                ? @"Delete Library/Caches and tmp for %lu app, plus Crash Logs"
                : @"Delete Library/Caches and tmp for %lu apps, plus Crash Logs",
                (unsigned long)appCount);
    }
    if (hasApps) {
        return WQLocalizedFormat(appCount == 1
                ? @"Delete Library/Caches and tmp for %lu app"
                : @"Delete Library/Caches and tmp for %lu apps",
                (unsigned long)appCount);
    }
    if (hasCrashLogs) return WQLocalized(@"Delete Crash Logs");
    return WQLocalized(@"Delete the selected cache targets");
}

static NSString *WQCacheFooterScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, NULL);
    if (hasApps && hasCrashLogs) {
        return WQLocalized(@"Clears each selected app's Library/Caches and tmp, and deletes selected Crash Logs. Apps rebuild their caches as you use them; some keep offline content (music, maps, downloads) there and will download it again. No backup is kept.");
    }
    if (hasApps) {
        return WQLocalized(@"Clears each selected app's Library/Caches and tmp. Apps rebuild their caches as you use them; some keep offline content (music, maps, downloads) there and will download it again. No backup is kept.");
    }
    if (hasCrashLogs) return WQLocalized(@"Deletes selected Crash Logs. This cannot be undone. No backup is kept.");
    return WQLocalized(@"Select app caches or Crash Logs to see the deletion scope. No backup is kept.");
}

typedef NS_ENUM(NSInteger, WQCacheMeasurementState) {
    WQCacheMeasurementMissing,
    WQCacheMeasurementKnown,
    WQCacheMeasurementLimited,
    WQCacheMeasurementCancelled,
};

static WQCacheMeasurementState WQCacheMeasureDirectory(NSString *path, NSString *taskID,
                                                        WQScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
    unsigned long long total = 0;
    WQMeasureResult result = wq_measure_tree_resumable(path, @"clean", taskID, cancellation, &total, ^(void (^work)(void)) { wq_scan_read(work); });
    switch (result) {
        case WQMeasureResultMissing:
            return WQCacheMeasurementMissing;
        case WQMeasureResultKnown:
            if (bytes) *bytes = total;
            return WQCacheMeasurementKnown;
        case WQMeasureResultCancelled:
            return WQCacheMeasurementCancelled;
        case WQMeasureResultLimited:

            return WQCacheMeasurementLimited;
    }
    return WQCacheMeasurementLimited;
}

typedef NS_ENUM(NSInteger, WQCachePathState) {
    WQCachePathMissing,
    WQCachePathExisting,
    WQCachePathInaccessible,
};

static WQCachePathState WQCacheInspectPath(NSString *path, struct stat *st)
{
    if (wq_stat(path, st)) return WQCachePathExisting;
    struct stat direct = {0};
    if (lstat(path.fileSystemRepresentation, &direct) == 0) {
        if (st) *st = direct;
        return WQCachePathExisting;
    }
    if (errno == ENOENT || errno == ENOTDIR) return WQCachePathMissing;
    return WQCachePathInaccessible;
}

static WQCacheTargetRecord *WQCacheTargetRecordForPath(NSString *path, NSString *relativePath)
{
    WQCacheTargetRecord *record = [WQCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(path, &st);
    if (state == WQCachePathExisting) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st.st_dev;
        record.inode = st.st_ino;
        record.mode = st.st_mode & S_IFMT;
    }
    return record;
}

static void WQCacheCaptureContainerIdentity(WQCacheItem *item)
{
    struct stat st = {0};
    if (item.containerPath.length && wq_stat(item.containerPath, &st) && S_ISDIR(st.st_mode)) {
        item.containerIdentityKnown = YES;
        item.containerDevice = st.st_dev;
        item.containerInode = st.st_ino;
        item.containerMode = st.st_mode & S_IFMT;
    }
}

static BOOL WQCacheRecordIdentityMatches(WQCacheTargetRecord *record, NSString **reason)
{
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(record.path, &st);
    if (!record.existed) {
        if (state == WQCachePathMissing) return YES;
        if (reason) *reason = [NSString stringWithFormat:@"%@ appeared after the scan", record.path];
        return NO;
    }
    if (state != WQCachePathExisting || !record.identityKnown ||
        st.st_dev != record.device || st.st_ino != record.inode ||
        (st.st_mode & S_IFMT) != record.mode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", record.path];
        return NO;
    }
    return YES;
}

// One of the known crash log folders, spelled exactly, with no link on the
// way and resolving to itself. (Compared without stringByStandardizingPath:
// that drops "/private" only when it can check the path, so the comparison
// with realpath's spelling depended on access.)
static BOOL WQCacheCrashPathIsSafe(NSString *path)
{
    return [WQCacheCrashLogCandidates() containsObject:path] &&
           WQCacheSafetyHasNoSymlinkAncestry(path, YES) &&
           [WQCacheSafetyCanonicalPath(path) isEqualToString:path];
}

static BOOL WQCacheValidateItem(WQCacheItem *item, NSString **reason)
{
    if (item.limited) {
        if (reason) *reason = WQLocalized(@"the scan had limited access");
        return NO;
    }
    if (item.crashLogs) {
        if (item.targets.count != 1 || item.targetRecords.count != 1 || !item.targets.firstObject.length ||
            ![item.targetRecords.firstObject.path isEqualToString:item.targets.firstObject] ||
            !item.targetRecords.firstObject.existed || item.targetRecords.firstObject.mode != S_IFDIR) {
            if (reason) *reason = WQLocalized(@"the crash-log target is not the expected canonical directory");
            return NO;
        }
        BOOL safe = WQCacheCrashPathIsSafe(item.targets.firstObject) ||
            (wq_grant(item.targets.firstObject) && WQCacheCrashPathIsSafe(item.targets.firstObject));
        if (!safe) {
            if (reason) *reason = @"the crash-log path has unsafe or inaccessible ancestry";
            return NO;
        }
        return WQCacheRecordIdentityMatches(item.targetRecords.firstObject, reason);
    }
    if (item.targetRecords.count != 2 || item.targets.count != 2 ||
        ![item.targetRecords[0].relativePath isEqualToString:@"Library/Caches"] ||
        ![item.targetRecords[1].relativePath isEqualToString:@"tmp"] ||
        ![item.targets[0] isEqualToString:item.targetRecords[0].path] ||
        ![item.targets[1] isEqualToString:item.targetRecords[1].path]) return NO;
    if (!item.containerIdentityKnown || !WQCacheSafetyContainerPathAllowed(item.containerPath) ||
        !WQCacheSafetyHasNoSymlinkAncestry(item.containerPath, NO)) {
        if (reason) *reason = WQLocalized(@"the app container identity or ancestry is unavailable");
        return NO;
    }
    struct stat container = {0};
    if (WQCacheInspectPath(item.containerPath, &container) != WQCachePathExisting ||
        !S_ISDIR(container.st_mode) || container.st_dev != item.containerDevice ||
        container.st_ino != item.containerInode || (container.st_mode & S_IFMT) != item.containerMode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", item.name];
        return NO;
    }
    NSString *label = wq_container_label(item.containerPath);
    if (!item.bundleID.length || ![label isEqualToString:item.bundleID]) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ no longer has the scanned container identity", item.name];
        return NO;
    }
    for (WQCacheTargetRecord *record in item.targetRecords) {
        if (record.existed && (!record.identityKnown || record.mode != S_IFDIR)) {
            if (reason) *reason = @"a cache target is not a verified directory";
            return NO;
        }
        if (!WQCacheSafetyTargetMatchesContainer(record.path, item.containerPath, record.relativePath)) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ has unsafe path ancestry", record.path];
            return NO;
        }
        if (!WQCacheRecordIdentityMatches(record, reason)) return NO;
    }
    return YES;
}

// Row: selection circle, icon, name with "cache · temp" below, size in a
// fixed right-hand column so long names never push it out.
@interface WQCleanerCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView, *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel, *sizeLabel;
@end

@implementation WQCleanerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.adjustsFontForContentSizeCategory = YES;
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold]];
        _sizeLabel.adjustsFontForContentSizeCategory = YES;
        // Trailing edge in both layout directions.
        _sizeLabel.textAlignment = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:self.semanticContentAttribute]
            == UIUserInterfaceLayoutDirectionRightToLeft ? NSTextAlignmentLeft : NSTextAlignmentRight;
        for (UIView *v in @[_checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: reclaimable total, a bar for the selected share, status.
@interface WQSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel, *totalLabel, *statusLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WQSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.adjustsFontForContentSizeCategory = YES;
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle]
                            scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.adjustsFontForContentSizeCategory = YES;
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _spinner]];
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[captionRow, _totalLabel, _bar, _statusLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

@implementation WQCacheCleanerViewController {
    WQScanTask *_scanTask;
    NSDictionary *_shownScanResult;
    BOOL _resumeScan;

    NSArray<WQCacheItem *> *_items;
    NSArray<WQCacheItem *> *_visibleItems;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning, _scanLimited, _cleanRequiresRescan;
    // A refresh asked for while cleaning runs once the cleaning has ended:
    // a scan must not replace the list (or the Stop button) under it.
    BOOL _refreshAfterClean, _rescanAfterClean;
    WQScanCancellation *_scanCancellation;
    WQScanCancellation *_cleanCancellation;
    NSUInteger _scanGeneration;
    float _scanProgress;   // 0…1 while scanning
    unsigned long long _scanBytes;   // found so far while scanning
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }


- (NSDictionary *)snapshotRows:(NSArray<WQCacheItem *> *)rows note:(NSString *)note
{
    NSMutableArray *saved = [NSMutableArray new];
    for (WQCacheItem *item in rows) {
        NSMutableDictionary *encoded = [WQScanEncode(item, @[@"name", @"bundleID", @"containerPath", @"cacheBytes", @"tempBytes", @"cacheKnown", @"tempKnown", @"limited", @"crashLogs", @"containerIdentityKnown", @"containerDevice", @"containerInode", @"containerMode"]) mutableCopy];
        NSMutableArray *records = [NSMutableArray new];
        for (WQCacheTargetRecord *record in item.targetRecords)
            [records addObject:WQScanEncode(record, @[@"path", @"relativePath", @"existed", @"identityKnown", @"device", @"inode", @"mode"])];
        encoded[@"records"] = records;
        [saved addObject:encoded];
    }
    return @{@"rows": saved, @"note": note ?: @""};
}

- (void)scanTaskChanged:(NSNotification *__unused)notification
{
    if (_cleaning) return;
    NSDictionary *result = _scanTask.result;
    if (result && result != _shownScanResult) {
        NSMutableArray *rows = [NSMutableArray new];
        for (id encoded in [result[@"rows"] isKindOfClass:NSArray.class] ? result[@"rows"] : @[]) {
            if (![encoded isKindOfClass:NSDictionary.class]) continue;
            WQCacheItem *item = [WQCacheItem new];
            WQScanDecode(item, encoded, @[@"name", @"bundleID", @"containerPath"], @[@"cacheBytes", @"tempBytes", @"cacheKnown", @"tempKnown", @"limited", @"crashLogs", @"containerIdentityKnown", @"containerDevice", @"containerInode", @"containerMode"]);
            NSMutableArray *records = [NSMutableArray new], *targets = [NSMutableArray new];
            for (id entry in [encoded[@"records"] isKindOfClass:NSArray.class] ? encoded[@"records"] : @[]) {
                if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"path"] isKindOfClass:NSString.class]) continue;
                WQCacheTargetRecord *record = [WQCacheTargetRecord new];
                WQScanDecode(record, entry, @[@"path", @"relativePath"], @[@"existed", @"identityKnown", @"device", @"inode", @"mode"]);
                [records addObject:record]; [targets addObject:record.path];
            }
            item.targetRecords = records;
            item.targets = targets;
            item.selected = NO;
            [rows addObject:item];
        }
        _items = rows;
        _shownScanResult = result;
        [self rebuildVisibleItems];
    }
    _scanning = _scanTask.running;
    NSString *note = [result[@"note"] isKindOfClass:NSString.class] ? result[@"note"] : nil;
    if (!note.length) note = nil;
    _status = _scanning ? (_scanTask.paused ? WQLocalized(@"Scan paused") :
        (_scanTask.status.length ? WQLocalized(_scanTask.status) : WQLocalized(@"Scan queued; previous results kept"))) :
        (_scanTask.status.length ? WQLocalized(_scanTask.status) : note);
    if (_scanTask.finishedAt) {
        NSString *date = [NSDateFormatter localizedStringFromDate:_scanTask.finishedAt dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
        self.navigationItem.prompt = WQLocalizedFormat(@"Last scanned %@ · Pull to refresh", date);
    }
    if (_scanTask.persistenceFailed) self.navigationItem.prompt = WQLocalized(@"Could not save scan state. Keep charony open.");
    if (!_scanning) [self.refreshControl endRefreshing];
    [self.tableView reloadData];
    [self updateButtons];
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
    self.title = WQLocalizedNullable(@"Caches");
    self.tabBarItem.title = @"Caches";
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = WQLocalizedNullable(@"Search apps");
    _contextSearchController = search;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    _scanTask = [WQScanTask taskNamed:@"clean"];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scanTaskChanged:) name:WQScanTaskChangedNotification object:_scanTask];
    [self scanTaskChanged:nil];
    if (!_scanTask.running && !_scanTask.userPaused && (!_scanTask.result || _scanTask.interrupted)) {
        _resumeScan = _scanTask.interrupted;
        [self scan];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self scanTaskChanged:nil];

}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    wq_offer_access_recovery(self);
}


- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // Read-only scanning survives navigation; destructive cleaning still stops.
    if (_cleaning) [_cleanCancellation cancel];
}

- (NSArray<WQCacheItem *> *)visibleItems
{
    return _visibleItems ?: @[];
}

- (void)rebuildVisibleItems
{
    if (!_query.length) {
        _visibleItems = _items;
        return;
    }
    _visibleItems = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
        return [it.name localizedCaseInsensitiveContainsString:self->_query] ||
               (it.bundleID && [it.bundleID localizedCaseInsensitiveContainsString:self->_query]);
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleItems];
    [self.tableView reloadData];
    [self updateButtons];
}

// While scanning, the bar shows how far the scan is; otherwise how much of
// the reclaimable space is selected.
- (void)setStatus:(NSString *)status progress:(float)progress
{
    _scanProgress = MAX(_scanProgress, MIN(1.0f, progress));
    [self setStatus:status];
}

- (void)setStatus:(NSString *)status
{
    if (_scanning && !_cleaning) [_scanTask progress:status generation:_scanTask.generation];
    _status = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateButtons
{
    // Stop stays while cleaning, whatever else happens.
    if (_cleaning) {
        UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Stop") style:UIBarButtonItemStylePlain
                                                                 target:self action:@selector(stopClean)];
        self.navigationItem.rightBarButtonItems = @[stop];
        return;
    }
    if (_scanning || _scanTask.userPaused) {
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithTitle:WQLocalized(_scanning ? @"Pause Scan" : @"Resume Scan")
            style:UIBarButtonItemStylePlain target:self action:@selector(toggleScan)]];
        return;
    }
    NSUInteger n = 0;
    for (WQCacheItem *it in _items) if (it.selected) n++;
    UIBarButtonItem *clean = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Clean") style:wq_primary_button_style()
                                                             target:self action:@selector(confirmClean)];
    clean.enabled = n > 0 && !_cleanRequiresRescan;
    self.navigationItem.rightBarButtonItems = @[clean];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    if (_cleaning) {
        _refreshAfterClean = YES;
        [self.refreshControl endRefreshing];
        return;
    }
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self scan];
}

// The one refresh after cleaning: the pull to refresh that came in during
// it, a rescan asked for meanwhile, or the rescan the result needs. YES when
// a scan was started.
- (BOOL)rescanAfterClean:(BOOL)needed
{
    BOOL user = _refreshAfterClean, queued = _rescanAfterClean;
    _refreshAfterClean = NO;
    _rescanAfterClean = NO;
    if (!needed && !user && !queued) return NO;
    if (user) {
        wq_enumerate_invalidate();
        wq_display_names_reset_miss();
    }
    [self scan];
    return YES;
}

- (void)scan
{
    if (_cleaning) {
        _rescanAfterClean = YES;
        [self.refreshControl endRefreshing];
        return;
    }
    WQScanCancellation *cancellation = [WQScanCancellation new];
    NSUInteger taskGeneration = [_scanTask beginFresh:!_resumeScan cancel:^{ [cancellation cancel]; }];
    _resumeScan = NO;
    if (!taskGeneration) return;
    NSString *taskID = _scanTask.identifier;
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    _scanProgress = 0;
    _scanBytes = 0;
    _scanLimited = NO;
    _cleanRequiresRescan = NO;
    _result = nil;
    [self updateButtons];
    [self setStatus:WQLocalizedNullable(@"Scan queued; previous results kept")];
    dispatch_async(wq_scan_queue(), ^{
        if (cancellation.isCancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_scanTask progress:WQLocalized(@"Finding apps…") generation:taskGeneration];
        });
        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        BOOL scanLimited = NO;
        NSUInteger failedEnumerations = 0;
        NSUInteger limitedContainers = 0;
        NSUInteger limitedMeasurements = 0;
        NSUInteger missingIdentities = 0;
        NSUInteger checkedContainers = 0;
        __block unsigned long long foundBytes = 0;

        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            if (cancellation.isCancelled) return;
            float share = 1.0f / (float)roots.count, base = (float)[roots indexOfObject:root] * share;
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"apps" : @"extensions";

            NSArray *containers = wq_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    [self setStatus:WQLocalizedFormat(@"Finding %@… %lld%%", kind, (long long)(total ? done * 100 / total : 0))
                           progress:base + share * 0.1f * (total ? (float)done / (float)total : 0)];
                });
            });
            if (!containers) {
                if (cancellation.isCancelled) return;
                scanLimited = YES;
                failedEnumerations++;

                continue;
            }
            if (!cancellation.isCancelled && !wq_display_names_loaded()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                [self setStatus:WQLocalizedNullable(@"Reading app names…")];
            });
            wq_load_display_names();
        }
            if (!containers.count) [emptyRoots addObject:kind];
            NSUInteger idx = 0;
            checkedContainers += containers.count;
            for (NSString *c in containers) {
                if (cancellation.isCancelled) return;
                idx++;
                if (idx % 10 == 0 || idx == containers.count) {
                    unsigned long long soFar = foundBytes;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                        self->_scanBytes = soFar;
                        [self setStatus:WQLocalizedFormat(@"Measuring %@ %lu of %lu…", kind,
                                         (unsigned long)idx, (unsigned long)containers.count)
                               progress:base + share * (0.1f + 0.9f * (float)idx / (float)containers.count)];
                    });
                }
                BOOL safeContainer = WQCacheSafetyHasNoSymlinkAncestry(c, NO);
                if ([c.stringByResolvingSymlinksInPath isEqualToString:NSHomeDirectory().stringByResolvingSymlinksInPath]) continue;
                BOOL granted = safeContainer && wq_grant(c);  // one token for the whole container
                NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                unsigned long long cacheBytes = 0, tempBytes = 0;
                BOOL safeCaches = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(caches, c, @"Library/Caches");
                BOOL safeTmp = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(tmp, c, @"tmp");
                WQCacheMeasurementState cacheState = granted && safeCaches
                    ? WQCacheMeasureDirectory(caches, taskID, cancellation, &cacheBytes)
                    : WQCacheMeasurementLimited;
                if (cacheState == WQCacheMeasurementCancelled) return;
                WQCacheMeasurementState tempState = granted && safeTmp
                    ? WQCacheMeasureDirectory(tmp, taskID, cancellation, &tempBytes)
                    : WQCacheMeasurementLimited;
                if (tempState == WQCacheMeasurementCancelled) return;
                if (!granted || !safeContainer) {
                    scanLimited = YES;
                    limitedContainers++;

                }
                if (cacheState == WQCacheMeasurementLimited || tempState == WQCacheMeasurementLimited) {
                    scanLimited = YES;
                    limitedMeasurements++;
                }
                BOOL cacheKnown = cacheState != WQCacheMeasurementLimited;
                BOOL tempKnown = tempState != WQCacheMeasurementLimited;
                foundBytes += cacheBytes + tempBytes;
                if (cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024) continue;
                WQCacheItem *item = [WQCacheItem new];
                NSString *bid = granted ? wq_container_label(c) : nil;
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
                item.targets = @[caches, tmp];
                item.cacheBytes = cacheBytes;
                item.tempBytes = tempBytes;
                item.cacheKnown = cacheKnown;
                item.tempKnown = tempKnown;
                item.limited = !cacheKnown || !tempKnown;
                item.containerPath = c;
                item.targetRecords = @[
                    WQCacheTargetRecordForPath(caches, @"Library/Caches"),
                    WQCacheTargetRecordForPath(tmp, @"tmp"),
                ];
                WQCacheCaptureContainerIdentity(item);
                if (!bid.length || !item.containerIdentityKnown) {
                    item.limited = YES;
                    scanLimited = YES;
                    missingIdentities++;
                }
                item.selected = NO;
                [items addObject:item];
            }
        }
        if (cancellation.isCancelled) return;
        unsigned long long crash = 0;
        // The first crash log folder that exists. worse_query reaches these on
        // iOS 27; where none can be reached (iOS 26) or none exists, the
        // section is left out instead of reported as limited.
        NSString *crashPath = nil;
        for (NSString *candidate in WQCacheCrashLogCandidates()) {
            struct stat cst;
            if (lstat(candidate.fileSystemRepresentation, &cst) != 0 && (errno == EPERM || errno == EACCES)) wq_grant(candidate);
            if (lstat(candidate.fileSystemRepresentation, &cst) == 0) { crashPath = candidate; break; }
        }
        BOOL crashReachable = crashPath != nil;

        BOOL safeCrashPath = crashReachable && WQCacheCrashPathIsSafe(crashPath);
        // The path check reads every ancestor, which can need the folder's
        // sandbox token first.
        if (crashReachable && !safeCrashPath && wq_grant(crashPath))
            safeCrashPath = WQCacheCrashPathIsSafe(crashPath);

        // The folder must also open for reading. On iOS 27.0.1 worse_query
        // doesn't reach mobile's Library/Logs (EPERM even with a token): then
        // WQ Files can neither measure nor clean it, and the section is left
        // out instead of showing as "can't be fully measured" on every scan.
        if (safeCrashPath) {
            int fd = open(crashPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            int err = fd < 0 ? errno : 0;
            // errno is kept from the open itself: a failed grant leaves its
            // own (it logged ENOENT for a folder that exists).
            if (fd < 0 && (err == EPERM || err == EACCES) && wq_grant(crashPath)) {
                fd = open(crashPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            }
            if (fd >= 0) close(fd);
            else {

                crashReachable = NO;
            }
        }
        WQCacheMeasurementState crashState = !crashReachable ? WQCacheMeasurementMissing
            : safeCrashPath ? WQCacheMeasureDirectory(crashPath, taskID, cancellation, &crash)
                            : WQCacheMeasurementLimited;
        if (crashState == WQCacheMeasurementCancelled) return;
        BOOL crashLimited = crashState == WQCacheMeasurementLimited;
        if (crashLimited) scanLimited = YES;
        if (crashState == WQCacheMeasurementLimited || crash > 0) {
            WQCacheItem *logs = [WQCacheItem new];
            logs.name = WQLocalized(@"Crash Logs");
            logs.targets = @[crashPath];
            logs.cacheBytes = crash;
            logs.cacheKnown = crashState != WQCacheMeasurementLimited;
            logs.crashLogs = YES;
            logs.limited = crashState == WQCacheMeasurementLimited;
            logs.targetRecords = @[WQCacheTargetRecordForPath(crashPath, nil)];
            logs.selected = NO;
            [items addObject:logs];
        }
        [items sortUsingComparator:^NSComparisonResult(WQCacheItem *a, WQCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (failedEnumerations) {
            [notes addObject:WQLocalizedFormat(failedEnumerations == 1
                ? @"%lu container enumeration failed" : @"%lu container enumerations failed",
                (unsigned long)failedEnumerations)];
        }
        if (limitedContainers) {
            [notes addObject:WQLocalizedFormat(limitedContainers == 1
                ? @"%lu container had limited access" : @"%lu containers had limited access",
                (unsigned long)limitedContainers)];
        }
        if (limitedMeasurements) {
            [notes addObject:WQLocalizedFormat(limitedMeasurements == 1
                ? @"%lu cache tree measurement was limited" : @"%lu cache tree measurements were limited",
                (unsigned long)limitedMeasurements)];
        }
        if (missingIdentities) {
            [notes addObject:WQLocalizedFormat(missingIdentities == 1
                ? @"%lu container had no identifier or identity" : @"%lu containers had no identifier or identity",
                (unsigned long)missingIdentities)];
        }
        NSString *note = nil;
        // No containers at all matters more than one limited measurement.
        if (scanLimited && emptyRoots.count) {
            NSString *empty = WQLocalizedFormat(emptyRoots.count == 1 ? @"No %@ container found." : @"No %@ containers found.",
                                                [emptyRoots componentsJoinedByString:@" or "]);
            [notes insertObject:[empty stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".。"]] atIndex:0];
        }
        // Only app and extension problems make the scan incomplete; Crash
        // Logs that can't be measured get their own sentence. A list without
        // app rows says how many were checked (everything was already clean
        // looked like a broken scan).
        NSUInteger appRows = 0;
        for (WQCacheItem *item in items) if (!item.crashLogs) appRows++;
        NSMutableArray<NSString *> *sentences = [NSMutableArray new];
        if (!appRows && checkedContainers && !failedEnumerations && !limitedContainers)
            [sentences addObject:WQLocalizedFormat(@"%lu apps and extensions checked: none has 64 KB or more in its caches and temporary files.",
                                                   (unsigned long)checkedContainers)];
        if (notes.count) {
            [notes addObject:WQLocalized(@"limited rows are excluded; the remaining rows can still be cleaned")];
            [sentences addObject:WQLocalizedFormat(@"Scan incomplete: %@. Pull to refresh to retry.", [notes componentsJoinedByString:@"; "])];
        } else if (emptyRoots.count) {
            [sentences addObject:WQLocalizedFormat(emptyRoots.count == 1 ? @"No %@ container found." : @"No %@ containers found.",
                                                   [emptyRoots componentsJoinedByString:@" or "])];
        }
        if (crashLimited) [sentences addObject:WQLocalized(@"Crash Logs can't be fully measured on this device.")];
        if (sentences.count) note = [sentences componentsJoinedByString:@" "];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            NSMutableDictionary *snapshot = [[self snapshotRows:items note:note] mutableCopy];
            snapshot[@"complete"] = @(failedEnumerations == 0);
            // Shown synchronously through the task's change notification.
            [self->_scanTask finish:snapshot generation:taskGeneration];
            wq_offer_access_recovery(self);

        });
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)self.visibleItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSUInteger shown = self.visibleItems.count;
    NSUInteger appCount = 0;
    for (WQCacheItem *item in _items) if (!item.crashLogs) appCount++;
    if (!appCount) return WQLocalized(@"Crash Logs");
    return _query.length ? WQLocalizedFormat(@"%lu of %lu", (unsigned long)shown, (unsigned long)_items.count)
                         : WQLocalizedFormat(@"%lu apps and extensions", (unsigned long)appCount);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"selected == YES"]];
    return [WQCacheFooterScope(selected) stringByAppendingString:WQLocalized(@" Close running apps first.")];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        WQSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"]
            ?: [[WQSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"summary"];
        unsigned long long total = 0, selected = 0;
        NSUInteger n = 0;
        BOOL complete = YES;
        for (WQCacheItem *it in _items) {
            total += it.bytes;
            if (!it.cacheKnown || (!it.crashLogs && !it.tempKnown)) complete = NO;
            if (it.selected) { selected += it.bytes; n++; }
        }
        BOOL busy = _scanning || _cleaning;
        cell.captionLabel.text = busy ? (_cleaning ? WQLocalized(@"Cleaning") : WQLocalized(@"Scanning")) : WQLocalized(complete ? @"Reclaimable" : @"Reclaimable (incomplete)");
        if (busy) [cell.spinner startAnimating]; else [cell.spinner stopAnimating];
        // While the first scan runs, the total found so far counts up.
        cell.totalLabel.text = wq_size_text((_scanning && !_items.count) ? _scanBytes : total);
        cell.bar.progress = _scanning ? _scanProgress : total ? (float)((double)selected / (double)total) : 0;
        cell.bar.hidden = NO;
        cell.statusLabel.text = _status ?: _result
            ?: WQLocalizedFormat(n == 1 ? @"%@ selected in %lu item" : @"%@ selected in %lu items",
                                 wq_size_text(selected), (unsigned long)n);
        return cell;
    }
    WQCleanerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[WQCleanerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.nameLabel.text = item.name;
    if (item.crashLogs) {
        cell.detailLabel.text = item.cacheKnown ? WQVerbatim([NSString stringWithFormat:@"%@ · CrashReporter", WQLocalized(@"Crash Logs")]) : WQLocalized(@"Crash Logs · access limited");
    } else {
        NSString *cache = item.cacheKnown ? wq_size_text(item.cacheBytes) : WQLocalized(@"unknown");
        NSString *temp = item.tempKnown ? wq_size_text(item.tempBytes) : WQLocalized(@"unknown");
        cell.detailLabel.text = WQLocalizedFormat(@"cache %@ · temp %@%@", cache, temp,
                                 item.limited ? WQLocalized(@" · access limited") : @"");
    }
    cell.sizeLabel.text = wq_size_text(item.bytes);
    cell.iconView.image = wq_app_icon(item.bundleID)
        ?: [UIImage systemImageNamed:item.bundleID ? @"app.dashed" : @"exclamationmark.triangle"];
    cell.iconView.tintColor = UIColor.secondaryLabelColor;
    cell.checkView.image = [UIImage systemImageNamed:item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    // The selection circle alone does not expose state to VoiceOver. Group
    // the row's content and publish its current manual-selection state.
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@", item.name, cell.detailLabel.text, cell.sizeLabel.text];
    cell.accessibilityValue = item.limited ? @"Access limited" : item.selected ? @"Selected" : @"Not selected";
    cell.accessibilityTraits = UIAccessibilityTraitButton | (item.selected ? UIAccessibilityTraitSelected : 0);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || _scanning || _cleaning) return;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    if (item.limited) {
        wq_alert(self, @"Not cleanable",
                 @"This row has incomplete access or identity information. Scan again while the app is closed, pull to refresh to try again.");
        return;
    }
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath, [NSIndexPath indexPathForRow:0 inSection:0]]
                     withRowAnimation:UITableViewRowAnimationNone];
    [self updateButtons];
}

- (void)stopClean
{
    [_cleanCancellation cancel];
    [self setStatus:WQLocalizedNullable(@"Stopping after the current item…")];
}

- (void)confirmClean
{
    if (_scanning || _cleaning || _scanTask.userPaused || _cleanRequiresRescan) return;
    NSMutableArray<WQCacheItem *> *selected = [NSMutableArray new];
    unsigned long long sel = 0;
    for (WQCacheItem *item in _items) {
        if (!item.selected) continue;
        [selected addObject:item];
        sel += item.bytes;
    }
    if (!selected.count) return;
    NSArray<WQCacheItem *> *confirmed = [selected copy];
    NSUInteger generation = _scanGeneration;
    NSString *msg = WQLocalizedFormat(@"%@, about %@? This cannot be undone. Close the selected apps first; you can stop between items.", WQCacheConfirmationScope(confirmed), wq_size_text(sel));
    UIAlertController *alert = wq_alert_controller(@"Clean caches?", msg, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Clean", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self dismissViewControllerAnimated:YES completion:^{ [self cleanItems:confirmed generation:generation]; }];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)cleanItems:(NSArray<WQCacheItem *> *)selected generation:(NSUInteger)generation
{
    if (_scanning || _cleaning || _scanTask.userPaused || _cleanRequiresRescan) return;
    if (!selected.count) return;
    if (generation != _scanGeneration) {
        wq_alert(self, @"Selection changed", @"The scan changed after confirmation. Select the current targets and confirm again.");
        return;
    }
    WQScanCancellation *cancellation = [WQScanCancellation new];
    if (!wq_begin_mutation(self)) return;
    _cleanCancellation = cancellation;
    _cleaning = YES;
    [self updateButtons];
    [self setStatus:WQLocalizedNullable(@"Cleaning…")];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        BOOL allOk = YES;
        BOOL cancelled = NO;
        NSString *validationFailure = nil;
        for (WQCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            NSString *reason = nil;
            if (!WQCacheValidateItem(item, &reason)) {
                allOk = NO;
                validationFailure = validationFailure ?: [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];

            }
        }
        if (validationFailure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_end_mutation();
                self->_cleaning = NO;
                self->_cleanCancellation = nil;
                self->_scanLimited = YES;
                self->_cleanRequiresRescan = YES;
                self->_status = nil;
                BOOL rescanned = [self rescanAfterClean:NO];
                self->_result = WQLocalizedFormat(@"Clean cancelled: %@. Scan again before retrying.", validationFailure);
                if (rescanned) return;
                [self.tableView reloadData];
                [self updateButtons];
            });
            return;
        }
        NSUInteger i = 0;
        for (WQCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            i++;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setStatus:WQLocalizedFormat(@"Cleaning %lu of %lu: %@", (unsigned long)i, (unsigned long)selected.count, item.name)];
            });
            for (WQCacheTargetRecord *record in item.targetRecords) {
                if (cancellation.isCancelled) { cancelled = YES; break; }
                NSString *reason = nil;
                if (!WQCacheValidateItem(item, &reason)) {
                    allOk = NO;
                    validationFailure = [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];

                    break;
                }
                if (!wq_purge_contents_validated(record.path, &freed, cancellation, ^BOOL { return WQCacheValidateItem(item, NULL); })) {
                    if (cancellation.isCancelled) { cancelled = YES; break; }
                    allOk = NO;
                    validationFailure = [NSString stringWithFormat:@"%@ could not be fully cleaned because access or data changed", item.name];
                    break;
                }
            }
            if (validationFailure || cancelled) break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            wq_end_mutation();
            self->_cleaning = NO;
            self->_cleanCancellation = nil;
            if (cancelled) {
                self->_status = nil;
                [self rescanAfterClean:YES];
                self->_result = WQLocalizedFormat(@"Stopped. Freed %@.%@", wq_size_text(freed),
                                 allOk ? @"" : WQLocalized(@" Some items could not be removed (access denied or data changed)."));
                return;
            }
            if (validationFailure) {
                self->_scanLimited = YES;
                self->_cleanRequiresRescan = YES;
                self->_status = nil;
                BOOL rescanned = [self rescanAfterClean:NO];
                self->_result = WQLocalizedFormat(@"Clean stopped: %@. Scan again before retrying.", validationFailure);
                if (rescanned) return;
                [self.tableView reloadData];
                [self updateButtons];
            } else {
                self->_status = nil;
                [self rescanAfterClean:YES];
                self->_result = WQLocalizedFormat(@"Freed %@.%@", wq_size_text(freed),
                                 allOk ? @"" : WQLocalized(@" Some items could not be removed (access denied or data changed)."));
            }
        });
    });
}

@end
