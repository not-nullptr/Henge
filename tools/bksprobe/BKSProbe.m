//
//  BKSProbe.m
//  Henge / tools/bksprobe
//
//  A throwaway diagnostic tweak for the "external mouse on iPhone without
//  AssistiveTouch" question. It is injected into a guest app by LiveContainer's
//  TweakLoader and answers three things:
//
//    1. Is BackBoardServices' private BKSMousePointerService reachable from a
//       sandboxed app at all?
//    2. With AssistiveTouch OFF, does the service see the attached mouse
//       (addPointerDeviceObserver:) and does globalPointerPosition move?
//    3. What are the exact signatures of the interesting methods, so the next
//       step (requestGlobalMouseEventsForDisplay:targetContextID:options:) can
//       be called without guessing at ABI?
//
//  Nothing here touches the guest's own state. It only reads and logs.
//
//  Build: see README.md in this folder.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <GameController/GameController.h>
#import <math.h>
#import <string.h>

#define PROBE_TAG @"BKSProbe"

static NSMutableString *gLog;
static UILabel *gLabel;
static UIWindow *gWindow;
static id gService;
static id gObserver;
static id gObserverToken;
static NSString *gLogPath;
static BOOL gStarted;

static CGPoint gLastGlobal, gLastNormalized;
static BOOL gHaveGlobal, gHaveNormalized;
static NSInteger gLastMouseCount = -1;
static int gLastAT = -1;
static NSTimeInterval gLastTick;

#pragma mark - logging

static NSString *ProbeLogPath(void)
{
    if (gLogPath) return gLogPath;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) docs = NSTemporaryDirectory();
    gLogPath = [docs stringByAppendingPathComponent:@"BKSProbe.log"];
    return gLogPath;
}

// Safe from any thread: NSLog immediately, UI + file on the main queue.
static void Show(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line) return;

    NSLog(@"[%@] %@", PROBE_TAG, line);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLog) gLog = [NSMutableString new];
        [gLog appendFormat:@"%@\n", line];

        [gLog writeToFile:ProbeLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];

        if (gLabel) {
            NSArray<NSString *> *lines = [gLog componentsSeparatedByString:@"\n"];
            NSUInteger keep = 34;
            if (lines.count > keep) {
                gLog = [[lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)] componentsJoinedByString:@"\n"].mutableCopy;
            }
            gLabel.text = gLog;
        }
    });
}

#pragma mark - overlay

static BOOL EnsureOverlay(void)
{
    if (gWindow) return YES;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        scene = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) break;
    }
    if (!scene) return NO;

    gWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gWindow.windowLevel = UIWindowLevelAlert + 100;
    gWindow.userInteractionEnabled = NO;   // touches fall through to the guest
    gWindow.backgroundColor = UIColor.clearColor;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;

    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    label.textColor = UIColor.greenColor;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:4],
        [label.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:4],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-8],
    ]];

    gWindow.rootViewController = vc;
    gWindow.hidden = NO;
    gLabel = label;
    return YES;
}

#pragma mark - runtime helpers

static void DumpMethods(Class cls, NSString *title)
{
    if (!cls) {
        Show(@"--- %@: class not found", title);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Show(@"--- %@ (%u methods)", title, count);
    for (unsigned int i = 0; i < count; i++) {
        Show(@"M %@ %s %s", title,
             sel_getName(method_getName(methods[i])),
             method_getTypeEncoding(methods[i]));
    }
    free(methods);
}

static void DumpSig(NSString *name)
{
    SEL sel = NSSelectorFromString(name);
    if (![gService respondsToSelector:sel]) {
        Show(@"sig %@: absent", name);
        return;
    }
    NSMethodSignature *sig = [gService methodSignatureForSelector:sel];
    if (!sig) {
        Show(@"sig %@: no signature", name);
        return;
    }
    NSMutableString *args = [NSMutableString string];
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        [args appendFormat:@" %s", [sig getArgumentTypeAtIndex:i]];
    }
    Show(@"sig %@: ret=%s args=%@", name, sig.methodReturnType, args);
}

// Calls a no-argument getter through NSInvocation so a struct return can't
// corrupt the stack. Returns NO if the signature isn't a shape we understand.
static BOOL ReadPoint(NSString *name, CGPoint *out)
{
    SEL sel = NSSelectorFromString(name);
    if (![gService respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [gService methodSignatureForSelector:sel];
    if (!sig || sig.methodReturnLength == 0 || sig.methodReturnLength > 64) return NO;

    char buf[64] = {0};
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = gService;
    inv.selector = sel;
    [inv invoke];
    [inv getReturnValue:buf];

    const char *rt = sig.methodReturnType;
    if (strcmp(rt, @encode(CGPoint)) == 0 || (rt[0] == '{' && sig.methodReturnLength == sizeof(CGPoint))) {
        memcpy(out, buf, sizeof(CGPoint));
        return YES;
    }
    if (strcmp(rt, @encode(double)) == 0) {
        double d = 0;
        memcpy(&d, buf, sizeof(d));
        out->x = out->y = d;
        return YES;
    }
    return NO;
}

#pragma mark - device observer

@interface LCProbeObserver : NSObject
@end

@implementation LCProbeObserver
- (void)mousePointerDevicesDidChange:(NSSet *)devices
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id d in devices) [names addObject:[d description]];
    Show(@"devices(%lu): %@", (unsigned long)devices.count,
         names.count ? [names componentsJoinedByString:@" | "] : @"(none)");
}
@end

#pragma mark - poll

static void Poll(void)
{
    if (!gService) return;

    CGPoint p = CGPointZero;
    if (ReadPoint(@"globalPointerPosition", &p)) {
        if (!gHaveGlobal || fabs(p.x - gLastGlobal.x) > 0.5 || fabs(p.y - gLastGlobal.y) > 0.5) {
            Show(@"globalPointerPosition = (%.1f, %.1f)", p.x, p.y);
            gLastGlobal = p;
            gHaveGlobal = YES;
        }
    }
    if (ReadPoint(@"normalizedGlobalPointerPosition", &p)) {
        if (!gHaveNormalized || fabs(p.x - gLastNormalized.x) > 0.001 || fabs(p.y - gLastNormalized.y) > 0.001) {
            Show(@"normalizedGlobalPointerPosition = (%.4f, %.4f)", p.x, p.y);
            gLastNormalized = p;
            gHaveNormalized = YES;
        }
    }

    NSInteger mice = (NSInteger)[GCMouse mice].count;
    if (mice != gLastMouseCount) {
        Show(@"GCMouse.mice.count = %ld (current=%@)", (long)mice,
             [GCMouse current] ? @"yes" : @"no");
        gLastMouseCount = mice;
    }

    int at = UIAccessibilityIsAssistiveTouchRunning() ? 1 : 0;
    if (at != gLastAT) {
        Show(@"AssistiveTouch running = %@", at ? @"YES" : @"NO");
        gLastAT = at;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastTick > 5.0) {
        gLastTick = now;
        Show(@"tick: service=%@ mice=%ld AT=%@",
             gService ? @"ok" : @"nil", (long)mice, at ? @"YES" : @"NO");
    }
}

#pragma mark - start

static void Start(void)
{
    if (gStarted) return;
    gStarted = YES;

    Show(@"%@ v1 on %@ %@ (idiom %ld)", PROBE_TAG,
         UIDevice.currentDevice.systemName,
         UIDevice.currentDevice.systemVersion,
         (long)UIDevice.currentDevice.userInterfaceIdiom);
    Show(@"bundle: %@", NSBundle.mainBundle.bundleIdentifier);
    Show(@"overlay: %@", gWindow ? @"yes" : @"no");
    Show(@"log: %@", ProbeLogPath());

    void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    if (!handle) {
        Show(@"dlopen BackBoardServices FAILED: %s", dlerror());
    } else {
        Show(@"dlopen BackBoardServices = ok");
    }

    Class cls = NSClassFromString(@"BKSMousePointerService");
    Show(@"BKSMousePointerService class = %@", cls);
    if (!cls) return;

    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sharedSel]) {
        Show(@"sharedInstance: absent");
        return;
    }
    gService = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
    Show(@"sharedInstance = %@", gService);
    if (!gService) return;

    DumpMethods(cls, @"BKSMousePointerService");
    DumpMethods(NSClassFromString(@"BKSMousePointerGlobalContextOptions"), @"BKSMousePointerGlobalContextOptions");
    DumpMethods(NSClassFromString(@"BKSMousePointerDevice"), @"BKSMousePointerDevice");

    for (NSString *name in @[
             @"globalPointerPosition",
             @"normalizedGlobalPointerPosition",
             @"setGlobalPointerPosition:",
             @"addPointerDeviceObserver:",
             @"requestGlobalMouseEventsForDisplay:targetContextID:options:",
             @"requestGlobalMouseEventsForDisplay:targetContextID:",
             @"pointerSuppressionAssertionOnDisplay:forReason:withOptionsMask:",
             @"globalDevicePreferences",
             @"setGlobalDevicePreferences:",
         ]) {
        DumpSig(name);
    }

    SEL addSel = NSSelectorFromString(@"addPointerDeviceObserver:");
    if ([gService respondsToSelector:addSel]) {
        gObserver = [LCProbeObserver new];
        gObserverToken = ((id (*)(id, SEL, id))objc_msgSend)(gService, addSel, gObserver);
        Show(@"observer token = %@", gObserverToken);
    } else {
        Show(@"addPointerDeviceObserver: absent");
    }

    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        Poll();
    }];
}

#pragma mark - entry

__attribute__((constructor))
static void BKSProbeInit(void)
{
    // The tweak is dlopen'd before the guest's UIApplicationMain. Touch UIKit
    // only after the main queue starts draining, and wait for a window scene.
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int tries = 0;
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            if (gStarted) {
                [timer invalidate];
                return;
            }
            tries++;
            // Wait for a window scene so the overlay can attach, but do not
            // wait forever: the file log is useful without it.
            if (EnsureOverlay() || tries >= 10) {
                [timer invalidate];
                Start();
            }
        }];
    });
}
