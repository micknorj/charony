//
//  WQAccess.m
//  WQ Files
//
//  Sandbox extension technique: worse_query by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//
//  Notes from testing on 27.0.1:
//  - An extension covers the folder it was issued for. A container root
//    extension was not enough to open a file two levels down for writing, so
//    writes always ask for the file's own folder first.
//  - /var/containers/Shared/SystemGroup itself gets no token; its children do.
//

#import "WQAccess.h"
#import "WQScanJournal.h"
#import "WQAccessSafety.h"
#import "WQLocalization.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/xattr.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <xpc/xpc.h>

static _Atomic BOOL gAccessRecoveryNeeded;

@implementation WQScanCancellation {
    _Atomic BOOL _cancelled;
}

- (BOOL)isCancelled
{
    return atomic_load_explicit(&_cancelled, memory_order_relaxed);
}

- (void)cancel
{
    atomic_store_explicit(&_cancelled, YES, memory_order_relaxed);
}

@end

static NSCondition *wq_scan_condition(void)
{
    static NSCondition *condition;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ condition = [NSCondition new]; });
    return condition;
}
static BOOL gScansPaused;
void wq_scan_set_paused(BOOL paused)
{
    NSCondition *condition = wq_scan_condition();
    [condition lock];
    gScansPaused = paused;
    [condition broadcast];
    [condition unlock];
}
BOOL wq_scan_wait(WQScanCancellation *cancellation)
{
    NSCondition *condition = wq_scan_condition();
    [condition lock];
    while (gScansPaused && !cancellation.isCancelled) [condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    [condition unlock];
    return !cancellation.isCancelled;
}

static NSString *wq_errno(int err) { return [NSString stringWithFormat:@"%s (errno %d)", strerror(err), err]; }

#pragma mark - App group

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static int64_t wq_query_token_ex(NSString *group, BOOL altFlags, BOOL consumeIt, NSString **covered);

// The App Group folder a token is issued for, read from an unused token
// (its last field is ".../AppGroup/<UUID>/Library/Caches"). Under
// LiveContainer this is the only reliable answer: the container manager
// gives no path and LiveContainer's stand-in can be anywhere (#65).
static NSString *wq_token_group_root(NSString *group)
{
    for (int alt = 0; alt < 2; alt++) {
        NSString *covered = nil;
        (void)wq_query_token_ex(group, alt == 1, NO, &covered);
        NSString *root = WQGroupRootFromTokenPath(covered);
        if (root) return root;
    }
    return nil;
}

// The group container's path as the container manager knows it: the one
// worse_query's token is issued for. nil when it can't be asked.
static NSString *wq_cm_group_path(NSString *group)
{
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return nil;
    void *(*create)(void) = (void *(*)(void))dlsym(mgr, "container_query_create");
    void (*setClass)(void *, uint64_t) = (void (*)(void *, uint64_t))dlsym(mgr, "container_query_set_class");
    void (*setGroups)(void *, xpc_object_t) = (void (*)(void *, xpc_object_t))dlsym(mgr, "container_query_set_group_identifiers");
    void (*iterate)(void *, bool (^)(void *)) = (void (*)(void *, bool (^)(void *)))dlsym(mgr, "container_query_iterate_results_sync");
    void (*freeQuery)(void *) = (void (*)(void *))dlsym(mgr, "container_query_free");
    const char *(*getPath)(void *) = (const char *(*)(void *))dlsym(mgr, "container_object_get_path");
    __block NSString *found = nil;
    if (create && setClass && setGroups && iterate && freeQuery && getPath) {
        void *query = create();
        if (query) {
            setClass(query, 7);   // app group container
            setGroups(query, xpc_string_create(group.UTF8String));
            iterate(query, ^bool(void *object) {
                const char *path = object ? getPath(object) : NULL;
                if (path && path[0]) { found = @(path); return false; }
                return true;
            });
            freeQuery(query);
        }
    }
    dlclose(mgr);
    return found.length ? found : nil;
}

static BOOL wq_is_dir(NSString *path)
{
    struct stat st;
    return path.length && lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

static NSString *wq_group_root(NSString *group)
{
    if (!group) return nil;
    static NSMutableDictionary<NSString *, NSString *> *roots;
    @synchronized (NSFileManager.class) {
        if (roots[group]) return roots[group];
    }
    NSString *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group].path;
    NSString *root = nil;
    // 1. The folder access tokens are really issued for decides (#65).
    //    Under LiveContainer, NSFileManager's answer is a stand-in for every
    //    group except the one LiveContainer itself uses.
    NSString *tokenRoot = wq_token_group_root(group);
    if (tokenRoot && wq_is_dir(tokenRoot)) {
        root = tokenRoot;

    }
    // 2. Without a usable token answer: the container manager's path.
    if (!root) {
        NSString *managed = WQCanonicalVarPath(wq_cm_group_path(group) ?: @"");
        if (wq_is_dir(managed)) {
            root = managed;

        }
    }
    // 3. Last resort: NSFileManager's answer, mapped out of a LiveContainer
    //    stand-in when it has that shape.
    if (!root) {
        root = WQGroupRootForPath(path);
        if (root && ![root isEqualToString:path] && !wq_is_dir(root)) root = path;
    }
    if (!root) return nil;
    @synchronized (NSFileManager.class) {
        if (!roots) roots = [NSMutableDictionary new];
        roots[group] = root;
    }
    return root;
}

NSString *wq_app_group(void)
{
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *groups = nil;
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task) {
            CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value) groups = (__bridge_transfer NSArray *)value;
            CFRelease(task);
        }
        // Prefer a group whose NSFileManager folder is the one tokens are
        // issued for: under LiveContainer that is the group LiveContainer
        // itself uses (it prefers SideStore's, while the entitlement list may
        // start with AltStore's), elsewhere simply the first group (#65).
        NSMutableArray *ordered = [NSMutableArray new];
        for (id candidate in groups) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSString *fm = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate].path;
            NSString *token = wq_token_group_root(candidate);
            BOOL agrees = fm.length && token && [token isEqualToString:WQCanonicalVarPath(fm)];
            if (agrees) [ordered insertObject:candidate atIndex:0]; else [ordered addObject:candidate];
            if (agrees) break;
        }
        for (id candidate in groups)
            if ([candidate isKindOfClass:NSString.class] && ![ordered containsObject:candidate]) [ordered addObject:candidate];
        for (NSString *candidate in ordered) {
            NSString *root = wq_group_root(candidate);
            if (root) {
                group = candidate;
                if (!WQRecoverCacheSwapAtPath([root stringByAppendingPathComponent:@"Library"]))
                    atomic_store(&gAccessRecoveryNeeded, YES);
                break;
            }
        }

    });
    return group;
}

#pragma mark - worse_query

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*cq_result_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_token_fn)(void *);
typedef int64_t (*ext_consume_fn)(const char *);
// The callback returns true to continue; a void block leaves that value undefined.
typedef void (*cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*co_get_path_fn)(void *);
typedef const char *(*co_get_id_fn)(void *);

static void wq_release_handle(int64_t handle);

static int64_t wq_query_token(NSString *group, BOOL altFlags)
{
    return wq_query_token_ex(group, altFlags, YES, NULL);
}

// `consumeIt` NO: only ask, for *covered (the path the token is issued for,
// its last field) without using the token.
static int64_t wq_query_token_ex(NSString *group, BOOL altFlags, BOOL consumeIt, NSString **covered)
{
    if (covered) *covered = nil;
    if (wq_access_capability_failure()) return -2;
    static void *mgr;
    static cq_create_fn create;
    static cq_set_u64_fn setClass, setFlags, setPart;
    static cq_set_ids_fn setGroups;
    static cq_result_fn single;
    static cq_free_fn freeQuery;
    static cq_token_fn copyToken;
    static ext_consume_fn consume;
    if (!mgr) {
        mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!mgr) return -2;
        create = (cq_create_fn)dlsym(mgr, "container_query_create");
        setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
        setGroups = (cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
        setFlags = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
        setPart = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
        single = (cq_result_fn)dlsym(mgr, "container_query_get_single_result");
        freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
        copyToken = (cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
        consume = (ext_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    }
    if (!create || !setClass || !setGroups || !setFlags || !setPart || !single || !freeQuery || !copyToken || !consume) return -2;

    void *query = create();
    if (!query) return -3;
    char *token = NULL;
    @try {
        setClass(query, 7);  // app group container
        xpc_object_t ident = xpc_string_create(group.UTF8String);
        setGroups(query, ident);
        setPart(query, 3);   // Library/Caches
        setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
        void *result = single(query);
        token = result ? copyToken(result) : NULL;
        if (token && covered) {
            NSString *text = @(token) ?: @"";
            NSRange last = [text rangeOfString:@";" options:NSBackwardsSearch];
            if (last.location != NSNotFound) *covered = [text substringFromIndex:NSMaxRange(last)];
        }
        if (!consumeIt) return token ? 0 : (result ? -6 : -5);
        int64_t handle = token ? consume(token) : (result ? -6 : -5);
        return token && handle < 0 ? -7 : handle;
    } @finally {
        if (token) free(token);
        freeQuery(query);
    }
}

BOOL wq_system_areas_reachable(void)
{
    // worse_query reaches System Data, the system groups and the App Groups
    // parent only on iOS 27; on iOS 26 it reaches the individual app,
    // extension, daemon and app group containers.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

// the swap marker, the preserved folder and what Caches is now.
BOOL wq_access_cache_needs_recovery(void) { return atomic_load(&gAccessRecoveryNeeded); }
static int64_t wq_query(NSString *target, BOOL altFlags)
{
    NSString *group = wq_app_group();
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = wq_group_root(group);
    if (!root) return -1;
    NSString *libraryPath = [root stringByAppendingPathComponent:@"Library"];
    if (![files createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil]) return -4;
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return -4;
    int lock = WQOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        // A lock that isn't a regular file (a link or folder another app left)
        // never opens: report it like a blocked cache so wq_grant's automatic
        // repair moves it aside (review DR-08). A busy lock is just busy.
        BOOL malformed = lock < 0 && (errno == EINVAL || errno == ELOOP || errno == EISDIR);
        if (malformed) atomic_store(&gAccessRecoveryNeeded, YES);

        if (lock >= 0) close(lock);
        close(library);
        return malformed ? -5 : -4;
    }
    int64_t handle = -4;
    @try {
        // Keep the exact Caches swap point required by worse_query, but preserve
        // its original inode and nested contents. Next acquisition recovers an
        // interrupted swap from the durable marker, before doing another query.
        if (WQCacheSwapBegin(library, target)) handle = wq_query_token(group, altFlags);
        else {
            // Library/Caches isn't in a state a query can start from, e.g. a
            // link another worse_query app sharing the App Group left behind
            // (LiveContainer, issue #65). wq_grant repairs it and asks again.
            handle = -5;
            atomic_store(&gAccessRecoveryNeeded, YES);
        }
    } @catch (NSException *__unused exception) {

        handle = -9;
    } @finally {
        if (!WQCacheSwapRecover(library)) {
            atomic_store(&gAccessRecoveryNeeded, YES);
            if (handle >= 0) wq_release_handle(handle);
            handle = -8;
        } else if (handle >= 0) {
            atomic_store(&gAccessRecoveryNeeded, NO);
        }
        close(lock);
        close(library);
    }
    return handle;
}

BOOL wq_reset_access_cache(NSString **errorText)
{
    NSString *group = wq_app_group();
    NSString *root = wq_group_root(group);
    if (!root) { if (errorText) *errorText = WQLocalized(@"The App Group is missing."); return NO; }
    NSString *libraryPath = [root stringByAppendingPathComponent:@"Library"];
    [NSFileManager.defaultManager createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil];
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    NSMutableArray<NSString *> *done = [NSMutableArray new];
    // Unlike token requests, repair moves a non-regular lock aside first.
    int lock = WQCacheLockOpenForRepair(library, done);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        int err = errno;
        if (lock >= 0) close(lock);
        close(library);

        if (errorText) *errorText = wq_errno(err);
        return NO;
    }
    BOOL ok = WQCacheSwapReset(library, done);
    atomic_store(&gAccessRecoveryNeeded, !ok);
    int err = errno;
    close(lock);
    close(library);

    if (!ok && errorText) *errorText = wq_errno(err);
    return ok;
}

static NSMutableDictionary<NSString *, NSNumber *> *gGrants;
static NSMutableArray<NSString *> *gGrantOrder;   // oldest first
// The kernel limits how many sandbox extensions a process may hold. Keep a
// bounded working set and release the oldest; released paths are simply
// granted again when they are next used.
static const NSUInteger kMaxGrants = 192;

static void wq_release_handle(int64_t handle)
{
    typedef int (*ext_release_fn)(int64_t);
    static ext_release_fn release;
    if (!release) release = (ext_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release && handle >= 0) release(handle);
}
static NSRecursiveLock *gGrantLock;

static NSString *wq_norm(NSString *path)
{
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

// Whether the target can now be opened. Only a sandbox denial (EPERM) counts
// as "the token didn't help": EACCES is ordinary file permissions (root-owned
// system containers), which a token never changes.
static BOOL wq_grant_opens(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) { close(fd); return YES; }
    return errno != EPERM;
}

BOOL wq_grant(NSString *path)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gGrants = [NSMutableDictionary new];
        gGrantOrder = [NSMutableArray new];
        gGrantLock = [NSRecursiveLock new];
    });
    NSString *key = wq_norm(path);
    [gGrantLock lock];
    NSNumber *known = gGrants[key];
    if (known) {
        [gGrantOrder removeObject:key];   // most recently used goes last
        [gGrantOrder addObject:key];
        [gGrantLock unlock];
        return YES;
    }
    while (gGrantOrder.count >= kMaxGrants) {
        NSString *oldest = gGrantOrder.firstObject;
        wq_release_handle(gGrants[oldest].longLongValue);
        [gGrants removeObjectForKey:oldest];
        [gGrantOrder removeObjectAtIndex:0];
    }
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        [gGrantLock unlock];
        return NO;  // worse_query needs an existing target
    }
    // iOS 26 needs the alternative query flags; try the likely ones first so
    // a grant costs one query, and the other set only when that fails. A
    // token can also be issued and consumed yet not open the target (seen on
    // 27.0.1 with an AltStore app group): check, and then try the other flags.
    // The set that works is remembered for the rest of the run.
    static int preferAlt = -1;
    BOOL altFirst = preferAlt >= 0 ? (BOOL)preferAlt : !wq_system_areas_reachable();
    int64_t handle = wq_query(key, altFirst);
    // A broken access cache refuses every folder until it is repaired: do
    // in the way is renamed aside), at most once a minute, and ask again.
    if (handle == -5) {
        static CFAbsoluteTime lastRepair;
        if (CFAbsoluteTimeGetCurrent() - lastRepair > 60) {
            lastRepair = CFAbsoluteTimeGetCurrent();
            NSString *error = nil;
            BOOL repaired = wq_reset_access_cache(&error);

            if (repaired) handle = wq_query(key, altFirst);
        }
    }
    BOOL usedAlt = altFirst;
    if (handle >= 0 && !wq_grant_opens(key)) {
        wq_release_handle(handle);
        handle = -8;
    }
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alt = wq_query(key, !altFirst);
        if (alt >= 0 && !wq_grant_opens(key)) {
            wq_release_handle(alt);
            alt = -8;
        }
        if (alt >= 0) {
            handle = alt;
            usedAlt = !altFirst;
        }
    }
    // Decided once, by the first grant that works: some targets refuse to
    // open for their own reasons, and a per-target fallback already covers
    // the rest, so flipping the preference back and forth only costs queries.
    if (handle >= 0 && preferAlt < 0) {
        preferAlt = usedAlt;

    }
    if (handle >= 0) {  // failures are retried next time
        gGrants[key] = @(handle);
        [gGrantOrder addObject:key];
    }
    [gGrantLock unlock];
    return handle >= 0;
}

static BOOL wq_is_denied(int err) { return err == EPERM || err == EACCES; }
#ifdef WQ_ACCESS_TESTING
static int64_t wq_test_volume_limit = -1;
static void (^wq_test_tree_hook)(NSString *stage, NSString *path);
static NSDictionary<NSString *, NSArray<NSString *> *> *(^wq_test_shared_scan_runner)(BOOL inodeOnly);
#define WQ_TREE_HOOK(stage, path) do { if (wq_test_tree_hook) wq_test_tree_hook(stage, path); } while (0)
#else
#define WQ_TREE_HOOK(stage, path) do {} while (0)
#endif
static int wq_open(NSString *path, int flags, mode_t mode);

NSArray<NSString *> *wq_list(NSString *dir, NSString **errorText)
{
    NSError *error = nil;
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && wq_grant(dir)) items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && errorText) *errorText = error.localizedDescription ?: WQLocalized(@"Cannot list this folder");
    if (!items) {
        // Keep the reason in errno, so callers can tell a refusal from a failure.
        int err = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoPermissionError ? EACCES : EIO;
        for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
            if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code > 0) { err = (int)e.code; break; }
        }
        errno = err;
    }
    return items;
}

static int wq_open(NSString *path, int flags, mode_t mode)
{
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    int fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd >= 0 || !wq_is_denied(errno)) return fd;
    // The file's own folder first, then the file itself.
    if (wq_grant(path.stringByDeletingLastPathComponent)) {
        fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
        if (fd >= 0 || !wq_is_denied(errno)) return fd;
    }
    if (!(flags & O_CREAT) && wq_grant(path)) fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    return fd;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    int fd = wq_open(path, O_RDONLY, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData new];
    uint8_t buf[65536];
    for (;;) {
        size_t want = sizeof(buf);
        if (maxBytes && data.length + want > maxBytes) want = maxBytes - data.length;
        if (want == 0) break;
        ssize_t n = read(fd, buf, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errorText) *errorText = wq_errno(errno);
            close(fd);
            return nil;
        }
        if (n == 0) break;
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    return data;
}

static BOOL wq_stat_allows(const struct stat *st, mode_t need)
{
    uid_t me = getuid();
    if (me == 0) return YES;
    if (st->st_uid == me) return (st->st_mode >> 6 & need) == need;
    BOOL member = st->st_gid == getgid();
    if (!member) {
        gid_t groups[64];
        int n = getgroups(64, groups);
        for (int i = 0; i < n && !member; i++) member = groups[i] == st->st_gid;
    }
    if (member) return (st->st_mode >> 3 & need) == need;
    return (st->st_mode & need) == need;
}

BOOL wq_stat_readable(const struct stat *st)
{
    return wq_stat_allows(st, S_ISDIR(st->st_mode) ? 5 : 4);   // r-x / r
}

NSString *wq_permission_hint(NSString *path, BOOL forWriting)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    uid_t me = getuid();
    if (wq_stat_allows(&st, forWriting ? 2 : 4)) return nil;   // w / r
    NSString *owner = st.st_uid == 0 ? @"root" : [NSString stringWithFormat:@"uid %d", (int)st.st_uid];
    return WQLocalizedFormat(@"This file belongs to %@ (mode %o) and only its owner may %@ it. charony reaches the folder, but runs as mobile (uid %d), so no app can %@ this file.",
            owner, st.st_mode & 07777, forWriting ? WQLocalized(@"change") : WQLocalized(@"read"), (int)me, forWriting ? WQLocalized(@"change") : WQLocalized(@"open"));
}

static int wq_open_directory_flags(NSString *path, int flags)
{
    int fd = WQOpenDirectoryNoLinksFlags(path, flags);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(path)) fd = WQOpenDirectoryNoLinksFlags(path, flags);
    return fd;
}

static int wq_open_directory(NSString *path)
{
    return wq_open_directory_flags(path, O_RDONLY);
}

// fsgetpath: resolve a filesystem object id to a path. Not in the public SDK.
extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

// Highest object id in use on the volume, roughly: APFS hands out ids in
// increasing order, so a file created now gets one of the newest. Containers
// of apps installed long after setup sit far above the ids of Apple's own
// apps; a fixed limit misses them on a well-used device.
static const int64_t kWQInodeMargin = 100000;

static int64_t wq_volume_max_inode(fsid_t fsid, int64_t *probeInode)
{
    if (probeInode) *probeInode = 0;
#ifdef WQ_ACCESS_TESTING
    if (wq_test_volume_limit >= 0) return wq_test_volume_limit;
#endif
    NSArray<NSString *> *directories = @[
        NSTemporaryDirectory() ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
    ];
    for (NSString *directory in directories) {
        if (!directory.length) continue;
        NSString *probe = [directory stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"wq-inode-%u", arc4random()]];
        int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) {

            continue;
        }
        struct stat st = {0};
        struct statfs sfs = {0};
        BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
        close(fd);
        unlink(probe.fileSystemRepresentation);
        if (!ok) {

            continue;
        }
        if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) {

            continue;
        }
        if ((uint64_t)st.st_ino > (uint64_t)INT64_MAX - (uint64_t)kWQInodeMargin) return 0;
        if (probeInode) *probeInode = (int64_t)st.st_ino;
        return (int64_t)st.st_ino + kWQInodeMargin;
    }
    return 0;
}

// A shared index may serve several screens/tasks. Park it only when the last
// waiter leaves; pausing one task must not pause another task's index lookup.
// With no demand the worker checkpoints and exits, releasing the global scan
// gate; the next caller resumes from disk rather than holding that gate idle.
@interface WQScanDemand : NSObject
- (BOOL)join;
- (void)leave;
- (void)abandon;
- (BOOL)wait:(WQScanCancellation *)cancellation;
@end
@implementation WQScanDemand {
    NSCondition *_condition;
    NSUInteger _waiters;
    BOOL _abandoned, _started, _stopped;
}
- (instancetype)init { if ((self = [super init])) _condition = [NSCondition new]; return self; }
- (BOOL)join
{
    [_condition lock];
    BOOL joined = !_stopped;
    if (joined) { _waiters++; _started = YES; [_condition broadcast]; }
    [_condition unlock];
    return joined;
}
- (void)leave
{
    [_condition lock];
    if (_waiters) _waiters--;
    if (!_waiters) _stopped = YES;
    [_condition broadcast];
    [_condition unlock];
}
- (void)abandon { [_condition lock]; _abandoned = YES; [_condition broadcast]; [_condition unlock]; }
- (BOOL)wait:(WQScanCancellation *)cancellation
{
    [_condition lock];
    while (!_started && !_abandoned && !cancellation.isCancelled)
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    BOOL proceed = _waiters > 0 && !cancellation.isCancelled;
    [_condition unlock];
    return proceed;
}
@end

// The user stopped a full scan: the next one starts over (and asks first).
static void wq_scan_checkpoint_remove(NSArray<NSString *> *bases)
{
    WQScanJournalRemove([@"inodes:" stringByAppendingString:[bases componentsJoinedByString:@"\n"]]);
}

static NSDictionary *wq_scan_checkpoint_load(fsid_t fsid, int64_t firstId, int64_t lastId, NSArray<NSString *> *bases)
{
    NSDictionary *checkpoint = WQScanJournalLoad([@"inodes:" stringByAppendingString:[bases componentsJoinedByString:@"\n"]]);
    NSArray *seed = checkpoint[@"found"];
    BOOL resume = [checkpoint[@"fsid"] isEqual:@[@(fsid.val[0]), @(fsid.val[1])]] &&
        [checkpoint[@"first"] isEqual:@(firstId)] &&
        [checkpoint[@"last"] isKindOfClass:NSNumber.class] && [checkpoint[@"next"] isKindOfClass:NSNumber.class] &&
        [checkpoint[@"at"] isKindOfClass:NSDate.class] &&
        -[checkpoint[@"at"] timeIntervalSinceNow] >= 0 && -[checkpoint[@"at"] timeIntervalSinceNow] < 7 * 86400 &&
        [checkpoint[@"last"] longLongValue] <= lastId &&
        [checkpoint[@"next"] longLongValue] >= firstId &&
        [checkpoint[@"next"] longLongValue] <= [checkpoint[@"last"] longLongValue] + 1 &&
        [seed isKindOfClass:NSArray.class] && seed.count == MIN(bases.count, (NSUInteger)8);
    for (id entries in resume ? seed : @[]) if (![entries isKindOfClass:NSDictionary.class]) resume = NO;
    return resume ? checkpoint : nil;
}

// Scans object ids first...last once and collects the direct children of every
// base in `bases` (each a /private/var/... path), as path -> object id. Uses at
// most 4 worker threads (half the cores) at `qos`: a full scan of a well-used
// device is millions of ids, and running it on every core made phones hot.
// progress gets the ids done, the range size and the hits per base. Returns
// one dictionary per base, or nil when cancelled.
typedef void (^WQScanProgress)(int64_t done, int64_t total, const NSUInteger *counts);
// Inode checkpoints are written at most this often (every chunk in the
// recovery tests, which kill the process right after one).
#ifdef WQ_ACCESS_TESTING
static const NSTimeInterval kWQCheckpointInterval = 0;
#else
static const NSTimeInterval kWQCheckpointInterval = 20.0;
#endif
static NSArray<NSMutableDictionary<NSString *, NSNumber *> *> *wq_scan_children(fsid_t fsid, int64_t firstId, int64_t lastId,
                                                                               NSArray<NSString *> *bases,
                                                                               WQScanCancellation *cancellation,
                                                                               qos_class_t qos, BOOL allCores,
                                                                               WQScanProgress progress, WQScanDemand *demand)
{
    NSUInteger baseCount = MIN(bases.count, (NSUInteger)8);
    int64_t requestedFirst = MAX((int64_t)1, firstId);
    NSString *journalKey = [@"inodes:" stringByAppendingString:[bases componentsJoinedByString:@"\n"]];
    NSDictionary *checkpoint = wq_scan_checkpoint_load(fsid, requestedFirst, lastId, bases);
    NSArray *seed = checkpoint[@"found"];
    BOOL resume = checkpoint != nil;
    if (resume) {
        firstId = [checkpoint[@"next"] longLongValue];

    }
    // Heap tables: blocks can't capture C arrays.
    char **prefixes = calloc(8, sizeof(char *));
    size_t *prefixLens = calloc(8, sizeof(size_t));
    NSUInteger *counts = calloc(8, sizeof(NSUInteger));
    if (!prefixes || !prefixLens || !counts) { free(prefixes); free(prefixLens); free(counts); return nil; }
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *found = [NSMutableArray new];
    for (NSUInteger i = 0; i < baseCount; i++) {
        prefixes[i] = strdup(bases[i].fileSystemRepresentation);
        prefixLens[i] = strlen(prefixes[i]);
        NSMutableDictionary *verified = [NSMutableDictionary new];
        for (id path in resume ? seed[i] : @{}) {
            id inode = seed[i][path];
            if (![inode isKindOfClass:NSNumber.class]) continue;
            char current[1200];
            fsid_t volume = fsid;
            if (fsgetpath(current, sizeof(current), &volume, [inode unsignedLongLongValue]) <= 0) continue;
            NSString *resolved = [NSString stringWithUTF8String:current];
            if ([resolved.stringByDeletingLastPathComponent isEqual:bases[i]]) verified[resolved] = inode;
        }
        [found addObject:verified];
    }
    if (firstId < 1) firstId = 1;
    int64_t total = lastId >= firstId ? lastId - firstId + 1 : 0;
    NSLock *lock = [NSLock new];
    const int64_t chunk = 32768;
    int64_t chunks = (total + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0, frontier = 0;
    NSMutableIndexSet *completed = [NSMutableIndexSet new];
    // Save out-of-order ranges too: a slow early chunk must not force later,
    // already committed chunks to run again after a restart.
    for (id range in resume && [checkpoint[@"ranges"] isKindOfClass:NSArray.class] ? checkpoint[@"ranges"] : @[]) {
        if (![range isKindOfClass:NSArray.class] || [range count] != 2 ||
            ![range[0] isKindOfClass:NSNumber.class] || ![range[1] isKindOfClass:NSNumber.class]) continue;
        int64_t start = [range[0] longLongValue], end = [range[1] longLongValue];
        if (start >= firstId && end >= start && end <= [checkpoint[@"last"] longLongValue])
            [completed addIndexesInRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))];
    }
    done = (int64_t)completed.count;
    // Checkpoints: a snapshot is taken under `lock` (cheap copies), written
    // outside it every 20 s, and never older over newer. Writing the whole
    // found set every second stalled every worker and wrote hundreds of MB
    // over a long scan (iOS kills apps for heavy disk writes).
    __block NSTimeInterval savedAt = NSDate.date.timeIntervalSinceReferenceDate;
    __block uint64_t snapshotSeq = 0, writtenSeq = 0;
    NSLock *writeLock = [NSLock new];
    NSDictionary *(^snapshotCheckpoint)(void) = ^NSDictionary *{   // caller holds lock
        NSMutableArray *ranges = [NSMutableArray new];
        [completed enumerateRangesUsingBlock:^(NSRange range, BOOL *__unused stop) {
            [ranges addObject:@[@(range.location), @(NSMaxRange(range) - 1)]];
        }];
        NSMutableArray *foundCopy = [NSMutableArray arrayWithCapacity:found.count];
        for (NSDictionary *hits in found) [foundCopy addObject:[hits copy]];
        snapshotSeq++;
        return @{@"seq": @(snapshotSeq), @"state": @{@"fsid": @[@(fsid.val[0]), @(fsid.val[1])], @"first": @(requestedFirst),
            @"last": @(lastId), @"next": @(MIN(firstId + frontier * chunk, lastId + 1)),
            @"found": foundCopy, @"ranges": ranges, @"at": NSDate.date}};
    };
    void (^writeCheckpoint)(NSDictionary *) = ^(NSDictionary *snapshot) {
        uint64_t seq = [snapshot[@"seq"] unsignedLongLongValue];
        [writeLock lock];
        if (seq > writtenSeq) {
            (void)WQScanJournalSave(journalKey, snapshot[@"state"]);
            writtenSeq = seq;
        }
        [writeLock unlock];
    };
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    // A full scan the user agreed to wait for uses all but two cores; the
    // short incremental scans stay at half the cores.
    size_t workers = allCores ? (size_t)MAX((NSUInteger)2, MIN((NSUInteger)8, cores > 2 ? cores - 2 : 1))
                              : (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    __block _Atomic BOOL abandoned = NO;
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        for (;;) {
            if (!wq_scan_wait(cancellation)) return;
            if (demand && ![demand wait:cancellation]) { atomic_store(&abandoned, YES); return; }
            [lock lock];
            int64_t c = nextChunk++;
            if (c >= chunks) { [lock unlock]; return; }
            int64_t first = firstId + c * chunk, last = MIN(first + chunk - 1, lastId);
            BOOL alreadyDone = c < frontier || [completed containsIndexesInRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
            [lock unlock];
            if (alreadyDone) continue;
            NSMutableDictionary *local[8] = {nil};
            for (int64_t ino = first; ino <= last; ino++) {
                if ((ino & 127) == 0 && cancellation.isCancelled) return;
                ssize_t n = fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino);
                if (n <= 0) continue;
                // fsgetpath returns /private/var/...; bases are normalized the same way.
                for (NSUInteger i = 0; i < baseCount; i++) {
                    if (strncmp(buf, prefixes[i], prefixLens[i]) == 0 && buf[prefixLens[i]] == '/' &&
                        strchr(buf + prefixLens[i] + 1, '/') == NULL) {
                        if (!local[i]) local[i] = [NSMutableDictionary new];
                        local[i][[NSString stringWithUTF8String:buf]] = @(ino);
                        break;
                    }
                }
            }
            NSUInteger snapshot[8] = {0};
            [lock lock];
            for (NSUInteger i = 0; i < baseCount; i++) {
                if (local[i]) [found[i] addEntriesFromDictionary:local[i]];
                snapshot[i] = counts[i] = found[i].count;
            }
            NSRange finishedRange = NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1));
            done += last - first + 1 - (int64_t)[completed countOfIndexesInRange:finishedRange];
            [completed addIndexesInRange:finishedRange];
            while (frontier < chunks) {
                int64_t start = firstId + frontier * chunk, end = MIN(start + chunk - 1, lastId);
                NSRange prefix = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1));
                if (![completed containsIndexesInRange:prefix]) break;
                [completed removeIndexesInRange:prefix];
                frontier++;
            }
            NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
            NSDictionary *checkpointState = nil;
            if (now - savedAt >= kWQCheckpointInterval) { checkpointState = snapshotCheckpoint(); savedAt = now; }
            int64_t nowDone = done + firstId - requestedFirst;
            [lock unlock];
            if (checkpointState) writeCheckpoint(checkpointState);
            if (progress && !cancellation.isCancelled) progress(nowDone, lastId - requestedFirst + 1, snapshot);
        }
    });
    for (NSUInteger i = 0; i < baseCount; i++) free(prefixes[i]);
    free(prefixes);
    free(prefixLens);
    free(counts);
    // Interrupted: save both the contiguous frontier and completed ranges
    // beyond a hole. Finished: the checkpoint has done its job; a kept one
    // would turn the next forced full scan into a silent resume.
    if (cancellation.isCancelled || atomic_load(&abandoned)) {
        [lock lock];
        NSDictionary *snapshot = snapshotCheckpoint();
        [lock unlock];
        writeCheckpoint(snapshot);
        return nil;
    }
    WQScanJournalRemove(journalKey);
    return found;
}

static NSArray<NSString *> *wq_sorted_paths(NSDictionary<NSString *, NSNumber *> *hits)
{
    return [hits.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

// The three container parents that can only be listed by scanning. One scan
// collects all three and is reused for a while: the Cache Cleaner alone used to
// scan the whole id range three times (apps, extensions, and the daemon scan
// that finds the app name database).
static NSArray<NSString *> *wq_shared_scan_roots(void)
{
    return @[ @"/private/var/mobile/Containers/Data/Application",
              @"/private/var/mobile/Containers/Data/PluginKitPlugin",
              @"/private/var/mobile/Containers/Data/InternalDaemon" ];
}

// One shared scan runs at a time, detached from the screen that started it:
// leaving the screen no longer throws the work away. Waiters stop waiting when
// cancelled; the scan finishes and is reused by the next caller.
static NSObject *gSharedScanGuard;
static void (^gScanProgress)(int64_t, int64_t, NSUInteger);
static NSUInteger gScanProgressIndex;
static id gScanProgressOwner;

static void wq_shared_scan_setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSharedScanGuard = [NSObject new]; });
}

static void wq_scan_slots_clear(void);
static void wq_label_caches_invalidate(void);

void wq_enumerate_invalidate(void)
{
    wq_shared_scan_setup();
    @synchronized (gSharedScanGuard) { wq_scan_slots_clear(); }
    wq_label_caches_invalidate();
    // A refresh also retries the background LaunchServices database search.
    [wq_discovery_state() removeObjectForKey:@"WQLaunchServicesDiscoveryMissedAt"];
}

// areas are visible without listing individual files.

// LaunchServices API: each app's and plug-in's data container, where the
// system lets this app ask (it refuses on iOS 27).
// Path -> bundle id caches (this API's and the container manager's) are tied
// to the folder object they were made for: each entry keeps the (device,
// inode) seen when it was recorded, or on its first use when the folder
// couldn't be checked then, and a folder with another identity doesn't get
// the cached id. An explicit refresh drops both caches.
static NSDictionary<NSString *, NSString *> *gLSAPILabels;
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *gLSAPIIdentities;
static _Atomic NSUInteger gWQLabelGeneration;

typedef NS_ENUM(int, WQLabelIdentity) { WQLabelIdentityUnknown, WQLabelIdentityKnown, WQLabelIdentityGone };

static WQLabelIdentity wq_label_identity(NSString *path, NSArray<NSNumber *> **identity)
{
    *identity = nil;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT ? WQLabelIdentityGone : WQLabelIdentityUnknown;
    if (!S_ISDIR(st.st_mode)) return WQLabelIdentityGone;
    *identity = @[@((uint64_t)st.st_dev), @((uint64_t)st.st_ino)];
    return WQLabelIdentityKnown;
}

// Whether a cached id for key may be used for the folder as it is now.
// Caller holds the lock of identities.
static BOOL wq_label_identity_matches(NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *identities, NSString *key,
                                      WQLabelIdentity state, NSArray<NSNumber *> *current)
{
    if (state == WQLabelIdentityGone) return NO;
    if (state == WQLabelIdentityUnknown) return YES;   // can't be checked: as before
    NSArray *recorded = identities[key];
    if (!recorded) { identities[key] = current; return YES; }
    return [recorded isEqualToArray:current];
}

static void wq_label_caches_invalidate(void)
{
    @synchronized (NSNull.null) { gLSAPILabels = nil; gLSAPIIdentities = nil; }
    atomic_fetch_add(&gWQLabelGeneration, 1);
}

static NSDictionary<NSString *, NSArray<NSString *> *> *wq_lsapi_list_containers(NSArray<NSString *> *roots)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL appsSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSel]) {  return nil; }
    NSMutableDictionary<NSString *, NSString *> *labels = [NSMutableDictionary new];
    @try {
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id workspace = send(workspaceClass, defaultSel);
        if (![workspace respondsToSelector:appsSel]) {  return nil; }
        NSArray *apps = send(workspace, appsSel);
        SEL containerSel = NSSelectorFromString(@"dataContainerURL"), idSel = NSSelectorFromString(@"bundleIdentifier");
        SEL pluginsSel = NSSelectorFromString(@"plugInKitPlugins");
        void (^add)(id) = ^(id proxy) {
            if (![proxy respondsToSelector:containerSel] || ![proxy respondsToSelector:idSel]) return;
            NSURL *url = send(proxy, containerSel);
            NSString *bid = send(proxy, idSel);
            if (![url isKindOfClass:NSURL.class] || ![bid isKindOfClass:NSString.class] || !url.path.length || !bid.length) return;
            NSString *path = wq_norm(url.path);
            if (!labels[path]) labels[path] = bid;
        };
        for (id app in [apps isKindOfClass:NSArray.class] ? apps : @[]) {
            add(app);
            NSArray *appPlugins = [app respondsToSelector:pluginsSel] ? send(app, pluginsSel) : nil;
            for (id plugin in [appPlugins isKindOfClass:NSArray.class] ? appPlugins : @[]) { add(plugin); }
        }
    } @catch (NSException *__unused exception) {

        return nil;
    }
    NSMutableDictionary<NSString *, NSMutableArray *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableArray new];
    for (NSString *path in labels) [found[path.stringByDeletingLastPathComponent] addObject:path];
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root] sortedArrayUsingSelector:@selector(compare:)];

    NSMutableDictionary *identities = [NSMutableDictionary new];
    for (NSString *path in labels) {
        NSArray<NSNumber *> *identity = nil;
        if (wq_label_identity(path, &identity) == WQLabelIdentityKnown) identities[path] = identity;
    }
    @synchronized (NSNull.null) { gLSAPILabels = [labels copy]; gLSAPIIdentities = identities; }
    return result;
}

// The container manager can list containers directly (instant, no scan). On
// releases where it answers this app only with its own containers, the list
// has no other apps and the fsgetpath scan is used instead. Classes are not
// relied on: every class is asked and paths are sorted by their parent.
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_mcm_list_containers(NSArray<NSString *> *roots)
{
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableSet new];
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {  return nil; }
    cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
    cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
    cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
    co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
    if (!create || !setClass || !iterate || !freeQuery || !getPath) {
        dlclose(mgr);

        return nil;
    }
    for (uint64_t cls = 1; cls <= 14; cls++) {
        void *query = create();
        if (!query) continue;
        setClass(query, cls);
        @try {
            iterate(query, ^bool(void *object) {
                const char *path = object ? getPath(object) : NULL;
                if (!path || !path[0]) return true;
                NSString *norm = wq_norm([NSString stringWithUTF8String:path] ?: @"");
                NSString *parent = norm.stringByDeletingLastPathComponent;
                [found[parent] addObject:norm];
                return true;
            });
        } @catch (NSException *__unused exception) {

        }
        freeQuery(query);
    }
    dlclose(mgr);
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root].allObjects sortedArrayUsingSelector:@selector(compare:)];

    return result;
}

// Samples ids across the volume. On some releases fsgetpath resolves only the
// caller's own files; then a full scan takes minutes and finds nothing.
static BOOL wq_fsgetpath_sees_others(fsid_t fsid, int64_t maxInode, double *idsPerSecond)
{
    NSMutableArray<NSString *> *own = [NSMutableArray arrayWithObject:wq_norm(NSHomeDirectory())];
    NSString *bundle = wq_norm(NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent);
    if (bundle.length) [own addObject:bundle];
    NSString *group = wq_app_group();
    NSString *groupRoot = wq_group_root(group);
    if (groupRoot.length) [own addObject:wq_norm(groupRoot)];
    int64_t stride = MAX((int64_t)1, maxInode / 20000);
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSUInteger sampled = 0, foreign = 0;
    char buf[1200];
    for (int64_t ino = 1 + (int64_t)arc4random_uniform((uint32_t)MIN(stride, (int64_t)UINT32_MAX)); ino <= maxInode; ino += stride) {
        sampled++;
        fsid_t id = fsid;
        if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:buf];
        BOOL mine = NO;
        for (NSString *prefix in own) if ([path hasPrefix:prefix]) { mine = YES; break; }
        if (!mine) {
            foreign++;
        }
    }

    double elapsed = CFAbsoluteTimeGetCurrent() - started;
    if (idsPerSecond) *idsPerSecond = elapsed > 0 ? sampled / elapsed : 0;
    return foreign > 0;
}

// Full scans (every file id) take minutes on a well-used device. The UI
// confirms them first and shows their progress; without a UI hook (or when
// the app isn't in front) they don't start.
static BOOL (*gFullScanConfirm)(NSString *what, int64_t ids, double seconds);
static void (*gFullScanProgress)(int64_t done, int64_t total, BOOL finished);
static WQScanCancellation *gFullScanStop;

void wq_set_full_scan_ui(BOOL (*confirm)(NSString *what, int64_t ids, double seconds),
                         void (*progress)(int64_t done, int64_t total, BOOL finished))
{
    gFullScanConfirm = confirm;
    gFullScanProgress = progress;
}

void wq_full_scan_stop(void)
{
    @synchronized (NSNull.null) { [gFullScanStop cancel]; }
}

// Full scans run one at a time (the App Data and Internal Daemons slots can
// both need one): the stop token, the progress window, its completion and the
// background task belong to a single scan. A second full scan waits here until
// the first has ended, and only then asks.
static dispatch_semaphore_t wq_full_scan_gate(void)
{
    static dispatch_semaphore_t gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = dispatch_semaphore_create(1); });
    return gate;
}

// NO when the caller was cancelled while waiting.
static BOOL wq_full_scan_acquire(NSString *__unused what, WQScanCancellation *caller)
{
    dispatch_semaphore_t gate = wq_full_scan_gate();
    if (dispatch_semaphore_wait(gate, DISPATCH_TIME_NOW) == 0) return YES;

    while (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (caller.isCancelled) return NO;
    }
    return YES;
}

static void wq_full_scan_release(void)
{
    dispatch_semaphore_signal(wq_full_scan_gate());
}

// Asks before a full scan. Returns the scan's stop token, or nil when the user
// (or the missing UI) declined. A non-nil token holds the full-scan gate until
// wq_full_scan_end.
static WQScanCancellation *wq_full_scan_begin(NSString *what, int64_t ids, double seconds, WQScanCancellation *caller, BOOL __unused resuming)
{
    // Without an App Group no container can be opened or named, so a long
    // scan would only produce a list of unusable folders.
    if (!wq_app_group()) {


        return nil;
    }
    if (!wq_full_scan_acquire(what, caller)) return nil;
    // A resumed scan asks too: the confirmation also opens the scan window,
    // the only place to Stop it.

    if (!gFullScanConfirm || !gFullScanConfirm(what, ids, seconds)) {


        wq_full_scan_release();
        return nil;
    }

    WQScanCancellation *stop = [WQScanCancellation new];
    @synchronized (NSNull.null) { gFullScanStop = stop; }
    return stop;
}

static void wq_full_scan_end(WQScanCancellation *stop)
{
    @synchronized (NSNull.null) { if (gFullScanStop == stop) gFullScanStop = nil; }
    // The window's completion is queued before the next scan can ask.
    if (gFullScanProgress) gFullScanProgress(0, 0, YES);

    wq_full_scan_release();
}

// Rough duration of a full scan from a single-thread sample rate.
static double wq_full_scan_estimate(int64_t ids, double sampleRate)
{
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    double workers = MAX(2.0, MIN(8.0, cores > 2 ? (double)cores - 2 : 1.0));
    double rate = (sampleRate > 0 ? sampleRate : 15000.0) * workers * 0.8;
    return ids / rate;
}

static NSArray<NSString *> *(*gContainerListProvider)(NSString *storeHint);

void wq_set_container_list_provider(NSArray<NSString *> *(*provider)(NSString *storeHint))
{
    gContainerListProvider = provider;
}

static BOOL wq_is_ls_store_name(const char *path)
{
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    size_t len = strlen(name);
    return len > 33 && strncmp(name, "com.apple.LaunchServices-", 25) == 0 && strcmp(name + len - 8, ".csstore") == 0;
}

// The LaunchServices database is rewritten on every app install or update, so
// its id is among the newest: scan down from the top and stop at the first.
static const CFTimeInterval kWQStoreSearchLimit = 20;

static NSString *wq_scan_for_ls_store(fsid_t fsid, int64_t maxInode, qos_class_t qos, WQScanProgress progress, WQScanDemand *demand)
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    const int64_t chunk = 32768;
    int64_t chunks = (maxInode + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    __block NSString *found = nil;
    NSLock *lock = [NSLock new];
    WQScanCancellation *stop = [WQScanCancellation new];
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        NSUInteger none[8] = {0};
        for (;;) {
            if (!wq_scan_wait(stop) || (demand && ![demand wait:stop])) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            // Normally found among the newest ids within seconds; past the
            // limit the full scan is the better way (and asks first).
            if (CFAbsoluteTimeGetCurrent() - started > kWQStoreSearchLimit) { [stop cancel]; return; }
            int64_t last = maxInode - c * chunk, first = MAX((int64_t)1, last - chunk + 1);
            for (int64_t ino = last; ino >= first; ino--) {
                if ((ino & 127) == 0 && stop.isCancelled) return;
                if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0 || !wq_is_ls_store_name(buf)) continue;
                [lock lock];
                if (!found) found = [NSString stringWithUTF8String:buf];
                [lock unlock];
                [stop cancel];
                return;
            }
            [lock lock];
            done += last - first + 1;
            int64_t nowDone = done;
            [lock unlock];
            if (progress && !stop.isCancelled) progress(nowDone, maxInode, none);
        }
    });
    return found;
}

// When the container manager lists the containers, the database search in
// wq_containers_from_ls_store doesn't run, yet the name loader only reads a
// remembered database: look for it in the background (the same bounded id
// search), so app names and labels don't stay missing after a cold start.
// One search at a time; after a miss, again only after a day or a refresh.
static NSString *const kWQStoreDiscoveryMissKey = @"WQLaunchServicesDiscoveryMissedAt";
static _Atomic BOOL gStoreDiscoveryRunning;

static void wq_discover_ls_store_in_background(fsid_t fsid)
{
    if (!gContainerListProvider) return;
    NSDate *missed = [wq_discovery_state() objectForKey:kWQStoreDiscoveryMissKey];
    if ([missed isKindOfClass:NSDate.class] && fabs(missed.timeIntervalSinceNow) < 24 * 60 * 60) return;
    if (atomic_exchange(&gStoreDiscoveryRunning, YES)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (gContainerListProvider(nil).count >= 2) return;   // remembered and readable
            int64_t probeInode = 0;
            int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
            NSString *store = maxInode > 0 ? wq_scan_for_ls_store(fsid, maxInode, QOS_CLASS_UTILITY, nil, nil) : nil;
            NSUInteger listed = store ? gContainerListProvider(store).count : 0;
            if (listed < 2) {
                [wq_discovery_state() setObject:NSDate.date forKey:kWQStoreDiscoveryMissKey];

            }
        } @finally {
            atomic_store(&gStoreDiscoveryRunning, NO);
        }
    });
}

// The LaunchServices database keeps containers of earlier installs that no
// longer exist. Drop those (lstat says ENOENT even without access); keep
// anything that exists or can't be checked.
static NSArray<NSString *> *wq_existing_containers(NSArray<NSString *> *paths, NSUInteger *dropped)
{
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:paths.count];
    struct stat st;
    for (NSString *path in paths) {
        if (lstat(path.fileSystemRepresentation, &st) != 0 && errno == ENOENT) { (*dropped)++; continue; }
        [kept addObject:path];
    }
    return kept;
}

// The App Data and Extensions lists from the LaunchServices database.
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_containers_from_ls_store(NSArray<NSString *> *roots, fsid_t fsid,
                                                                                   qos_class_t qos, WQScanProgress progress, WQScanDemand *demand)
{
    if (!gContainerListProvider) return nil;
    NSArray<NSString *> *paths = gContainerListProvider(nil);
    if (paths.count < 2) {
        int64_t probeInode = 0;
        int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) return nil;
        NSString *store = wq_scan_for_ls_store(fsid, maxInode, qos, progress, demand);
        if (!store) {

            return nil;
        }
        paths = gContainerListProvider(store);
        if (paths.count < 2) {

            return nil;
        }
    }
    NSUInteger stale = 0;
    NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) [normalized addObject:wq_norm(path)];
    paths = wq_existing_containers(normalized, &stale);

    NSMutableDictionary<NSString *, NSMutableArray *> *byRoot = [NSMutableDictionary new];
    for (NSString *root in roots) byRoot[root] = [NSMutableArray new];
    for (NSString *path in paths) [byRoot[path.stringByDeletingLastPathComponent] addObject:path];
    if ([byRoot[roots[0]] count] < 2) return nil;
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [byRoot[root] sortedArrayUsingSelector:@selector(compare:)];

    return result;
}

// inodeOnly: skip the container manager and LaunchServices shortcuts and scan
// ids (iOS 26 Internal Daemons, which no database lists).
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_run_shared_scan(fsid_t fsid, qos_class_t qos, BOOL inodeOnly, WQScanDemand *demand)
{
    if (demand && ![demand wait:nil]) return nil;
    NSArray<NSString *> *roots = wq_shared_scan_roots();

    if (inodeOnly) goto inodeScan;
    {
    NSDictionary<NSString *, NSArray<NSString *> *> *listed = wq_mcm_list_containers(roots);

    // Other apps' containers listed: no scan needed. A list with only this
    // app's own container is not enough.
    if ([listed[roots[0]] count] > 1) {
        wq_discover_ls_store_in_background(fsid);
        return listed;
    }
    NSDictionary<NSString *, NSArray<NSString *> *> *lsListed = wq_lsapi_list_containers(roots);

    if (!wq_system_areas_reachable() && [lsListed[roots[0]] count] > 1) {
        // The API doesn't list daemon containers; those still need the scan
        // on releases where it works, so only skip it when apps are covered.
        NSMutableDictionary *merged = [lsListed mutableCopy];
        if (![merged[roots[2]] count]) merged[roots[2]] = @[];
        return merged;
    }
    {
        // A full scan is tens of millions of ids (minutes, up to most of an
        // hour); the database lists the same app and extension containers.
        WQScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *__unused counts) {
            void (^progress)(int64_t, int64_t, NSUInteger) = nil;
            @synchronized (gSharedScanGuard) { progress = gScanProgress; }
            if (progress) progress(done, total, 0);
        };
        NSDictionary *fromStore = wq_containers_from_ls_store(roots, fsid, qos, report, demand);
        if (fromStore) return fromStore;
    }
    }
inodeScan:;
    if (demand && ![demand wait:nil]) return nil;
    int64_t probeInode = 0;
    int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
    if (maxInode <= 0) {

        return nil;
    }
    if (maxInode > INT64_MAX - 32768) {

        return nil;
    }
    int64_t firstId = 1;
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *known = [NSMutableArray new];
    for (NSUInteger i = 0; i < roots.count; i++) [known addObject:[NSMutableDictionary new]];
    double sampleRate = 0;
    if (!wq_fsgetpath_sees_others(fsid, maxInode, &sampleRate)) {

        return nil;
    }
    WQScanCancellation *stop = nil;
    {
        stop = wq_full_scan_begin(inodeOnly ? WQLocalized(@"Internal Daemons") : WQLocalized(@"the app folders"), maxInode,
                                  wq_full_scan_estimate(maxInode, sampleRate), nil,
                                  wq_scan_checkpoint_load(fsid, firstId, maxInode, roots) != nil);
        if (!stop) return nil;   // declined: progress kept, the next attempt asks again
        qos = QOS_CLASS_USER_INITIATED;
    }
    WQScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *counts) {
        void (^progress)(int64_t, int64_t, NSUInteger) = nil;
        NSUInteger index = 0;
        @synchronized (gSharedScanGuard) { progress = gScanProgress; index = gScanProgressIndex; }
        if (progress) progress(done, total, (index < roots.count ? known[index].count : 0) + (index < 8 ? counts[index] : 0));
        if (stop && gFullScanProgress) gFullScanProgress(done, total, NO);
    };
    NSArray *lists = wq_scan_children(fsid, firstId, maxInode, roots, stop, qos, stop != nil, report, demand);
    if (stop && stop.isCancelled) wq_scan_checkpoint_remove(roots);   // Stop: start over next time, and only when asked
    if (stop) wq_full_scan_end(stop);
    if (!lists) return nil;
    NSMutableDictionary *scan = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < roots.count; i++) {
        [known[i] addEntriesFromDictionary:lists[i]];
        scan[roots[i]] = wq_sorted_paths(known[i]);
    }

    return scan;
}

// One scan per slot runs at a time. On iOS 26 the Internal Daemons id scan
// (most of an hour the first time) has its own slot, so the lists that come
// from the LaunchServices database never wait for it.
// generation: bumped by wq_enumerate_invalidate. A worker publishes into the
// slot only when the generation it started with is still current; callers
// after an invalidation start a new worker, which first waits for the
// detached one (previous) so the two never scan at the same time.
@interface WQScanSlot : NSObject
@property (nonatomic, strong) WQScanDemand *demand;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *scan;
@property (nonatomic, strong) dispatch_group_t group;
@property (nonatomic, strong) NSMutableDictionary *box;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) dispatch_group_t previous;
@end
@implementation WQScanSlot
@end

static WQScanSlot *wq_scan_slot(BOOL inode)
{
    static WQScanSlot *slots[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slots[0] = [WQScanSlot new]; slots[1] = [WQScanSlot new]; });
    return slots[inode ? 1 : 0];
}

static void wq_scan_slots_clear(void)
{
    for (int i = 0; i < 2; i++) {
        WQScanSlot *slot = wq_scan_slot(i == 1);
        slot.scan = nil;

        slot.generation++;
        // A running worker keeps its own waiters but no longer serves new
        // callers or fills the slot.
        if (slot.group) {
            slot.previous = slot.group;
            [slot.demand abandon];
            slot.group = nil;
            slot.box = nil;
        }
    }
}

static NSArray<NSString *> *wq_shared_children(NSString *base, fsid_t fsid, WQScanCancellation *cancellation,
                                               void (^progress)(int64_t, int64_t, NSUInteger))
{
    wq_shared_scan_setup();
    NSUInteger baseIndex = [wq_shared_scan_roots() indexOfObject:base];
    // iOS 26 lists apps and extensions from the LaunchServices database; only
    // Internal Daemons need the (long) id scan.
    BOOL inodeOnly = [base isEqualToString:@"/private/var/mobile/Containers/Data/InternalDaemon"];
    WQScanSlot *slot = wq_scan_slot(inodeOnly);
    id owner = [NSObject new];
    dispatch_group_t group = nil;
    NSMutableDictionary *box = nil;
    WQScanDemand *demand = nil;
    @synchronized (gSharedScanGuard) {
        if (slot.scan) {
            NSArray *cached = slot.scan[base];
            if (progress) progress(1, 1, cached.count);
            return cached;
        }
        if (progress) {
            gScanProgress = [progress copy];
            gScanProgressIndex = baseIndex;
            gScanProgressOwner = owner;
        }
        BOOL joined = slot.group && [slot.demand join];
        if (!joined) {
            // A screen waiting for the result gets foreground priority; the
            // worker count stays at half the cores either way.
            qos_class_t qos = progress ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
            dispatch_group_t started = dispatch_group_create();
            NSMutableDictionary *startedBox = [NSMutableDictionary new];
            if (slot.group) {
                // A paused worker is still winding down. Its eventual result
                // must not overwrite the replacement worker's cache.
                slot.generation++;
                slot.scan = nil;

            }
            NSUInteger generation = slot.generation;
            dispatch_group_t previous = slot.group ?: slot.previous;
            slot.previous = nil;
            slot.group = started;
            slot.box = startedBox;
            slot.demand = [WQScanDemand new];
            [slot.demand join];
            WQScanDemand *workerDemand = slot.demand;
            dispatch_group_enter(started);
            dispatch_async(dispatch_get_global_queue(qos, 0), ^{
                // A worker detached by an invalidation finishes first.
                if (previous) dispatch_group_wait(previous, DISPATCH_TIME_FOREVER);
                NSDictionary *scan = nil;
                @try {
#ifdef WQ_ACCESS_TESTING
                    if (wq_test_shared_scan_runner) scan = wq_test_shared_scan_runner(inodeOnly);
                    else
#endif
                    scan = wq_run_shared_scan(fsid, qos, inodeOnly, workerDemand);
                } @catch (NSException *__unused exception) {

                }
                @synchronized (gSharedScanGuard) {
                    if (scan) {
                        startedBox[@"scan"] = scan;   // its own waiters asked before any invalidation
                        if (slot.generation == generation) {
                            slot.scan = scan;

                        }
                    }
                    if (slot.group == started) {
                        slot.group = nil;
                        slot.box = nil;
                    }
                }
                dispatch_group_leave(started);
            });
        }
        group = slot.group;
        box = slot.box;
        demand = slot.demand;
    }
    BOOL cancelled = NO;
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (cancellation.isCancelled) { cancelled = YES; break; }
    }
    [demand leave];
    NSArray<NSString *> *result = nil;
    @synchronized (gSharedScanGuard) {
        if (gScanProgressOwner == owner) { gScanProgress = nil; gScanProgressOwner = nil; }
        if (!cancelled) result = box[@"scan"][base];
    }
    return result;
}

NSArray<NSString *> *wq_enumerate(NSString *dir, int64_t maxInode, WQScanCancellation *cancellation,
                                  void (^progress)(int64_t, int64_t, NSUInteger))
{
    if (cancellation.isCancelled) return nil;
    NSString *base = wq_norm(dir);  // /private/var/... form
    struct stat baseStat = {0};
    int baseError = lstat(base.fileSystemRepresentation, &baseStat);
    if (baseError == 0 && !S_ISDIR(baseStat.st_mode)) {

        return nil;
    }
    if (baseError != 0 && errno != EACCES && errno != EPERM) {

        return nil;
    }
    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0) {
        // The container parent may not even be stat-able without a token. In
        // that case fall back to the data volume's fsid and let fsgetpath do
        // the work; a denied parent is not the same thing as a missing parent.
        if (statfs("/private/var/mobile", &sfs) != 0) {

            return nil;
        }
    }
    fsid_t fsid = sfs.f_fsid;
    BOOL dynamicBound = maxInode <= 0;
    if (dynamicBound && [wq_shared_scan_roots() containsObject:base])
        return wq_shared_children(base, fsid, cancellation, progress);
    // iOS 26: a full scan takes about 40 minutes; the LaunchServices database
    // lists the group containers of installed apps.
    if (dynamicBound && !wq_system_areas_reachable() && gContainerListProvider &&
        [base isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) {
        NSArray<NSString *> *all = gContainerListProvider(nil);
        if (all.count) {
            NSMutableArray *groups = [NSMutableArray new];
            for (NSString *path in all)
                if ([wq_norm(path).stringByDeletingLastPathComponent isEqualToString:base]) [groups addObject:wq_norm(path)];
            NSUInteger stale = 0;
            groups = [wq_existing_containers(groups, &stale) mutableCopy];
            [groups sortUsingSelector:@selector(compare:)];

            if (progress) progress(1, 1, groups.count);
            return groups;
        }
    }
    int64_t probeInode = 0;
    if (dynamicBound) {
        maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) {

            return nil;
        }
    }
    if (maxInode > INT64_MAX - 32768) {

        return nil;
    }
    WQScanCancellation *stop = nil;
    if (dynamicBound) {
        stop = wq_full_scan_begin(base.lastPathComponent, maxInode, wq_full_scan_estimate(maxInode, 0), cancellation,
                                  wq_scan_checkpoint_load(fsid, 1, maxInode, @[base]) != nil);
        if (!stop) return nil;   // declined: progress kept, the next attempt asks again
    }
    // Either the caller's cancellation or the scan window's Stop ends it.
    WQScanCancellation *either = stop ?: cancellation;
    if (stop && cancellation) {
        either = [WQScanCancellation new];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (!either.isCancelled) {
                if (stop.isCancelled || cancellation.isCancelled) { [either cancel]; break; }
                usleep(200000);
            }
        });
    }
    NSArray *lists = wq_scan_children(fsid, 1, maxInode, @[base], either, QOS_CLASS_USER_INITIATED, stop != nil,
        ^(int64_t done, int64_t total, const NSUInteger *counts) {
            if (progress) progress(done, total, counts[0]);
            if (stop && gFullScanProgress) gFullScanProgress(done, total, NO);
        }, nil);
    if (stop && stop.isCancelled) wq_scan_checkpoint_remove(@[base]);
    if (stop) { wq_full_scan_end(stop); [either cancel]; }
    if (!lists) return nil;

    return wq_sorted_paths(lists.firstObject);
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    if (!wq_is_denied(errno)) return NO;
    if (wq_grant(path.stringByDeletingLastPathComponent) && lstat(path.fileSystemRepresentation, st) == 0) return YES;
    return NO;
}

WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *cancellation, unsigned long long *bytes)
{
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    struct stat st = {0};
    if (!wq_stat(dir, &st)) {
        struct stat direct = {0};
        if (lstat(dir.fileSystemRepresentation, &direct) != 0 &&
            (errno == ENOENT || errno == ENOTDIR)) return WQMeasureResultMissing;
        return WQMeasureResultLimited;
    }
    if (!S_ISDIR(st.st_mode)) return WQMeasureResultLimited;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) wq_grant(dir);

    NSURL *root = [NSURL fileURLWithPath:dir isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
                                       NSURLFileSizeKey, NSURLIsDirectoryKey];
    __block BOOL limited = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:root includingPropertiesForKeys:keys options:0
           errorHandler:^BOOL(NSURL *__unused errorURL, NSError *__unused error) {
        limited = YES;

        return YES;
    }];
    if (!enumerator) return WQMeasureResultLimited;

    unsigned long long total = 0;
    for (NSURL *item in enumerator) {
        if (cancellation.isCancelled) return WQMeasureResultCancelled;
        NSNumber *isLink = nil, *isRegular = nil, *size = nil;
        NSError *error = nil;
        if (![item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:&error] ||
            ![item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:&error]) {
            limited = YES;
            continue;
        }
        if (isLink.boolValue || !isRegular.boolValue) continue;
        if (![item getResourceValue:&size forKey:NSURLFileSizeKey error:&error]) {
            limited = YES;
            continue;
        }
        total += size.unsignedLongLongValue;
    }
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    if (bytes) *bytes = total;
    return limited ? WQMeasureResultLimited : WQMeasureResultKnown;
}

static NSArray *wq_measure_identity(const struct stat *st)
{
    return @[@(st->st_dev), @(st->st_ino), @(st->st_birthtimespec.tv_sec), @(st->st_birthtimespec.tv_nsec)];
}

// Measurement progress is saved at most this often (the recovery tests save
// after every directory to cover a kill right after the first one).
// One trip to the mutation queue measures directories for up to this long
// (one directory per trip in the tests), so writes can still run in between
// without a queue hop for every directory.
#ifdef WQ_ACCESS_TESTING
static const NSTimeInterval kWQMeasureSaveInterval = 0;
static const NSTimeInterval kWQMeasureSlice = 0;
#else
static const NSTimeInterval kWQMeasureSaveInterval = 20.0;
static const NSTimeInterval kWQMeasureSlice = 0.05;
#endif

WQMeasureResult wq_measure_tree_resumable(NSString *dir, NSString *scope, NSString *taskID,
    WQScanCancellation *cancellation, unsigned long long *bytes, void (^performIO)(void (^work)(void)))
{
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    __block struct stat rootStat = {0};
    __block BOOL rootOK = NO;
    performIO(^{ rootOK = wq_stat(dir, &rootStat) && S_ISDIR(rootStat.st_mode); });
    if (!rootOK) return wq_measure_tree(dir, cancellation, bytes);
    NSArray *identity = wq_measure_identity(&rootStat);
    NSString *key = [NSString stringWithFormat:@"measure:%@:%@", scope, dir];
    NSDictionary *saved = WQScanJournalLoad(key);
    NSArray *pendingSaved = saved[@"pending"];
    BOOL valid = [saved[@"task"] isEqual:taskID] && [saved[@"identity"] isEqual:identity] &&
        [pendingSaved isKindOfClass:NSArray.class] && [saved[@"bytes"] isKindOfClass:NSNumber.class] &&
        [saved[@"bytes"] longLongValue] >= 0 && [saved[@"limited"] isKindOfClass:NSNumber.class];
    NSString *prefix = [dir stringByAppendingString:@"/"];
    for (id path in valid ? pendingSaved : @[]) {
        if (![path isKindOfClass:NSString.class] || ![path isEqual:[path stringByStandardizingPath]] ||
            (![path isEqual:dir] && ![path hasPrefix:prefix])) valid = NO;
    }
    NSMutableArray *pending = valid ? [pendingSaved mutableCopy] : [NSMutableArray arrayWithObject:dir];
    __block unsigned long long total = valid ? [saved[@"bytes"] unsignedLongLongValue] : 0;
    __block BOOL limited = valid && [saved[@"limited"] boolValue];

    // Small directories finish before the first save; a finished measurement
    // removes its journal.
    NSTimeInterval lastSave = NSDate.date.timeIntervalSinceReferenceDate;
    // Sandbox tokens are asked for sparingly: a token for the measured folder
    // covers its subfolders, so a denied subfolder gets at most a few tries per
    // measurement (a failed query isn't remembered by wq_grant and costs two
    // round trips under the global grant lock). EACCES is file permissions,
    // which no token changes.
    __block NSUInteger grantTries = 0;
    void (^noteLimit)(NSString *, int) = ^(NSString *what, int err) {
        limited = YES;
        (void)what;
        (void)err;
    };
    while (pending.count) {
        if (!wq_scan_wait(cancellation)) return WQMeasureResultCancelled;
        // A slice of directories per trip to the mutation queue. Never hold a
        // descriptor or a sandbox token across a saved checkpoint.
        performIO(^{
            CFAbsoluteTime sliceStart = CFAbsoluteTimeGetCurrent();
            do {
                if (cancellation.isCancelled) return;
                NSString *path = pending.lastObject;
                [pending removeLastObject];
                // Opened directly: the children come from this walk (lstat
                // types), so a component can only be a link after a swap, and
                // measuring never writes. Walking every path from "/" again
                // cost about ten opens per directory.
                BOOL isRoot = [path isEqualToString:dir];
                int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (fd < 0 && (isRoot ? wq_is_denied(errno) : errno == EPERM && grantTries < 3)) {
                    int denied = errno;
                    if (!isRoot) grantTries++;
                    if (wq_grant(path)) fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    else errno = denied;
                }
                // A subfolder removed since it was listed (crash logs and
                // caches change while they are measured) was simply not there.
                if (fd < 0 && !isRoot && (errno == ENOENT || errno == ENOTDIR)) continue;
                int openErr = errno;
                DIR *stream = fd >= 0 ? fdopendir(fd) : NULL;
                if (!stream) { if (fd >= 0) { openErr = errno; close(fd); } noteLimit(path, openErr); continue; }
                struct dirent *entry;
                errno = 0;
                while ((entry = readdir(stream))) {
                    if (cancellation.isCancelled) break;
                    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                    if (entry->d_type == DT_LNK) continue;
                    struct stat st;
                    if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                        int err = errno;
                        if (err == ENOENT) {}   // removed since it was listed
                        else noteLimit([path stringByAppendingPathComponent:@(entry->d_name)], err);
                        errno = 0;
                        continue;
                    }
                    if (S_ISREG(st.st_mode)) total += (unsigned long long)MAX((off_t)0, st.st_size);
                    else if (S_ISDIR(st.st_mode)) {
                        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
                        if (name) [pending addObject:[path stringByAppendingPathComponent:name]];
                    }
                    errno = 0;
                }
                if (errno) noteLimit(path, errno);
                closedir(stream);
            } while (pending.count && CFAbsoluteTimeGetCurrent() - sliceStart < kWQMeasureSlice);
        });
        if (cancellation.isCancelled) return WQMeasureResultCancelled;
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (pending.count && now - lastSave >= kWQMeasureSaveInterval) {
            (void)WQScanJournalSave(key, @{@"task": taskID, @"identity": identity, @"pending": pending,
                                         @"bytes": @(total), @"limited": @(limited)});
            lastSave = now;
        }
    }
    WQScanJournalRemove(key);
    if (bytes) *bytes = total;
    return limited ? WQMeasureResultLimited : WQMeasureResultKnown;
}

static BOOL wq_directory_current(NSString *path, int fd)
{
    int current = WQOpenDirectoryNoLinksFlags(path, O_SEARCH);
    struct stat a, b;
    BOOL ok = current >= 0 && fstat(current, &a) == 0 && fstat(fd, &b) == 0 && WQSameObject(&a, &b);
    if (current >= 0) close(current);
    return ok;
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation, BOOL (^validate)(void));

// Purge uses fd-relative removal, so the path is only a swap detector. One
// lstat is enough; reopening every ancestor for every child is needlessly
// expensive on large caches.
static BOOL wq_purge_root_matches(NSString *path, int fd)
{
    struct stat pathStat, fdStat;
    return lstat(path.fileSystemRepresentation, &pathStat) == 0 &&
           fstat(fd, &fdStat) == 0 && WQSameObject(&pathStat, &fdStat);
}

static BOOL wq_purge_fd(int fd, NSString *path, unsigned long long *freed, WQScanCancellation *cancellation, BOOL (^validate)(void))
{
    int listing = dup(fd);
    if (listing < 0) return NO;
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); return NO; }
    BOOL ok = YES;
    for (;;) {
        if (cancellation.isCancelled) { ok = NO; break; }
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = NO; break; }
        WQ_TREE_HOOK(@"purgeChild", path);
        // Fail closed on changed ancestry; all removal remains fd-relative even
        // in the final race window. Symlink children are unlinked, never followed.
        if ((validate && !validate()) || !wq_directory_current(path, fd)) { ok = NO; break; }
        if (!wq_remove_entry(fd, name, [path stringByAppendingPathComponent:name], freed, cancellation, validate)) {
            ok = NO;
            break;
        }
    }
    if (closedir(dir) != 0) ok = NO;
    return ok;
}

static BOOL wq_removal_current(int parent, const char *name, NSString *path, const struct stat *expected,
                               WQScanCancellation *cancellation, BOOL (^validate)(void))
{
    if (cancellation.isCancelled || (validate && !validate()) ||
        !wq_directory_current(path.stringByDeletingLastPathComponent, parent)) return NO;
    struct stat current;
    // Keep this identity check immediately before unlink, after validation
    // that can perform I/O. unlinkat has no atomic compare-inode operation.
    return fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        WQSameObject(expected, &current) && (expected->st_mode & S_IFMT) == (current.st_mode & S_IFMT);
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation, BOOL (^validate)(void))
{
    if (cancellation.isCancelled || (validate && !validate())) return NO;
    const char *item = name.fileSystemRepresentation;
    struct stat before, current;
    if (fstatat(parent, item, &before, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    BOOL directory = S_ISDIR(before.st_mode);
    if (directory) {
        int child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0 && wq_is_denied(errno) && wq_grant(path))
            child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0) return NO;
        BOOL ok = fstat(child, &current) == 0 && WQSameObject(&before, &current) &&
            wq_purge_root_matches(path, child) && wq_purge_fd(child, path, freed, cancellation, validate);
        close(child);
        if (!ok) return NO;
    }
    if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !WQSameObject(&before, &current) ||
        (current.st_mode & S_IFMT) != (before.st_mode & S_IFMT)) return NO;
    WQ_TREE_HOOK(@"purgeBeforeUnlink", path);
    if (!wq_removal_current(parent, item, path, &before, cancellation, validate)) return NO;
    int rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent)) {
        WQ_TREE_HOOK(@"purgeRetryUnlink", path);
        if (!wq_removal_current(parent, item, path, &before, cancellation, validate)) return NO;
        rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    }
    // A user-immutable or append-only flag (on the item or its folder) makes
    // unlink fail with EPERM even for the owner. The owner may clear those
    // flags, so clear them and try once more. System flags stay untouched.
    if (rc != 0 && errno == EPERM &&
        fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) == 0 && WQSameObject(&before, &current)) {
        if (!wq_removal_current(parent, item, path, &before, cancellation, validate)) return NO;
        const uint32_t userLocks = UF_IMMUTABLE | UF_APPEND;
        struct stat parentStat = {0};
        BOOL cleared = NO;
        if (fstat(parent, &parentStat) == 0 && (parentStat.st_flags & userLocks))
            cleared = fchflags(parent, parentStat.st_flags & ~userLocks) == 0;
        if ((current.st_flags & userLocks) && !S_ISLNK(current.st_mode)) {
            int flagsFd = openat(parent, item, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC |
                                 (directory ? O_DIRECTORY : 0));
            struct stat opened;
            if (flagsFd >= 0 && fstat(flagsFd, &opened) == 0 && WQSameObject(&before, &opened) &&
                fchflags(flagsFd, opened.st_flags & ~userLocks) == 0) cleared = YES;
            if (flagsFd >= 0) close(flagsFd);
        }
        if (cleared) {
            WQ_TREE_HOOK(@"purgeUnlockUnlink", path);
            if (!wq_removal_current(parent, item, path, &before, cancellation, validate)) return NO;
            rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
        } else {
            errno = EPERM;
        }
    }
    if (rc == 0 && !directory && freed) *freed += (unsigned long long)before.st_size;
    return rc == 0;
}

BOOL wq_purge_contents_validated(NSString *dir, unsigned long long *freed, WQScanCancellation *cancellation, BOOL (^validate)(void))
{
    if (cancellation.isCancelled) return NO;
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(dir))) return NO;
    int fd = wq_open_directory(dir);
    if (fd < 0) {
        if (errno == ENOENT) return validate == nil || validate();

        return NO;
    }
    BOOL ok = (validate == nil || validate()) && wq_directory_current(dir, fd) && wq_purge_fd(fd, dir, freed, cancellation, validate);
    if (ok) ok = (validate == nil || validate()) && wq_directory_current(dir, fd);
    close(fd);
    return ok;
}

// Container-manager enumeration is a second, permission-independent way to
// map a container path to its identifier. The enumeration pattern is the one
// used by terminal_worse (GPL-3.0); no part-domain traversal is involved. The UUID xattr and the root-only
// metadata plist are the fast paths; this query is the fallback for devices
// or containers where either is unavailable. Paths and identifiers stay in a
// short-lived cache because labels are requested for every row; it is
// rebuilt after an explicit refresh and its entries are identity-bound like
// the LaunchServices API labels.
static NSString *wq_container_identifier_lookup(NSString *key, WQLabelIdentity state, NSArray<NSNumber *> *current)
{
    static NSObject *lock;
    static NSDictionary<NSString *, NSString *> *cached;
    static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *identities;
    static NSTimeInterval cachedAt;
    static NSUInteger cachedGeneration;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        NSUInteger generation = atomic_load(&gWQLabelGeneration);
        if (!cached || now - cachedAt >= 60 || generation != cachedGeneration) {
        identities = [NSMutableDictionary new];

        NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary new];
        void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (mgr) {
            cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
            cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
            cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
            cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
            co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
            co_get_id_fn getIdentifier = (co_get_id_fn)dlsym(mgr, "container_object_get_identifier");
            if (!getIdentifier) getIdentifier = (co_get_id_fn)dlsym(mgr, "container_result_get_identifier");
            if (create && setClass && iterate && freeQuery && getPath) {
                const uint64_t classes[] = { 0, 2, 5, 7, 8, 10, 11, 13 };
                for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
                    void *query = create();
                    if (!query) continue;
                    setClass(query, classes[i]);
                    iterate(query, ^bool(void *object) {
                        if (!object) return true;
                        const char *path = getPath(object);
                        const char *ident = getIdentifier ? getIdentifier(object) : NULL;
                        if (!path || !path[0] || !ident || !ident[0]) return true;
                        NSString *p = [NSString stringWithUTF8String:path];
                        NSString *v = [NSString stringWithUTF8String:ident];
                        if (!p.length || !v.length) return true;
                        NSString *pathKey = WQCanonicalVarPath(p);
                        if (pathKey.length && !map[pathKey]) {
                            map[pathKey] = v;
                            NSArray<NSNumber *> *identity = nil;
                            if (wq_label_identity(pathKey, &identity) == WQLabelIdentityKnown) identities[pathKey] = identity;
                        }
                        return true;
                    });
                    freeQuery(query);
                }
            }
            dlclose(mgr);
        }
        cached = map;
        cachedAt = now;
        cachedGeneration = generation;
        }
        NSString *value = cached[key];
        if (!value.length) return nil;
        if (!wq_label_identity_matches(identities, key, state, current)) {

            return nil;
        }
        return value;
    }
}

static NSString *(*gContainerLabelResolver)(NSString *path);
static NSString *(*gGroupLabelResolver)(NSString *path);

void wq_set_group_label_resolver(NSString *(*resolver)(NSString *path))
{
    gGroupLabelResolver = resolver;
}

void wq_set_container_label_resolver(NSString *(*resolver)(NSString *path))
{
    gContainerLabelResolver = resolver;
}

NSString *wq_container_label(NSString *dir)
{
    char buf[512];
    ssize_t len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len > 0) {
        buf[len] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    // Reading the attribute can need a token on the container: ask, try again.
    if (wq_grant(dir)) {
        len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
        if (len > 0) {
            buf[len] = 0;
            return [NSString stringWithUTF8String:buf];
        }
        // iOS 27.2+: the identity attribute ("identifier: <id>" among others).
        char identity[2048];
        ssize_t n = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identity", identity, sizeof(identity), 0, 0);
        NSString *fromIdentity = n > 0 ? WQIdentityAttributeIdentifier([NSData dataWithBytes:identity length:(NSUInteger)n]) : nil;
        if (fromIdentity.length) return fromIdentity;
    }
    // Prefer the container-manager query over the metadata plist: it needs no
    // file permission and can also label containers whose plist is root-only.
    NSArray<NSNumber *> *identity = nil;
    WQLabelIdentity state = wq_label_identity(dir, &identity);
    NSString *fromAPI = nil;
    @synchronized (NSNull.null) {
        NSString *key = wq_norm(dir);
        fromAPI = gLSAPILabels[key];
        if (fromAPI.length && gLSAPIIdentities && !wq_label_identity_matches(gLSAPIIdentities, key, state, identity)) {

            fromAPI = nil;
        }
    }
    NSString *queried = wq_container_identifier_lookup(WQCanonicalVarPath(dir), state, identity);
    // Two caches that disagree about the same folder: trust neither.
    if (fromAPI.length && queried.length && ![fromAPI isEqualToString:queried]) {

    } else {
        if (fromAPI.length) return fromAPI;
        if (queried.length) return queried;
    }
    // The LaunchServices database maps app and extension data containers to
    // bundle ids (set by the app; this file doesn't depend on that module).
    NSString *resolved = gContainerLabelResolver ? gContainerLabelResolver(WQCanonicalVarPath(dir)) : nil;
    if (resolved.length) return resolved;
    // The metadata plist is usually root-only (mode 600); only try it when the
    // owner and mode let this app read it, rather than repeatedly requesting unreadable metadata.
    NSString *fromPlist = nil;
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    if (!wq_permission_hint(meta, NO)) {
        NSData *data = wq_read(meta, 256 * 1024, NULL);
        NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
        id ident = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
        if ([ident isKindOfClass:NSString.class] && [ident length]) fromPlist = ident;
    }
    // App Groups whose plist is root-only (issue #59): the group id the apps'
    // records in the LaunchServices database give this folder. The plist
    NSString *fromGroups = gGroupLabelResolver ? gGroupLabelResolver(WQCanonicalVarPath(dir)) : nil;
    if (fromPlist) return fromPlist;
    return fromGroups.length ? fromGroups : nil;
}

NSString *wq_access_capability_failure(void)
{
    if (!WQAccessVersionAllowed(NSProcessInfo.processInfo.operatingSystemVersion))
        return @"This iOS version is unsupported. Use iOS 26.0–26.7.2 or iOS 27.0–27.3 beta 1.";
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0) != 0)
        return @"The iOS build could not be checked. Access is disabled.";
    size_t count = strnlen(build, sizeof(build));
    NSString *identifier = count < sizeof(build) ? [[NSString alloc] initWithBytes:build length:count encoding:NSUTF8StringEncoding] : nil;
    if (!WQAccessBuildIdentifierValid(identifier))
        return @"The iOS build could not be checked. Access is disabled.";
    if (WQWorseQueryPatchedBuild(identifier))
        return @"This iOS build has patched the access technique. charony supports the upstream range through iOS 27.3 beta 1.";
    return nil;
}
