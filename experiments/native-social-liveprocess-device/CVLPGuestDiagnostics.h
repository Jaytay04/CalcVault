#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "CVLPProbe.h"

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger CVLPGuestDiagnosticsMaximumEvents = 16;
static const NSTimeInterval CVLPGuestDiagnosticsDeadline = 30.0;

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
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic, strong) NSMutableArray *observerTokens;
+ (void)start;
- (void)appendLine:(NSString *)line;
- (void)installObserversAndSnapshots;
- (void)observe:(NSNotificationCenter *)center
           name:(NSNotificationName)name
          phase:(nullable NSString *)phase
          stops:(BOOL)stops;
- (void)stop;
- (void)snapshot:(NSString *)phase notificationWindow:(nullable UIWindow *)notificationWindow;
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
        CVLPGuestGeometryDiagnosticsShared = observer;
    }

    // This fixed marker is safe before UIApplication exists and makes a stalled
    // main queue distinguishable from a successful launch with no windows.
    [observer appendLine:@"CVLP_GUEST_GEOMETRY phase=armed mainQueuePending=1"];
    if ([NSThread isMainThread]) {
        [observer installObserversAndSnapshots];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [observer installObserversAndSnapshots];
        });
    }
}

- (void)appendLine:(NSString *)line {
    if (self.stopped || self.eventCount >= CVLPGuestDiagnosticsMaximumEvents ||
        !CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }
    self.eventCount += 1;
    [CVLPProbe recordGuestDiagnostic:line];
    if (self.eventCount >= CVLPGuestDiagnosticsMaximumEvents) { [self stop]; }
}

- (void)installObserversAndSnapshots {
    if (self.stopped || self.installed) { return; }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self installObserversAndSnapshots]; });
        return;
    }
    if (CACurrentMediaTime() - self.startedAt >= CVLPGuestDiagnosticsDeadline) {
        [self stop];
        return;
    }
    self.installed = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak typeof(self) weakSelf = self;

    [self observe:center name:UIApplicationDidFinishLaunchingNotification phase:@"did-finish-launching" stops:NO];
    [self observe:center name:UISceneDidActivateNotification phase:@"scene-active" stops:NO];
    [self observe:center name:UIWindowDidBecomeVisibleNotification phase:@"window-visible" stops:NO];
    [self observe:center name:UIWindowDidBecomeKeyNotification phase:@"window-key" stops:NO];
    [self observe:center name:UIApplicationWillResignActiveNotification phase:nil stops:YES];
    [self observe:center name:UIApplicationDidEnterBackgroundNotification phase:nil stops:YES];
    [self observe:center name:UISceneWillDeactivateNotification phase:nil stops:YES];

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
            if (!strongSelf || strongSelf.stopped) { return; }
            NSTimeInterval elapsed = CACurrentMediaTime() - strongSelf.startedAt;
            if (elapsed > CVLPGuestDiagnosticsDeadline + 0.25) {
                [strongSelf stop];
                return;
            }
            [strongSelf snapshot:phase notificationWindow:nil];
            if ([phase isEqualToString:@"snapshot-30s"]) { [strongSelf stop]; }
        });
    }
}

- (void)observe:(NSNotificationCenter *)center
           name:(NSNotificationName)name
          phase:(nullable NSString *)phase
          stops:(BOOL)stops {
    __weak typeof(self) weakSelf = self;
    id token = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            CVLPGuestGeometryDiagnostics *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.stopped) { return; }
            if (stops) {
                [strongSelf stop];
                return;
            }
            if (CACurrentMediaTime() - strongSelf.startedAt >= CVLPGuestDiagnosticsDeadline) {
                [strongSelf stop];
                return;
            }
            UIWindow *eventWindow = [notification.object isKindOfClass:UIWindow.class]
                ? (UIWindow *)notification.object : nil;
            if (phase != nil) { [strongSelf snapshot:phase notificationWindow:eventWindow]; }
        }];
    [self.observerTokens addObject:token];
}

- (void)stop {
    if (self.stopped) { return; }
    self.stopped = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id token in self.observerTokens) { [center removeObserver:token]; }
    [self.observerTokens removeAllObjects];
}

- (void)snapshot:(NSString *)phase notificationWindow:(nullable UIWindow *)notificationWindow {
    if (self.stopped || self.eventCount >= CVLPGuestDiagnosticsMaximumEvents ||
        ![NSThread isMainThread]) { return; }
    static NSSet<NSString *> *allowedPhases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedPhases = [NSSet setWithArray:@[
            @"did-finish-launching", @"scene-active", @"window-visible", @"window-key",
            @"snapshot-1s", @"snapshot-3s", @"snapshot-10s", @"snapshot-30s"
        ]];
    });
    if (![allowedPhases containsObject:phase]) { return; }

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

    NSString *line = [NSString stringWithFormat:
        @"CVLP_GUEST_GEOMETRY phase=%@ delegatePresent=%d delegateSceneSupport=%d scenes=%lu[%@] windows=%lu[%@]",
        phase, delegatePresent, delegateSceneSupport,
        (unsigned long)sceneDetails.count, [sceneDetails componentsJoinedByString:@"|"],
        (unsigned long)windowDetails.count, [windowDetails componentsJoinedByString:@"|"]];
    [self appendLine:line];
}

@end

NS_ASSUME_NONNULL_END
