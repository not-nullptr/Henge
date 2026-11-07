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
static BOOL gRouteCreated;
static int gGCMouseLogCount;
static id gGlobalRoute;
static NSMutableArray *gGlobalRoutes;

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

// Safe from any thread. The file write is synchronous so the last line is on
// disk even if the very next call kills the process.
static void Show(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line) return;

    NSLog(@"[%@] %@", PROBE_TAG, line);

    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });

    [lock lock];
    if (!gLog) gLog = [NSMutableString new];
    [gLog appendFormat:@"%@\n", line];
    [gLog writeToFile:ProbeLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSArray<NSString *> *lines = [gLog componentsSeparatedByString:@"\n"];
    NSUInteger keep = 34;
    NSString *text = lines.count > keep
        ? [[lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)] componentsJoinedByString:@"\n"]
        : [gLog copy];
    [lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLabel) gLabel.text = text;
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
    // The scene can appear after Start(); attach the overlay whenever it does.
    if (!gWindow) EnsureOverlay();
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
    if (!gStarted || !event) return;
    if (count >= 200) return;

    NSMutableString *touches = [NSMutableString string];
    BOOL interesting = (event.type == UIEventTypeHover);
    for (UITouch *t in event.allTouches) {
        if (t.type == UITouchTypeIndirectPointer) interesting = YES;
        [touches appendFormat:@" %ld", (long)t.type];
    }

    // Before the route, only hover / indirect-pointer events matter. After it,
    // log every event type so we can see what (if anything) arrives.
    if (!gRouteCreated) {
        if (event.type != UIEventTypeHover && event.type != UIEventTypeTouches) return;
        if (!interesting) return;
    }

    count++;
    Show(@"EVENT type=%ld touches=%@", (long)event.type, touches);
}

@implementation UIWindow (BKSProbeEvents)
- (void)bks_sendEvent:(UIEvent *)event
{
    LogEvent(event);
    [self bks_sendEvent:event];
}
@end

@implementation UIApplication (BKSProbeEvents)
- (void)bks_sendEvent:(UIEvent *)event
{
    LogEvent(event);
    [self bks_sendEvent:event];
}
@end

// Installed only after the overlay is up, so a bad swizzle can never break
// the app's startup.
static void InstallEventLogger(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method a = class_getInstanceMethod(UIWindow.class, @selector(sendEvent:));
        Method b = class_getInstanceMethod(UIWindow.class, @selector(bks_sendEvent:));
        if (a && b) method_exchangeImplementations(a, b);

        Method c = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
        Method d = class_getInstanceMethod(UIApplication.class, @selector(bks_sendEvent:));
        if (c && d) method_exchangeImplementations(c, d);
    });
}

// Wraps whatever handler the guest already installed, so Henge keeps working
// and we still see whether deltas start arriving after the route.
static void InstallGCMouseLogging(void)
{
    for (GCMouse *mouse in [GCMouse mice]) {
        GCMouseInput *input = mouse.mouseInput;
        if (!input) continue;

        void (^oldMoved)(GCMouseInput *, float, float) = input.mouseMovedHandler;
        input.mouseMovedHandler = ^(GCMouseInput *m, float dx, float dy) {
            if (gGCMouseLogCount++ < 40) Show(@"GCMOUSE move %.2f %.2f", dx, dy);
            if (oldMoved) oldMoved(m, dx, dy);
        };

        void (^oldLeft)(GCControllerButtonInput *, float, BOOL) = input.leftButton.pressedChangedHandler;
        input.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
            if (gGCMouseLogCount++ < 40) Show(@"GCMOUSE left %d", pressed);
            if (oldLeft) oldLeft(b, v, pressed);
        };

        void (^oldRight)(GCControllerButtonInput *, float, BOOL) = input.rightButton.pressedChangedHandler;
        input.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
            if (gGCMouseLogCount++ < 40) Show(@"GCMOUSE right %d", pressed);
            if (oldRight) oldRight(b, v, pressed);
        };

        Show(@"GCMOUSE wrapped %@", mouse.vendorName);
    }
}

static id CallRequestGlobalMouseEvents(NSMethodSignature *sig, SEL sel, id display, unsigned int ctx, id options)
{
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = gService;
    inv.selector = sel;

    // Arg 2: BKSHIDEventDisplay *
    const char *t2 = [sig getArgumentTypeAtIndex:2];
    if (t2[0] != '@') {
        Show(@"phase2: unsupported display type %s", t2);
        return nil;
    }
    [inv setArgument:&display atIndex:2];

    // Arg 3: unsigned int context id
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

    // Arg 4 (3-arg variant only): BKSMousePointerGlobalContextOptions *
    if (sig.numberOfArguments > 4) {
        const char *t4 = [sig getArgumentTypeAtIndex:4];
        if (t4[0] != '@') {
            Show(@"phase2: unsupported options type %s", t4);
            return nil;
        }
        [inv setArgument:&options atIndex:4];
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        Show(@"phase2: exception %@", e);
        return nil;
    }

    if (sig.methodReturnType[0] == '@' && sig.methodReturnLength == sizeof(id)) {
        // getReturnValue: writes the pointer without a retain. A plain `id`
        // here would make ARC release an object it does not own, over-releasing
        // the BSCompoundAssertion acquisition and trapping in its dealloc.
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    }
    Show(@"phase2: return len=%lu type=%s",
         (unsigned long)sig.methodReturnLength, sig.methodReturnType);
    return nil;
}

static NSString *AsString(id value)
{
    if (!value) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSUUID class]]) return [(NSUUID *)value UUIDString];
    return [value description];
}

static void AddCandidate(NSMutableArray<NSString *> *list, id value, NSString *label)
{
    NSString *s = AsString(value);
    Show(@"phase2: candidate %@ = %@", label, s);
    if (s.length && ![list containsObject:s]) [list addObject:s];
}

static NSArray<NSNumber *> *ContextIDCandidates(UIWindow *window)
{
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    SEL ctxSel = NSSelectorFromString(@"_contextId");

    if ([window respondsToSelector:ctxSel]) {
        unsigned int c = ((unsigned int (*)(id, SEL))objc_msgSend)(window, ctxSel);
        Show(@"phase2: window _contextId=%u", c);
        if (c) [ids addObject:@(c)];
    }

    UIScene *scene = window.windowScene;
    if (!scene) return ids;

    if ([scene respondsToSelector:ctxSel]) {
        unsigned int c = ((unsigned int (*)(id, SEL))objc_msgSend)(scene, ctxSel);
        Show(@"phase2: scene _contextId=%u", c);
        if (c && ![ids containsObject:@(c)]) [ids addObject:@(c)];
    }

    @try {
        id fbs = [scene valueForKey:@"_FBSScene"];
        Show(@"phase2: _FBSScene=%@", fbs);
        if (fbs) {
            for (NSString *key in @[@"contextID", @"_contextID", @"contextId"]) {
                @try {
                    id v = [fbs valueForKey:key];
                    Show(@"phase2: _FBSScene.%@=%@", key, v);
                    if ([v respondsToSelector:@selector(unsignedIntValue)]) {
                        unsigned int c = [v unsignedIntValue];
                        if (c && ![ids containsObject:@(c)]) [ids addObject:@(c)];
                    }
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}

    @try {
        id binder = [scene valueForKey:@"_contextBinder"];
        Show(@"phase2: _contextBinder=%@", binder);
        SEL contextForBindable = NSSelectorFromString(@"_contextForBindable:");
        if (binder && [binder respondsToSelector:contextForBindable]) {
            id ctx = ((id (*)(id, SEL, id))objc_msgSend)(binder, contextForBindable, window);
            Show(@"phase2: _contextForBindable=%@", ctx);
            SEL ctxIdSel = NSSelectorFromString(@"contextId");
            if (ctx && [ctx respondsToSelector:ctxIdSel]) {
                unsigned int c = ((unsigned int (*)(id, SEL))objc_msgSend)(ctx, ctxIdSel);
                Show(@"phase2: CAContext contextId=%u", c);
                if (c && ![ids containsObject:@(c)]) [ids addObject:@(c)];
            }
        }
    } @catch (NSException *e) {}

    return ids;
}

static void RequestGlobalMouseEvents(void)
{
    if (!gService) return;

    UIWindow *window = KeyWindow();
    if (!window) {
        Show(@"phase2: no window");
        return;
    }

    NSArray<NSNumber *> *ctxs = ContextIDCandidates(window);
    Show(@"phase2: context candidates=%@", ctxs);
    if (!ctxs.count) {
        Show(@"phase2: no context id, not calling");
        return;
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // BKSHIDEventDisplay's own hardware identifier.
    Class dispCls = NSClassFromString(@"BKSHIDEventDisplay");
    SEL builtinSel = NSSelectorFromString(@"builtinDisplay");
    if (dispCls && [dispCls respondsToSelector:builtinSel]) {
        id builtin = ((id (*)(id, SEL))objc_msgSend)(dispCls, builtinSel);
        Show(@"phase2: BKSHIDEventDisplay builtinDisplay=%@", builtin);
        if (builtin) {
            id hardware = nil;
            @try { hardware = [builtin valueForKey:@"_hardwareIdentifier"]; } @catch (NSException *e) {}
            AddCandidate(candidates, hardware, @"BKSHIDEventDisplay._hardwareIdentifier");
        }
    }

    // UIScreen's FBSDisplayConfiguration.
    UIScreen *screen = UIScreen.mainScreen;
    SEL configSel = NSSelectorFromString(@"displayConfiguration");
    if ([screen respondsToSelector:configSel]) {
        id config = ((id (*)(id, SEL))objc_msgSend)(screen, configSel);
        Show(@"phase2: displayConfiguration=%@", config);
        if (config) {
            id identity = nil, hardware = nil, uniqueID = nil;
            @try { identity = [config valueForKey:@"identity"]; } @catch (NSException *e) {}
            @try { hardware = [config valueForKey:@"hardwareIdentifier"]; } @catch (NSException *e) {}
            @try { uniqueID = [config valueForKey:@"uniqueID"]; } @catch (NSException *e) {}
            Show(@"phase2: identity=%@ hardware=%@ uniqueID=%@", identity, hardware, uniqueID);
            if (identity) {
                id uid = nil;
                @try { uid = [identity valueForKey:@"uniqueIdentifier"]; } @catch (NSException *e) {}
                AddCandidate(candidates, uid, @"FBSDisplayIdentity.uniqueIdentifier");
            }
            AddCandidate(candidates, hardware, @"FBSDisplayConfiguration.hardwareIdentifier");
            AddCandidate(candidates, uniqueID, @"FBSDisplayConfiguration.uniqueID");
        }
    }

    // Any display UUID the service already knows about.
    @try {
        id map = [gService valueForKey:@"_displayUUIDToPerDisplayInfo"];
        if ([map isKindOfClass:[NSDictionary class]]) {
            Show(@"phase2: service display map keys=%@", [map allKeys]);
            for (id key in [map allKeys]) AddCandidate(candidates, key, @"_displayUUIDToPerDisplayInfo key");
        }
    } @catch (NSException *e) {}

    if (!candidates.count) {
        Show(@"phase2: no display UUID candidates");
        return;
    }

    SEL sel2 = NSSelectorFromString(@"requestGlobalMouseEventsForDisplay:targetContextID:");
    if (![gService respondsToSelector:sel2]) {
        Show(@"phase2: 2-arg selector absent");
        return;
    }
    NSMethodSignature *sig2 = [gService methodSignatureForSelector:sel2];

    gGlobalRoutes = [NSMutableArray array];
    for (NSString *uuid in candidates) {
        for (NSNumber *ctxNum in ctxs) {
            unsigned int ctx = ctxNum.unsignedIntValue;
            Show(@"phase2: trying 2-arg display=%@ ctx=%u", uuid, ctx);
            id ret = CallRequestGlobalMouseEvents(sig2, sel2, uuid, ctx, nil);
            Show(@"phase2: return(display=%@, ctx=%u)=%@", uuid, ctx, ret);
            if (ret) [gGlobalRoutes addObject:ret];
        }
    }

    gGlobalRoute = gGlobalRoutes.firstObject;
    if (gGlobalRoutes.count) {
        gRouteCreated = YES;
        Show(@"ROUTE CREATED (%lu) — move the mouse and click now",
             (unsigned long)gGlobalRoutes.count);
        InstallGCMouseLogging();
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

    InstallEventLogger();

    // Give phase 1 time to show whether the pointer is tracked, then ask
    // backboardd to route global mouse events to this window's context.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
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
