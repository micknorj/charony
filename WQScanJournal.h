// Durable, app-private scan state. Never stores sandbox tokens or file contents.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <unistd.h>
#import <dirent.h>
#import <string.h>
#import "WQAccessSafety.h"

NS_ASSUME_NONNULL_BEGIN
static inline NSString *WQScanJournalDirectory(void)
{
#ifdef WQ_ACCESS_TESTING
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"scan-journal"];
#else
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"ScanTasks"];
#endif
}
static inline NSString *WQScanJournalPath(NSString *key)
{
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return [WQScanJournalDirectory() stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}
static inline NSDictionary *_Nullable WQScanJournalReadAt(int directory, NSString *name)
{
    int fd = WQOpenRegularAt(directory, name.fileSystemRepresentation, O_RDONLY, 0);
    if (fd < 0) return nil;
    NSMutableData *data = [NSMutableData new];
    uint8_t buffer[65536];
    BOOL ok = YES;
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = NO; break; }
        if (!count) break;
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(fd);
    if (!ok) return nil;
    id envelope = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    return [envelope isKindOfClass:NSDictionary.class] ? envelope : nil;
}
static inline NSArray<NSString *> *_Nullable WQScanJournalEntries(int directory)
{
    int listing = dup(directory);
    if (listing < 0) return nil;
    DIR *stream = fdopendir(listing);
    if (!stream) { close(listing); return nil; }
    NSMutableArray *names = [NSMutableArray new];
    BOOL ok = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = NO; break; }
        [names addObject:name];
    }
    if (closedir(stream) != 0) ok = NO;
    return ok ? names : nil;
}
static inline NSDictionary *_Nullable WQScanJournalLoad(NSString *key)
{
    int directory = WQOpenDirectoryNoLinks(WQScanJournalDirectory());
    if (directory < 0) return nil;
    NSDictionary *envelope = WQScanJournalReadAt(directory, WQScanJournalPath(key).lastPathComponent);
    close(directory);
    if (![envelope[@"version"] isEqual:@1] || ![envelope[@"key"] isEqual:key] ||
        ![envelope[@"value"] isKindOfClass:NSDictionary.class]) return nil;
    return envelope[@"value"];
}
static inline BOOL WQScanJournalFailed(NSString *key)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"WQScanJournalWriteFailed" object:key];
    });
    return NO;
}
static inline BOOL WQScanJournalSave(NSString *key, NSDictionary *value)
{
    NSString *path = WQScanJournalDirectory();
    int directory = WQCreateDirectoriesNoLinks(path);
    if (directory < 0) return WQScanJournalFailed(key);
    NSURL *url = [NSURL fileURLWithPath:path];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSDictionary *envelope = @{@"version": @1, @"key": key, @"value": value};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:envelope format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *temporary = [@".checkpoint-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = data ? WQOpenRegularAt(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600) : -1;
    BOOL ok = fd >= 0 && WQWriteBytes(fd, data);
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (ok) ok = renameat(directory, temporary.fileSystemRepresentation, directory,
                          WQScanJournalPath(key).lastPathComponent.fileSystemRepresentation) == 0 && WQSyncDirectory(directory);
    unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    return ok ? YES : WQScanJournalFailed(key);
}
static inline BOOL WQScanJournalRemove(NSString *key)
{
    int directory = WQOpenDirectoryNoLinks(WQScanJournalDirectory());
    if (directory < 0) return errno == ENOENT ? YES : WQScanJournalFailed(key);
    // Never follow a swapped ancestor or recursively remove unexpected state.
    BOOL ok = unlinkat(directory, WQScanJournalPath(key).lastPathComponent.fileSystemRepresentation, 0) == 0 || errno == ENOENT;
    if (ok) ok = WQSyncDirectory(directory);
    close(directory);
    return ok ? YES : WQScanJournalFailed(key);
}
// Remove stale owned journal files through the pinned directory.
static inline void WQScanJournalPrune(NSTimeInterval age)
{
    int directory = WQOpenDirectoryNoLinks(WQScanJournalDirectory());
    if (directory < 0) return;
    for (NSString *name in WQScanJournalEntries(directory)) {
        struct stat st;
        if (fstatat(directory, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(st.st_mode)) continue;
        // Startup runs before writers exist. A staged UUID file left by a
        // killed writer cannot be resumed and can be discarded immediately.
        NSString *prefix = @".checkpoint-";
        if ([name hasPrefix:prefix] && [[NSUUID alloc] initWithUUIDString:[name substringFromIndex:prefix.length]]) {
            if (unlinkat(directory, name.fileSystemRepresentation, 0) != 0 && errno != ENOENT)
                WQScanJournalFailed(@"task:apps");
            continue;
        }
        if (NSDate.date.timeIntervalSince1970 - st.st_mtimespec.tv_sec <= age) continue;
        NSDictionary *envelope = WQScanJournalReadAt(directory, name);
        NSString *key = envelope[@"key"];
        if ([key isKindOfClass:NSString.class] && [envelope[@"version"] isEqual:@1] &&
            [name isEqualToString:WQScanJournalPath(key).lastPathComponent]) unlinkat(directory, name.fileSystemRepresentation, 0);
    }
    WQSyncDirectory(directory);
    close(directory);
}
static inline BOOL WQScanJournalRemoveScope(NSString *scope)
{
    int directory = WQOpenDirectoryNoLinks(WQScanJournalDirectory());
    NSString *failureKey = [@"task:" stringByAppendingString:scope];
    if (directory < 0) return errno == ENOENT ? YES : WQScanJournalFailed(failureKey);
    NSArray *names = WQScanJournalEntries(directory);
    BOOL ok = names != nil;
    NSString *prefix = [NSString stringWithFormat:@"measure:%@:", scope];
    for (NSString *name in names) {
        NSDictionary *envelope = WQScanJournalReadAt(directory, name);
        NSString *key = envelope[@"key"];
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:prefix] &&
            [name isEqualToString:WQScanJournalPath(key).lastPathComponent] &&
            unlinkat(directory, name.fileSystemRepresentation, 0) != 0 && errno != ENOENT) ok = NO;
    }
    if (!WQSyncDirectory(directory)) ok = NO;
    close(directory);
    return ok ? YES : WQScanJournalFailed(failureKey);
}
// Run before task workers are created. Remove completed legacy state even
// for a tab the user has not opened, and retain only unfinished task flags.
static inline BOOL WQScanJournalPrepareKnownTasks(void)
{
    BOOL ok = YES;
    for (NSString *scope in @[@"apps", @"clean"]) {
        NSString *key = [@"task:" stringByAppendingString:scope];
        NSDictionary *saved = WQScanJournalLoad(key);
        if (![saved[@"unfinished"] isEqual:@YES]) {
            if (!WQScanJournalRemoveScope(scope)) ok = NO;
            if (!WQScanJournalRemove(key)) ok = NO;
            continue;
        }
        NSString *identifier = [saved[@"identifier"] isKindOfClass:NSString.class] ? saved[@"identifier"] : NSUUID.UUID.UUIDString;
        NSDictionary *minimal = @{@"identifier": identifier, @"unfinished": @YES,
                                   @"userPaused": @([saved[@"userPaused"] isEqual:@YES])};
        if (!WQScanJournalSave(key, minimal)) ok = NO;
    }
#ifdef WQ_ACCESS_TESTING
    NSString *cacheDirectory = NSTemporaryDirectory();
#else
    NSString *cacheDirectory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
#endif
    int cache = WQOpenDirectoryNoLinks(cacheDirectory);
    if (cache < 0) {
        if (errno != ENOENT) { WQScanJournalFailed(@"task:apps"); ok = NO; }
    } else {
        if (unlinkat(cache, "wq-container-scan.plist", 0) != 0 && errno != ENOENT) {
            WQScanJournalFailed(@"task:apps");
            ok = NO;
        }
        close(cache);
    }
    return ok;
}
static inline NSDictionary *WQScanEncode(id object, NSArray<NSString *> *keys)
{
    NSMutableDictionary *row = [NSMutableDictionary new];
    for (NSString *key in keys) { id value = [object valueForKey:key]; if (value) row[key] = value; }
    return row;
}
static inline void WQScanDecode(id object, NSDictionary *row, NSArray<NSString *> *strings, NSArray<NSString *> *numbers)
{
    for (NSString *key in strings) if ([row[key] isKindOfClass:NSString.class]) [object setValue:row[key] forKey:key];
    for (NSString *key in numbers) if ([row[key] isKindOfClass:NSNumber.class]) [object setValue:row[key] forKey:key];
}
NS_ASSUME_NONNULL_END
