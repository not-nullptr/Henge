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
static id gGlobalRoute;

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

#pragma mark - phase 2: request global mouse events

static UIWindow *KeyWindow(void)
{
    UIWindow *best = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!best) best = w;
        }
    }
    return best;
}

// Logs hover / indirect-pointer events, which is what a successful
// requestGlobalMouseEvents... should start delivering.
static void LogEvent(UIEvent *event)
{
    static int count = 0;
    if (count >= 60) return;
    if (event.type != UIEventTypeHover && event.type != UIEventTypeTouches) return;

    BOOL interesting = (event.type == UIEventTypeHover);
    NSMutableString *touches = [NSMutableString string];
    for (UITouch *t in event.allTouches) {
        if (t.type == UITouchTypeIndirectPointer) interesting = YES;
        [touches appendFormat:@" %ld", (long)t.type];
    }
    if (!interesting) return;

    count++;
    Show(@"EVENT type=%ld touches=%@", (long)event.type, touches);
}

@implementation UIWindow (BKSProbeEvents)
+ (void)load
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method a = class_getInstanceMethod(self, @selector(sendEvent:));
        Method b = class_getInstanceMethod(self, @selector(bks_sendEvent:));
        if (a && b) method_exchangeImplementations(a, b);
    });
}
- (void)bks_sendEvent:(UIEvent *)event
{
    LogEvent(event);
    [self bks_sendEvent:event];
}
@end

static id CallRequestGlobalMouseEvents(NSMethodSignature *sig, id display, unsigned int ctx, id options)
{
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = gService;
    inv.selector = NSSelectorFromString(@"requestGlobalMouseEventsForDisplay:targetContextID:options:");

    const char *t2 = [sig getArgumentTypeAtIndex:2];
    if (t2[0] == '@') {
        [inv setArgument:&display atIndex:2];
    } else if (t2[0] == 'I' || t2[0] == 'i') {
        unsigned int did = (unsigned int)CGMainDisplayID();
        [inv setArgument:&did atIndex:2];
    } else if (t2[0] == 'Q' || t2[0] == 'q') {
        unsigned long long did = (unsigned long long)CGMainDisplayID();
        [inv setArgument:&did atIndex:2];
    } else {
        Show(@"phase2: unsupported display type %s", t2);
        return nil;
    }

    const char *t3 = [sig getArgumentTypeAtIndex:3];
    if (t3[0] == 'I' || t3[0] == 'i') {
        [inv setArgument:&ctx atIndex:3];
    } else if (t3[0] == 'Q' || t3[0] == 'q') {
        unsigned long long c = ctx;
        [inv setArgument:&c atIndex:3];
    } else {
        Show(@"phase2: unsupported context type %s", t3);
        return nil;
    }

    const char *t4 = [sig getArgumentTypeAtIndex:4];
    if (t4[0] == '@') {
        [inv setArgument:&options atIndex:4];
    } else if (t4[0] == 'I' || t4[0] == 'i') {
        unsigned int zero = 0;
        [inv setArgument:&zero atIndex:4];
    } else if (t4[0] == 'Q' || t4[0] == 'q') {
        unsigned long long zero = 0;
        [inv setArgument:&zero atIndex:4];
    } else {
        Show(@"phase2: unsupported options type %s", t4);
        return nil;
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        Show(@"phase2: exception %@", e);
        return nil;
    }

    if (sig.methodReturnType[0] == '@' && sig.methodReturnLength == sizeof(id)) {
        id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    }
    Show(@"phase2: return len=%lu type=%s",
         (unsigned long)sig.methodReturnLength, sig.methodReturnType);
    return nil;
}

static void RequestGlobalMouseEvents(void)
{
    if (!gService) return;

    SEL sel = NSSelectorFromString(@"requestGlobalMouseEventsForDisplay:targetContextID:options:");
    if (![gService respondsToSelector:sel]) {
        Show(@"phase2: selector absent");
        return;
    }
    NSMethodSignature *sig = [gService methodSignatureForSelector:sel];
    if (!sig) {
        Show(@"phase2: no signature");
        return;
    }
    Show(@"phase2: nargs=%lu ret=%s", (unsigned long)sig.numberOfArguments, sig.methodReturnType);
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        Show(@"phase2: arg%lu=%s", (unsigned long)i, [sig getArgumentTypeAtIndex:i]);
    }
    if (sig.numberOfArguments != 5) {
        Show(@"phase2: unexpected arg count");
        return;
    }

    UIWindow *window = KeyWindow();
    unsigned int ctx = 0;
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    if (window && [window respondsToSelector:ctxSel]) {
        ctx = ((unsigned int (*)(id, SEL))objc_msgSend)(window, ctxSel);
    }
    Show(@"phase2: window=%@ ctx=%u", window, ctx);
    if (!ctx) {
        Show(@"phase2: no context id, not calling");
        return;
    }

    Class dispCls = NSClassFromString(@"BKSHIDEventDisplay");
    id display = nil;
    SEL builtinSel = NSSelectorFromString(@"builtinDisplay");
    if (dispCls && [dispCls respondsToSelector:builtinSel]) {
        display = ((id (*)(id, SEL))objc_msgSend)(dispCls, builtinSel);
    }
    Show(@"phase2: display=%@", display);

    Show(@"phase2: calling requestGlobalMouseEvents (nil options)...");
    id ret = CallRequestGlobalMouseEvents(sig, display, ctx, nil);
    Show(@"phase2: return(nil opts)=%@", ret);

    if (!ret) {
        Class optCls = NSClassFromString(@"BKSMousePointerGlobalContextOptions");
        if (optCls) {
            id opts = [optCls new];
            Show(@"phase2: retrying with options=%@", opts);
            ret = CallRequestGlobalMouseEvents(sig, display, ctx, opts);
            Show(@"phase2: return(opts)=%@", ret);
        }
    }

    gGlobalRoute = ret;   // keep any route/assertion alive
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

    // Give phase 1 a few seconds to show whether the pointer is tracked, then
    // ask backboardd to route global mouse events to this window's context.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RequestGlobalMouseEvents();
    });
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
