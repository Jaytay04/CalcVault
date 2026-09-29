#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "CVLPProbe.h"

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger CVLPGuestDiagnosticsMaximumEvents = 16;
static const NSUInteger CVLPGuestDiagnosticsMaximumNotificationSamples = 6;
static const NSTimeInterval CVLPGuestDiagnosticsDeadline = 30.0;
static const NSTimeInterval CVLPGuestDiagnosticsFinalSampleGrace = 0.25;

typedef NS_ENUM(NSUInteger, CVLPGuestDiagnosticsStopReason) {
    CVLPGuestDiagnosticsStopReasonAppInactive,
    CVLPGuestDiagnosticsStopReasonAppBackground,
    CVLPGuestDiagnosticsStopReasonSceneDeactivated,
    CVLPGuestDiagnosticsStopReasonDeadline,
    CVLPGuestDiagnosticsStopReasonEventLimit,
};

typedef NS_ENUM(NSUInteger, CVLPGuestDiagnosticsSampleSource) {
    CVLPGuestDiagnosticsSampleSourceDispatch,
    CVLPGuestDiagnosticsSampleSourceRunLoop,
    CVLPGuestDiagnosticsSampleSourceNotification,
};

static NSString *CVLPGuestDiagnosticsStopReasonName(CVLPGuestDiagnosticsStopReason reason) {
    switch (reason) {
        case CVLPGuestDiagnosticsStopReasonAppInactive: return @"app-inactive";
        case CVLPGuestDiagnosticsStopReasonAppBackground: return @"app-background";
        case CVLPGuestDiagnosticsStopReasonSceneDeactivated: return @"scene-deactivated";
        case CVLPGuestDiagnosticsStopReasonDeadline: return @"deadline";
        case CVLPGuestDiagnosticsStopReasonEventLimit: return @"event-limit";
    }
    return @"event-limit";
}

static CGFloat CVLPGuestDiagnosticsFinite(CGFloat value) {
    double number = (double)value;
    return isfinite(number) && fabs(number) <= 100000.0 ? value : 0.0;
}

static NSString *CVLPGuestDiagnosticsRect(CGRect rect) {
    return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
        CVLPGuestDiagnosticsFinite(rect.origin.x), CVLPGuestDiagnosticsFinite(rect.origin.y),
        CVLPGuestDiagnosticsFinite(rect.size.width), CVLPGuestDiagnosticsFinite(rect.size.height)];
}

static NSString *CVLPGuestDiagnosticsInsets(UIEdgeInsets insets) {
    return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
        CVLPGuestDiagnosticsFinite(insets.top), CVLPGuestDiagnosticsFinite(insets.right),
        CVLPGuestDiagnosticsFinite(insets.bottom), CVLPGuestDiagnosticsFinite(insets.left)];
}

static BOOL CVLPGuestDiagnosticsLineIsSanitized(NSString *line) {
    if (![line isKindOfClass:NSString.class] || line.length == 0 || line.length > 2048 ||
        ![line hasPrefix:@"CVLP_GUEST_GEOMETRY "]) { return NO; }
    static NSCharacterSet *allowedCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-=.,:;[]|"];
    });
    return [line rangeOfCharacterFromSet:allowedCharacters.invertedSet].location == NSNotFound;
}

@interface CVLPGuestGeometryDiagnostics : NSObject
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL installed;
@property(nonatomic) NSUInteger eventCount;
@property(nonatomic) NSUInteger dispatchSamples;
@property(nonatomic) NSUInteger runLoopSamples;
@property(nonatomic) NSUInteger notificationSamples;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic, strong) NSMutableArray *observerTokens;
@property(nonatomic, strong) NSMutableArray<NSTimer *> *runLoopTimers;
+ (void)start;
- (BOOL)appendPhase:(NSString *)phase fields:(NSString *)fields;
- (void)installObserversAndSnapshots;
- (void)observe:(NSNotificationCenter *)center
           name:(NSNotificationName)name
          phase:(nullable NSString *)phase
          stops:(BOOL)stops
     stopReason:(CVLPGuestDiagnosticsStopReason)stopReason;
- (void)stopWithReason:(CVLPGuestDiagnosticsStopReason)reason;
- (void)takeScheduledSnapshot:(NSString *)phase
                        source:(CVLPGuestDiagnosticsSampleSource)source
                       isFinal:(BOOL)isFinal;
- (BOOL)snapshot:(NSString *)phase
notificationWindow:(nullable UIWindow *)notificationWindow
          source:(CVLPGuestDiagnosticsSampleSource)source;
@end

static CVLPGuestGeometryDiagnostics *CVLPGuestGeometryDiagnosticsShared;

@implementation CVLPGuestGeometryDiagnostics

+ (void)start {
    CVLPGuestGeometryDiagnostics *observer;
    @synchronized (self) {
        if (CVLPGuestGeometryDiagnosticsShared != nil) { return; }
        observer = [CVLPGuestGeometryDiagnostics new];
        observer.startedAt = CACurrentMediaTime();
        observer.observerTokens = [NSMutableArray array];
        observer.runLoopTimers = [NSMutableArray array];
        CVLPGuestGeometryDiagnosticsShared = observer;
    }

    // This fixed marker is safe before UIApplication exists and makes a stalled
    // main queue distinguishable from a successful launch with no windows.
    [observer appendPhase:@"armed" fields:@"mainQueuePending=1"];
    if ([NSThread isMainThread]) {
        [observer installObserversAndSnapshots];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [observer installObserversAndSnapshots];
        });
    }
}

- (uint64_t)elapsedMilliseconds {
    CFTimeInterval elapsed = MAX(0.0, CACurrentMediaTime() - self.startedAt);
    return (uint64_t)floor(elapsed * 1000.0);
}

- (BOOL)appendPhase:(NSString *)phase fields:(NSString *)fields {
    if (self.stopped) { return NO; }
    // Keep one slot for the terminal marker. The 16th event is always terminal.
    if (self.eventCount >= CVLPGuestDiagnosticsMaximumEvents - 1) {
        [self stopWithReason:CVLPGuestDiagnosticsStopReasonEventLimit];
        return NO;
    }
    NSUInteger sequence = self.eventCount + 1;
    NSString *suffix = fields.length > 0 ? [NSString stringWithFormat:@" %@", fields] : @"";
    NSString *line = [NSString stringWithFormat:
        @"CVLP_GUEST_GEOMETRY phase=%@ sequence=%lu elapsedMs=%llu%@",
        phase, (unsigned long)sequence, (unsigned long long)[self elapsedMilliseconds], suffix];
    if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return NO; }
    self.eventCount = sequence;
    [CVLPProbe recordGuestDiagnostic:line];
    return YES;
}

- (void)installObserversAndSnapshots {
    if (self.stopped || self.installed) { return; }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self installObserversAndSnapshots]; });
        return;
    }
    if (CACurrentMediaTime() - self.startedAt >= CVLPGuestDiagnosticsDeadline) {
        [self stopWithReason:CVLPGuestDiagnosticsStopReasonDeadline];
        return;
    }
    self.installed = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak typeof(self) weakSelf = self;

    [self observe:center name:UIApplicationDidFinishLaunchingNotification phase:@"did-finish-launching" stops:NO
        stopReason:CVLPGuestDiagnosticsStopReasonDeadline];
    [self observe:center name:UISceneDidActivateNotification phase:@"scene-active" stops:NO
        stopReason:CVLPGuestDiagnosticsStopReasonDeadline];
    [self observe:center name:UIWindowDidBecomeVisibleNotification phase:@"window-visible" stops:NO
        stopReason:CVLPGuestDiagnosticsStopReasonDeadline];
    [self observe:center name:UIWindowDidBecomeKeyNotification phase:@"window-key" stops:NO
        stopReason:CVLPGuestDiagnosticsStopReasonDeadline];
    [self observe:center name:UIApplicationWillResignActiveNotification phase:nil stops:YES
        stopReason:CVLPGuestDiagnosticsStopReasonAppInactive];
    [self observe:center name:UIApplicationDidEnterBackgroundNotification phase:nil stops:YES
        stopReason:CVLPGuestDiagnosticsStopReasonAppBackground];
    [self observe:center name:UISceneWillDeactivateNotification phase:nil stops:YES
        stopReason:CVLPGuestDiagnosticsStopReasonSceneDeactivated];

    NSArray<NSNumber *> *delays = @[@1, @3, @10, @30];
    NSArray<NSString *> *phases = @[@"snapshot-1s", @"snapshot-3s", @"snapshot-10s", @"snapshot-30s"];
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSTimeInterval delay = delays[index].doubleValue;
        NSTimeInterval elapsed = CACurrentMediaTime() - self.startedAt;
        NSTimeInterval remaining = MAX(0.0, delay - elapsed);
        dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC));
        NSString *phase = phases[index];
        dispatch_after(when, dispatch_get_main_queue(), ^{
            CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
            [strongSelf takeScheduledSnapshot:phase
                source:CVLPGuestDiagnosticsSampleSourceDispatch
                isFinal:[phase isEqualToString:@"snapshot-30s"]];
        });
    }

    NSArray<NSNumber *> *runLoopDelays = @[@2, @8, @30];
    NSArray<NSString *> *runLoopPhases = @[@"runloop-2s", @"runloop-8s", @"runloop-30s"];
    for (NSUInteger index = 0; index < runLoopDelays.count; index++) {
        NSTimeInterval delay = runLoopDelays[index].doubleValue;
        NSTimeInterval elapsed = CACurrentMediaTime() - self.startedAt;
        NSTimeInterval remaining = MAX(0.0, delay - elapsed);
        NSString *phase = runLoopPhases[index];
        NSTimer *timer = [NSTimer timerWithTimeInterval:remaining repeats:NO
            block:^(NSTimer * _Nonnull firedTimer) {
                CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
                [strongSelf takeScheduledSnapshot:phase
                    source:CVLPGuestDiagnosticsSampleSourceRunLoop
                    isFinal:[phase isEqualToString:@"runloop-30s"]];
            }];
        [self.runLoopTimers addObject:timer];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }

    NSTimeInterval runLoopTerminalElapsed = CACurrentMediaTime() - self.startedAt;
    NSTimeInterval runLoopTerminalDelay = MAX(0.0,
        CVLPGuestDiagnosticsDeadline + CVLPGuestDiagnosticsFinalSampleGrace - runLoopTerminalElapsed);
    NSTimer *runLoopTerminalTimer = [NSTimer timerWithTimeInterval:runLoopTerminalDelay repeats:NO
        block:^(NSTimer * _Nonnull firedTimer) {
            CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
            if (strongSelf && !strongSelf.stopped) {
                [strongSelf stopWithReason:CVLPGuestDiagnosticsStopReasonDeadline];
            }
        }];
    [self.runLoopTimers addObject:runLoopTerminalTimer];
    [[NSRunLoop mainRunLoop] addTimer:runLoopTerminalTimer forMode:NSRunLoopCommonModes];

    NSString *installedFields = [NSString stringWithFormat:
        @"dispatchScheduled=4 runLoopScheduled=3 runLoopTerminalScheduled=1 notificationLimit=%lu",
        (unsigned long)CVLPGuestDiagnosticsMaximumNotificationSamples];
    [self appendPhase:@"installed" fields:installedFields];

    NSTimeInterval elapsed = CACurrentMediaTime() - self.startedAt;
    NSTimeInterval terminalDelay = MAX(0.0,
        CVLPGuestDiagnosticsDeadline + CVLPGuestDiagnosticsFinalSampleGrace - elapsed);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(terminalDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
            if (strongSelf && !strongSelf.stopped) {
                [strongSelf stopWithReason:CVLPGuestDiagnosticsStopReasonDeadline];
            }
        });
}

- (void)observe:(NSNotificationCenter *)center
           name:(NSNotificationName)name
          phase:(nullable NSString *)phase
          stops:(BOOL)stops
     stopReason:(CVLPGuestDiagnosticsStopReason)stopReason {
    __weak typeof(self) weakSelf = self;
    id token = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.stopped) { return; }
            if (stops) {
                [strongSelf stopWithReason:stopReason];
                return;
            }
            NSTimeInterval elapsed = CACurrentMediaTime() - strongSelf.startedAt;
            if (elapsed > CVLPGuestDiagnosticsDeadline + CVLPGuestDiagnosticsFinalSampleGrace) {
                [strongSelf stopWithReason:CVLPGuestDiagnosticsStopReasonDeadline];
                return;
            }
            if (elapsed >= CVLPGuestDiagnosticsDeadline ||
                strongSelf.notificationSamples >= CVLPGuestDiagnosticsMaximumNotificationSamples) { return; }
            UIWindow *eventWindow = [notification.object isKindOfClass:UIWindow.class]
                ? (UIWindow *)notification.object : nil;
            if (phase != nil) {
                [strongSelf snapshot:phase notificationWindow:eventWindow
                    source:CVLPGuestDiagnosticsSampleSourceNotification];
            }
        }];
    [self.observerTokens addObject:token];
}

- (void)takeScheduledSnapshot:(NSString *)phase
                        source:(CVLPGuestDiagnosticsSampleSource)source
                       isFinal:(BOOL)isFinal {
    if (self.stopped) { return; }
    NSTimeInterval elapsed = CACurrentMediaTime() - self.startedAt;
    if (elapsed >= CVLPGuestDiagnosticsDeadline) {
        if (elapsed > CVLPGuestDiagnosticsDeadline + CVLPGuestDiagnosticsFinalSampleGrace) {
            [self stopWithReason:CVLPGuestDiagnosticsStopReasonDeadline];
        } else if (isFinal) {
            [self snapshot:phase notificationWindow:nil source:source];
        }
        return;
    }
    [self snapshot:phase notificationWindow:nil source:source];
}

- (void)stopWithReason:(CVLPGuestDiagnosticsStopReason)reason {
    if (self.stopped) { return; }
    self.stopped = YES;
    if (self.eventCount < CVLPGuestDiagnosticsMaximumEvents) {
        NSUInteger sequence = self.eventCount + 1;
        NSString *line = [NSString stringWithFormat:
            @"CVLP_GUEST_GEOMETRY phase=stopped reason=%@ sequence=%lu elapsedMs=%llu dispatchSamples=%lu runLoopSamples=%lu notificationSamples=%lu",
            CVLPGuestDiagnosticsStopReasonName(reason), (unsigned long)sequence,
            (unsigned long long)[self elapsedMilliseconds], (unsigned long)self.dispatchSamples,
            (unsigned long)self.runLoopSamples, (unsigned long)self.notificationSamples];
        if (CVLPGuestDiagnosticsLineIsSanitized(line)) {
            self.eventCount = sequence;
            [CVLPProbe recordGuestDiagnostic:line];
        }
    }
    for (NSTimer *timer in self.runLoopTimers) { [timer invalidate]; }
    [self.runLoopTimers removeAllObjects];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id token in self.observerTokens) { [center removeObserver:token]; }
    [self.observerTokens removeAllObjects];
}

- (BOOL)snapshot:(NSString *)phase
notificationWindow:(nullable UIWindow *)notificationWindow
          source:(CVLPGuestDiagnosticsSampleSource)source {
    if (self.stopped || ![NSThread isMainThread]) { return NO; }
    if (self.eventCount >= CVLPGuestDiagnosticsMaximumEvents - 1) {
        [self stopWithReason:CVLPGuestDiagnosticsStopReasonEventLimit];
        return NO;
    }
    static NSSet<NSString *> *allowedPhases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedPhases = [NSSet setWithArray:@[
            @"did-finish-launching", @"scene-active", @"window-visible", @"window-key",
            @"snapshot-1s", @"snapshot-3s", @"snapshot-10s", @"snapshot-30s",
            @"runloop-2s", @"runloop-8s", @"runloop-30s"
        ]];
    });
    if (![allowedPhases containsObject:phase]) { return NO; }

    UIApplication *application = UIApplication.sharedApplication;
    id<UIApplicationDelegate> delegate = application.delegate;
    BOOL delegatePresent = delegate != nil;
    BOOL delegateSceneSupport = [delegate respondsToSelector:
        @selector(application:configurationForConnectingSceneSession:options:)];

    NSMutableArray<NSString *> *sceneDetails = [NSMutableArray array];
    NSMutableArray<UIWindowScene *> *sampledScenes = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [sampledScenes addObject:windowScene];
        [sceneDetails addObject:[NSString stringWithFormat:@"active=%ld coord=%@",
            (long)windowScene.activationState,
            CVLPGuestDiagnosticsRect(windowScene.coordinateSpace.bounds)]];
        if (sampledScenes.count >= 2) { break; }
    }

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSHashTable<UIWindow *> *seenWindows = [[NSHashTable alloc]
        initWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
        capacity:3];
    void (^appendWindow)(UIWindow * _Nullable) = ^(UIWindow * _Nullable window) {
        if (window != nil && ![seenWindows containsObject:window] && windows.count < 3) {
            [seenWindows addObject:window];
            [windows addObject:window];
        }
    };
    appendWindow(notificationWindow);
    if ([delegate respondsToSelector:@selector(window)]) {
        appendWindow(delegate.window);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *applicationWindows = application.windows;
#pragma clang diagnostic pop
    for (UIWindow *window in applicationWindows) {
        if (window.windowScene == nil) { appendWindow(window); }
    }
    for (UIWindowScene *scene in sampledScenes) {
        for (UIWindow *window in scene.windows) { appendWindow(window); }
    }

    NSMutableArray<NSString *> *windowDetails = [NSMutableArray array];
    for (UIWindow *window in windows) {
        UIView *rootView = window.rootViewController.viewIfLoaded;
        NSString *rootBounds = rootView != nil
            ? CVLPGuestDiagnosticsRect(rootView.bounds) : @"0.0,0.0,0.0,0.0";
        [windowDetails addObject:[NSString stringWithFormat:
            @"scene=%d bounds=%@ key=%d hidden=%d safe=%@ rootLoaded=%d root=%@",
            window.windowScene != nil, CVLPGuestDiagnosticsRect(window.bounds),
            window.isKeyWindow, window.hidden, CVLPGuestDiagnosticsInsets(window.safeAreaInsets),
            rootView != nil, rootBounds]];
    }

    NSString *fields = [NSString stringWithFormat:
        @"delegatePresent=%d delegateSceneSupport=%d scenes=%lu[%@] windows=%lu[%@]",
        delegatePresent, delegateSceneSupport,
        (unsigned long)sceneDetails.count, [sceneDetails componentsJoinedByString:@"|"],
        (unsigned long)windowDetails.count, [windowDetails componentsJoinedByString:@"|"]];
    BOOL appended = [self appendPhase:phase fields:fields];
    if (appended) {
        switch (source) {
            case CVLPGuestDiagnosticsSampleSourceDispatch: self.dispatchSamples += 1; break;
            case CVLPGuestDiagnosticsSampleSourceRunLoop: self.runLoopSamples += 1; break;
            case CVLPGuestDiagnosticsSampleSourceNotification: self.notificationSamples += 1; break;
        }
    }
    return appended;
}

@end

NS_ASSUME_NONNULL_END
