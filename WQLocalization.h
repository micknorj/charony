// English presentation compatibility helpers for retained WQ Files code.
// GPL-3.0-or-later.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
NSString *WQLocalized(NSString *text);
NSString *_Nullable WQLocalizedNullable(NSString *_Nullable text);
NSString *WQLocalizedFormat(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *_Nullable WQVerbatim(NSString *_Nullable text);
NS_ASSUME_NONNULL_END
