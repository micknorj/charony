// Relevant English formatting coverage retained after translation removal.
#import "../WQLocalization.h"
#import <stdio.h>
#import <stdlib.h>
static void check(BOOL ok, const char *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
    printf("PASS: %s\n", name);
}
int main(void)
{
    @autoreleasepool {
        NSString *name = @"Date";
        check(WQLocalized(name) == name, "English keys remain verbatim");
        check(WQVerbatim(name) == name, "raw app names preserve identity");
        check(WQLocalizedNullable(nil) == nil && WQVerbatim(nil) == nil, "optional strings remain optional");
        check([WQLocalizedFormat(@"%@ · %lu · %.1f%%", name, (unsigned long)2, 3.5) isEqualToString:@"Date · 2 · 3.5%"],
              "format placeholders preserve types, order and percent escaping");
    }
    return 0;
}
