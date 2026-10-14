// capeapply — apply a Mousecape .cape file as the system cursor theme.
//
//   capeapply <file.cape>          apply once and exit
//   capeapply --watch <file.cape>  apply, then re-apply after every display
//                                  reconfiguration and console-user switch
//
// macOS has no public API for replacing system cursors. This talks to
// WindowServer through the same private CoreGraphics (SkyLight) calls
// Mousecape uses; signatures are taken from Mousecape's CGSInternal headers
// (github.com/sdmj76/Mousecape-swiftUI, mousecloak/apply.m, listen.m).
// Registrations are per login session: they survive this process exiting
// but vanish at logout, and WindowServer can drop them on display changes —
// hence --watch.
//
// Originally written by kgoh (github.com/KGOH).

#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>

typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSRegisterCursorWithImages(CGSConnectionID cid, const char *name,
    bool setGlobally, bool instantly, CGSize size, CGPoint hotSpot,
    NSUInteger frameCount, CGFloat frameDuration, CFArrayRef images, int *seed);
extern char *CGSCursorNameForSystemCursor(int cursorID);
extern void CGSSetDockCursorOverride(CGSConnectionID cid, bool flag);

// WindowServer rejects hot spots outside [0, 32) with CGError 1000.
static const CGFloat kMaxHotSpot = 31.99;
static const NSUInteger kMaxFrames = 24;

static NSString *capePath;

// On Tahoe the arrow and I-beam are looked up under more names than the
// legacy com.apple.coregraphics.* ones; register the cape's image under
// every system cursor name that contains the keyword.
static NSArray<NSString *> *synonyms(NSArray<NSString *> *legacy, NSString *keyword) {
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:legacy];
    for (int i = 0; i < 128; i++) {
        char *c = CGSCursorNameForSystemCursor(i);
        if (!c || !*c) continue;
        NSString *name = @(c);
        if ([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound)
            [set addObject:name];
    }
    return set.array;
}

static NSArray<NSString *> *namesFor(NSString *ident) {
    static NSArray *arrow, *ibeam;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        arrow = synonyms(@[@"com.apple.coregraphics.Arrow", @"com.apple.coregraphics.ArrowCtx"], @"arrow");
        ibeam = synonyms(@[@"com.apple.coregraphics.IBeam", @"com.apple.coregraphics.IBeamXOR"], @"ibeam");
    });
    if ([arrow containsObject:ident]) return arrow;
    if ([ibeam containsObject:ident]) return ibeam;
    return @[ident];
}

static BOOL applyCursor(NSString *ident, NSDictionary *c, BOOL animate) {
    NSUInteger frames = [c[@"FrameCount"] unsignedIntegerValue];
    CGFloat duration = [c[@"FrameDuration"] doubleValue];
    CGPoint hot = CGPointMake(MIN(MAX([c[@"HotSpotX"] doubleValue], 0), kMaxHotSpot),
                              MIN(MAX([c[@"HotSpotY"] doubleValue], 0), kMaxHotSpot));
    CGSize size = CGSizeMake([c[@"PointsWide"] doubleValue], [c[@"PointsHigh"] doubleValue]);

    if (frames < 1 || frames > kMaxFrames) {
        fprintf(stderr, "%s: frame count %lu out of range\n", ident.UTF8String, (unsigned long)frames);
        return NO;
    }

    // Representations are PNG/TIFF blobs, one per pixel density; each is a
    // vertical sprite sheet of `frames` frames.
    NSMutableArray *images = [NSMutableArray array];
    for (NSData *data in c[@"Representations"]) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
        if (!rep) continue;
        NSColorSpace *space = rep.colorSpace.numberOfColorComponents == 1
            ? NSColorSpace.genericGamma22GrayColorSpace : NSColorSpace.sRGBColorSpace;
        CGImageRef img = [rep bitmapImageRepByRetaggingWithColorSpace:space].CGImage;
        if (!img) continue;
        if (!animate && frames > 1) {
            size_t h = CGImageGetHeight(img) / frames;
            CGImageRef first = CGImageCreateWithImageInRect(img, CGRectMake(0, 0, CGImageGetWidth(img), h));
            [images addObject:(__bridge_transfer id)first];
        } else {
            [images addObject:(__bridge id)img];
        }
    }
    if (images.count == 0) return NO;
    if (!animate) frames = 1;

    BOOL ok = NO;
    for (NSString *name in namesFor(ident)) {
        int seed = 0;
        CGError err = CGSRegisterCursorWithImages(CGSMainConnectionID(), name.UTF8String,
            true, true, size, hot, frames, duration, (__bridge CFArrayRef)images, &seed);
        if (err == kCGErrorSuccess) ok = YES;
        else fprintf(stderr, "%s: CGSRegisterCursorWithImages failed (%d)\n", name.UTF8String, err);
    }
    return ok;
}

static BOOL applyCape(void) {
    @autoreleasepool {
        NSDictionary *cape = [NSDictionary dictionaryWithContentsOfFile:capePath];
        NSDictionary *cursors = cape[@"Cursors"];
        if (!cursors) {
            fprintf(stderr, "%s: not a valid cape\n", capePath.UTF8String);
            return NO;
        }
        BOOL animate = cape[@"Animate"] ? [cape[@"Animate"] boolValue] : YES;

        NSUInteger ok = 0;
        for (NSString *ident in cursors)
            if (applyCursor(ident, cursors[ident], animate)) ok++;
        // Keeps the Dock from immediately putting its own arrow back.
        CGSSetDockCursorOverride(CGSMainConnectionID(), false);

        fprintf(stderr, "applied %lu/%lu cursors from %s\n",
                (unsigned long)ok, (unsigned long)cursors.count, [cape[@"CapeName"] UTF8String]);
        return ok > 0;
    }
}

static void displayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *info) {
    // Each reconfiguration fires a Begin callback and then one per display;
    // only the post-change ones matter. Coalesce them into a single apply.
    static BOOL pending = NO;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        applyCape();
    });
}

static void consoleUserChanged(SCDynamicStoreRef store, CFArrayRef keys, void *info) {
    CFStringRef user = SCDynamicStoreCopyConsoleUser(store, NULL, NULL);
    if (user && CFEqual(user, (__bridge CFStringRef)NSUserName())) applyCape();
    if (user) CFRelease(user);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL watch = argc == 3 && strcmp(argv[1], "--watch") == 0;
        if (!(argc == 2 && argv[1][0] != '-') && !watch) {
            fprintf(stderr, "usage: capeapply [--watch] <file.cape>\n");
            return 2;
        }
        capePath = @(argv[argc - 1]);

        // Establishes the WindowServer connection CGSMainConnectionID refers to.
        NSApplicationLoad();

        BOOL ok = applyCape();
        if (!watch) return ok ? 0 : 1;

        CGDisplayRegisterReconfigurationCallback(displayChanged, NULL);

        SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("capeapply"), consoleUserChanged, NULL);
        CFStringRef key = SCDynamicStoreKeyCreateConsoleUser(NULL);
        SCDynamicStoreSetNotificationKeys(store, (__bridge CFArrayRef)@[(__bridge id)key], NULL);
        CFRelease(key);
        CFRunLoopSourceRef src = SCDynamicStoreCreateRunLoopSource(NULL, store, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);

        CFRunLoopRun();
    }
    return 0;
}
