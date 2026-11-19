// Reuses WQ Files' validated no-backup purge. GPL-3.0-or-later.
#import "CHAppData.h"
#import "WQAccess.h"
#import "WQAccessSafety.h"
#import "WQAppsSupport.h"
#import "WQCacheSafety.h"

#ifdef WQ_ACCESS_TESTING
static NSString *CHTestApplicationRoot;
#endif

static BOOL CHAppContainerAllowed(NSString *container)
{
    NSString *base = @"/private/var/mobile/Containers/Data/Application";
#ifdef WQ_ACCESS_TESTING
    if (CHTestApplicationRoot) base = CHTestApplicationRoot;
#endif
    return WQAbsolutePathGrammar(container) &&
        [container.stringByDeletingLastPathComponent isEqualToString:base] &&
        [[NSUUID alloc] initWithUUIDString:container.lastPathComponent] != nil &&
        ![container isEqualToString:NSHomeDirectory().stringByResolvingSymlinksInPath] &&
        WQCacheSafetyHasNoSymlinkAncestry(container, NO);
}

BOOL CHClearAppData(NSString *container, NSString *bundleID, dev_t device, ino_t inode,
                    unsigned long long *freed, NSString **error)
{
    if (!CHAppContainerAllowed(container) || !WQAppsSupportBundleIDValid(bundleID) || !device || !inode) {
        if (error) *error = @"The selected app has no valid container identity or safe path.";
        return NO;
    }
    BOOL (^containerMatches)(void) = ^BOOL {
        struct stat current;
        return CHAppContainerAllowed(container) && wq_grant(container) &&
            lstat(container.fileSystemRepresentation, &current) == 0 && S_ISDIR(current.st_mode) &&
            current.st_dev == device && current.st_ino == inode &&
            [wq_container_label(container) isEqualToString:bundleID];
    };
    if (!containerMatches()) {
        if (error) *error = @"The app container changed or access was refused. Refresh before retrying.";
        return NO;
    }
    NSArray *parts = @[@"Documents", @"Library", @"tmp"];
    NSMutableDictionary *identities = [NSMutableDictionary new];
    for (NSString *part in parts) {
        NSString *path = [container stringByAppendingPathComponent:part];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0) {
            if (!S_ISDIR(st.st_mode) || !WQCacheSafetyTargetMatchesContainer(path, container, part)) {
                if (error) *error = @"An app-data folder is a link or has unsafe ancestry. Nothing was cleared.";
                return NO;
            }
            identities[part] = @[@(st.st_dev), @(st.st_ino)];
        } else if (errno != ENOENT) {
            if (error) *error = @"An app-data folder could not be inspected. Nothing was cleared.";
            return NO;
        }
    }
    BOOL (^selectedTargetsMatch)(void) = ^BOOL {
        if (!containerMatches()) return NO;
        for (NSString *part in parts) {
            NSString *path = [container stringByAppendingPathComponent:part];
            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) {
                if (errno == ENOENT && !identities[part]) continue;
                return NO;
            }
            NSArray *identity = identities[part];
            if (!identity || !S_ISDIR(st.st_mode) || st.st_dev != [identity[0] intValue] ||
                st.st_ino != [identity[1] unsignedLongLongValue] ||
                !WQCacheSafetyTargetMatchesContainer(path, container, part)) return NO;
        }
        return YES;
    };
    for (NSString *part in parts) {
        if (!selectedTargetsMatch() || !wq_purge_contents_validated(
                [container stringByAppendingPathComponent:part], freed, nil, selectedTargetsMatch)) {
            if (error) *error = @"Clearing stopped because access failed or data changed. Some data may already have been removed. Close the app and refresh before retrying.";
            return NO;
        }
    }
    // Keep the container and its part directories. Surface concurrent writes.
    for (NSString *part in parts) {
        if (!identities[part]) continue;
        NSError *listError = nil;
        NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[container stringByAppendingPathComponent:part] error:&listError];
        if (!remaining || remaining.count || !selectedTargetsMatch()) {
            if (error) *error = listError.localizedDescription ?: @"Data changed while clearing. Some contents remain.";
            return NO;
        }
    }
    if (!selectedTargetsMatch()) {
        if (error) *error = @"The selected app changed after clearing. Refresh before retrying.";
        return NO;
    }
    return YES;
}
