#import <Foundation/Foundation.h>
static inline BOOL WQAppsSupportBundleIDValid(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length < 3 || bundleID.length > 255) return NO;
    if ([bundleID hasPrefix:@"."] || [bundleID hasSuffix:@"."] || [bundleID containsString:@".."]) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    // Some established apps use single-word identifiers (for example,
    // pinterest). Keep the character/path guards without requiring a dot.
    return [bundleID rangeOfCharacterFromSet:bad].location == NSNotFound;
}
