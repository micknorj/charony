// Native Icon Composer render checks; test-only, no application data access.
#import <AppKit/AppKit.h>
#import <stdio.h>
static double luminance(NSBitmapImageRep *image, NSInteger x, NSInteger y)
{
    NSColor *color = [[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return .2126 * color.redComponent + .7152 * color.greenComponent + .0722 * color.blueComponent;
}
int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 7) return 2;
        for (int i = 1; i < argc; i++) {
            NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithContentsOfFile:[NSString stringWithUTF8String:argv[i]]];
            if (!image || image.pixelsWide != 1024 || image.pixelsHigh != 1024) return 3;
            if (i <= 2) {
                // A buried detail layer rendered as a blank coin. Compare a
                // real crater with adjacent, equally lit moon surface.
                double pit = luminance(image, 369, 470);
                double surface = (luminance(image, 309, 470) + luminance(image, 429, 470)) / 2;
                if (!(surface - pit > .005)) {
                    fprintf(stderr, "Native moon crater is not visible in %s (contrast %.6f)\n", argv[i], surface - pit);
                    return 4;
                }
            }
        }
        puts("Native icon renders: dimensions and visible lunar detail passed");
    }
    return 0;
}
