// English presentation helpers. Derived from WQ Files, GPL-3.0-or-later.
#import "WQLocalization.h"
NSString *WQLocalized(NSString *text) { return text; }
NSString *WQLocalizedNullable(NSString *text) { return text; }
NSString *WQVerbatim(NSString *text) { return text; }
NSString *WQLocalizedFormat(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return text;
}
