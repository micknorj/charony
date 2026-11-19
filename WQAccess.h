//
//  WQAccess.h
//  WQ Files
//
//  File access outside the sandbox through the worse_query technique by
//  Taj C (forcequit), https://github.com/forcequitOS/worse_query,
//  GPL-3.0-or-later. This reimplementation is GPL-3.0-or-later as well.
//

#import <Foundation/Foundation.h>
#import "WQLaunchServices.h"
#import "WQDiscoveryState.h"
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// Picks the app group the signer actually gave us. Nil when there is none.
NSString *_Nullable wq_app_group(void);

// Asks for a sandbox extension covering path (once per path). Returns YES
// when one is held for it.
BOOL wq_grant(NSString *path);
// Repairs the token cache (App Group Library/Caches) when another app sharing
// the App Group, or an interrupted run, left it in a state token requests
// refuse. Renames preserved state and reports an ephemeral error.
BOOL wq_reset_access_cache(NSString *_Nullable *_Nullable errorText);

// Directory listing; asks for access when the plain call is refused. On
// failure errno holds the reason (EACCES/EPERM for a refusal).
NSArray<NSString *> *_Nullable wq_list(NSString *dir, NSString *_Nullable *_Nullable errorText);

// Reads a whole file (up to maxBytes; 0 = no limit).
NSData *_Nullable wq_read(NSString *path, NSUInteger maxBytes, NSString *_Nullable *_Nullable errorText);

// When Unix permissions (not the sandbox) keep this app out of `path`: an
// explanation for the user; nil if the owner and mode allow it.
NSString *_Nullable wq_permission_hint(NSString *path, BOOL forWriting);

// Whether the owner, group and mode of `st` let this app (uid, gid and its
// supplementary groups) read the item; for folders, read and search. The
// folder lists use it to dim what can't be opened (issue #57).
BOOL wq_stat_readable(const struct stat *st);

// lstat with access retry. Returns NO if the item does not exist.
BOOL wq_stat(NSString *path, struct stat *st);

// Thread-safe cancellation for expensive filesystem scans.
@interface WQScanCancellation : NSObject
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Discovers direct children of dir by brute-forcing inode numbers with
// fsgetpath (not sandbox-gated), the way KAMUI/bad_query_list do. Needs no
// token on dir. maxInode bounds the scan (0 = up to the newest id on the
// volume); progress is called off the main thread, from several threads.
// Returns absolute child paths, sorted, or nil on failure/cancellation, including
// when the dynamic bound cannot be discovered. No implicit fixed-range fallback.
// App, extension and daemon roots share discovery work within the process.
// Incomplete inode scans retain a contiguous-frontier recovery checkpoint.
// Completed discovery is held in memory. Manual refresh invalidates it.
void wq_enumerate_invalidate(void);
// NO on iOS 26: there worse_query can't reach System Data, the system groups
// or the App Groups parent folder (only the individual containers).
BOOL wq_system_areas_reachable(void);
NSArray<NSString *> *_Nullable wq_enumerate(NSString *dir, int64_t maxInode,
                                            WQScanCancellation *_Nullable cancellation,
                                            void (^_Nullable progress)(int64_t done, int64_t total, NSUInteger found));

typedef NS_ENUM(NSInteger, WQMeasureResult) {
    WQMeasureResultMissing,
    WQMeasureResultKnown,
    WQMeasureResultLimited,
    WQMeasureResultCancelled,
};

// Total byte size of regular files below dir. A missing directory is Missing
// (size 0); an unreadable subtree makes the result Limited instead of silently
// undercounting. Grants access when the root cannot be listed.
WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *_Nullable cancellation,
                                unsigned long long *_Nullable bytes);

// Deletes every item *inside* dir (dir itself stays). No backup — for caches.
// Adds freed bytes to *freed. A missing dir counts as done; NO if dir cannot
// be read or listed, ancestry contains links (except canonical /var), the target
// changes, or some items could not be removed. Child links are not followed.
// MCM container identifier (bundle or group id) of a container folder.
NSString *_Nullable wq_container_label(NSString *dir);
// Extra source for wq_container_label, tried after the identifier attribute and
// the container-manager table: path (/private/var/...) -> identifier or nil.
// iOS 26: where a full scan takes far too long, the App Data and Extensions
// lists come from this provider (the LaunchServices database). storeHint is a
// database path the scan found, or nil for the remembered one.
// Full scans (every file id; minutes on a well-used device) only start after
// `confirm` returns YES; it's called on a background thread with what is being
// listed, the number of ids and a rough duration. `progress` reports a running
// full scan and its end (finished = YES). Without these hooks no full scan runs.
void wq_set_full_scan_ui(BOOL (*_Nullable confirm)(NSString *what, int64_t ids, double seconds),
                         void (*_Nullable progress)(int64_t done, int64_t total, BOOL finished));
// Stops the running full scan (the scan window's Stop button).
void wq_full_scan_stop(void);
// Whether the last listing failed because a full scan wasn't confirmed.
BOOL wq_full_scan_was_declined(void);
void wq_set_container_list_provider(NSArray<NSString *> *_Nullable (*_Nullable provider)(NSString *_Nullable storeHint));
void wq_set_container_label_resolver(NSString *_Nullable (*_Nullable resolver)(NSString *path));
// App Group folder -> group id, consulted after the metadata plist.
void wq_set_group_label_resolver(NSString *_Nullable (*_Nullable resolver)(NSString *path));

// Durable directory-by-directory measurement for user-started scan tasks.
// scope is stable (Apps/Clean); taskID changes only for an explicit fresh scan.
// performIO serializes one directory with foreground mutations, yielding between
// directories. Restored byte counts describe measurements taken over time.
WQMeasureResult wq_measure_tree_resumable(NSString *dir, NSString *scope, NSString *taskID,
    WQScanCancellation *_Nullable cancellation, unsigned long long *_Nullable bytes,
    void (^performIO)(void (^work)(void)));

// Cooperative suspension at scan boundaries; never waits on the mutation queue.
void wq_scan_set_paused(BOOL paused);
BOOL wq_scan_wait(WQScanCancellation *_Nullable cancellation);

BOOL wq_access_cache_needs_recovery(void);
BOOL wq_purge_contents_validated(NSString *dir, unsigned long long *freed, WQScanCancellation *_Nullable cancellation, BOOL (^_Nullable validate)(void));

NSString *_Nullable wq_access_capability_failure(void);
NS_ASSUME_NONNULL_END
