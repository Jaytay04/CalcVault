#import "CVLPCooperativeMediaGate.h"

@import AVFoundation;
@import CoreMedia;
#import <objc/runtime.h>
#import <os/lock.h>
#import <math.h>

static const NSUInteger CVLPMediaRegistryLimit = 128;
static const NSUInteger CVLPMediaTokenLimit = 128;
static const NSTimeInterval CVLPMediaMaximumHoldDuration = 120.0;
static NSString * const CVLPMediaGateErrorDomain = @"CVLPCooperativeMediaGate";

@interface CVLPMediaHook : NSObject
@property(nonatomic) Class targetClass;
@property(nonatomic) SEL selector;
@property(nonatomic) Method method;
@property(nonatomic) IMP originalImplementation;
@property(nonatomic) IMP wrapperImplementation;
@end

@implementation CVLPMediaHook
@end

@interface CVLPCooperativeMediaGate ()
- (instancetype)initPrivate;
@property(nonatomic) os_unfair_lock stateLock;
@property(nonatomic, strong) dispatch_queue_t controlQueue;
@property(nonatomic, strong) dispatch_queue_t mediaQueue;
@property(nonatomic, strong) NSHashTable<AVPlayer *> *players;
@property(nonatomic, strong) NSHashTable<AVAudioPlayer *> *audioPlayers;
@property(nonatomic, strong) NSHashTable<AVAudioEngine *> *audioEngines;
@property(nonatomic, strong) NSMutableSet<NSUUID *> *consumedTokens;
@property(nonatomic, strong) NSMutableArray<CVLPMediaHook *> *hooks;
@property(nonatomic, strong) dispatch_source_t expirationTimer;
@property(nonatomic) NSUInteger inFlightEntries;
@property(nonatomic, strong, nullable) NSUUID *activeToken;
@property(nonatomic, copy, nullable) void (^expirationHandler)(void);
@property(nonatomic) NSTimeInterval activeDeadlineUptime;
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL held;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL holdApplying;
@property(nonatomic) BOOL pauseRequestScheduled;
@end

typedef NS_ENUM(NSUInteger, CVLPMediaKind) {
    CVLPMediaKindPlayer,
    CVLPMediaKindAudioPlayer,
    CVLPMediaKindAudioEngine,
};

static IMP CVLPAVPlayerPlayOriginal;
static IMP CVLPAVPlayerSetRateOriginal;
static IMP CVLPAVPlayerPlayImmediatelyAtRateOriginal;
static IMP CVLPAVPlayerSetRateAtTimeOriginal;
static IMP CVLPAVAudioPlayerPlayOriginal;
static IMP CVLPAVAudioPlayerPlayAtTimeOriginal;
static IMP CVLPAVAudioPlayerSetRateOriginal;
static IMP CVLPAVAudioEngineStartOriginal;
static IMP CVLPAVAudioSessionSetActiveOriginal;
static IMP CVLPAVAudioSessionSetActiveWithOptionsOriginal;

static CVLPCooperativeMediaGate *CVLPSharedMediaGate(void) {
    static CVLPCooperativeMediaGate *gate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gate = [[CVLPCooperativeMediaGate alloc] initPrivate];
    });
    return gate;
}

static const char *CVLPSkipTypeQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL CVLPTypeEncodingMatches(const char *actual, const char *expected) {
    actual = CVLPSkipTypeQualifiers(actual);
    expected = CVLPSkipTypeQualifiers(expected);
    if (!actual || !expected) return NO;
    // Runtime encodings may attach a declared class name to an object type.
    if (*actual == '@' && *expected == '@') return YES;
    return strcmp(actual, expected) == 0;
}

static BOOL CVLPMethodHasSignature(Method method,
                                   const char *returnType,
                                   const char *const *argumentTypes,
                                   NSUInteger argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;

    char typeBuffer[256] = {0};
    method_getReturnType(method, typeBuffer, sizeof(typeBuffer));
    if (!CVLPTypeEncodingMatches(typeBuffer, returnType)) return NO;

    for (NSUInteger index = 0; index < argumentCount; index++) {
        memset(typeBuffer, 0, sizeof(typeBuffer));
        method_getArgumentType(method, (unsigned int)index, typeBuffer, sizeof(typeBuffer));
        if (!CVLPTypeEncodingMatches(typeBuffer, argumentTypes[index])) return NO;
    }
    return YES;
}

static BOOL CVLPClassOwnsSelector(Class targetClass, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(targetClass, &count);
    BOOL ownsSelector = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            ownsSelector = YES;
            break;
        }
    }
    free(methods);
    return ownsSelector;
}

static NSError *CVLPMediaHoldError(void) {
    return [NSError errorWithDomain:CVLPMediaGateErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                                          @"Media start is refused during a cooperative hold."}];
}

static BOOL CVLPHasPositiveRate(float rate) {
    return rate > 0.0f;
}

@interface CVLPCooperativeMediaGate (Private)
- (instancetype)initPrivate;
- (BOOL)installHooks;
- (void)beginHoldWithToken:(NSUUID *)token
           maximumDuration:(NSTimeInterval)duration
                completion:(void (^)(BOOL applied))completion
                expiration:(void (^)(void))expiration;
- (BOOL)endHoldWithToken:(NSUUID *)token;
- (void)invalidateGate;
- (void)cancelExpirationTimerLocked;
- (nullable void (^)(void))finishExpirationLockedForToken:(NSUUID *)token;
- (BOOL)hooksAreOwnedLocked;
- (BOOL)installSelector:(SEL)selector
                onClass:(Class)targetClass
                wrapper:(IMP)wrapper
             returnType:(const char *)returnType
          argumentTypes:(const char *const *)argumentTypes
          argumentCount:(NSUInteger)argumentCount
   originalImplementation:(IMP *)originalImplementation;
- (BOOL)beginMediaEntryForObject:(nullable id)object kind:(CVLPMediaKind)kind;
- (BOOL)beginSessionActivation;
- (void)endMediaEntry;
- (BOOL)deactivateAudioSessionForHold;
- (void)pauseTrackedMedia;
- (void)completeHoldApplicationForToken:(NSUUID *)token
                                  paused:(BOOL)paused
                             deactivated:(BOOL)deactivated
                              completion:(void (^)(BOOL applied))completion;
- (void)expireHoldForToken:(NSUUID *)token;
- (void)deliverExpiration:(nullable void (^)(void))handler;
@end

static void CVLPAVPlayerPlay(id self, SEL selector) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (![gate beginMediaEntryForObject:self kind:CVLPMediaKindPlayer]) return;
    IMP original = CVLPAVPlayerPlayOriginal;
    if (original) ((void (*)(id, SEL))original)(self, selector);
    [gate endMediaEntry];
}

static void CVLPAVPlayerSetRate(id self, SEL selector, float rate) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (CVLPHasPositiveRate(rate) &&
        ![gate beginMediaEntryForObject:self kind:CVLPMediaKindPlayer]) return;
    IMP original = CVLPAVPlayerSetRateOriginal;
    if (original) ((void (*)(id, SEL, float))original)(self, selector, rate);
    if (CVLPHasPositiveRate(rate)) [gate endMediaEntry];
}

static void CVLPAVPlayerPlayImmediatelyAtRate(id self, SEL selector, float rate) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (CVLPHasPositiveRate(rate) &&
        ![gate beginMediaEntryForObject:self kind:CVLPMediaKindPlayer]) return;
    IMP original = CVLPAVPlayerPlayImmediatelyAtRateOriginal;
    if (original) ((void (*)(id, SEL, float))original)(self, selector, rate);
    if (CVLPHasPositiveRate(rate)) [gate endMediaEntry];
}

static void CVLPAVPlayerSetRateAtTime(id self, SEL selector, float rate, CMTime itemTime, CMTime hostTime) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (CVLPHasPositiveRate(rate) &&
        ![gate beginMediaEntryForObject:self kind:CVLPMediaKindPlayer]) return;
    IMP original = CVLPAVPlayerSetRateAtTimeOriginal;
    if (original) ((void (*)(id, SEL, float, CMTime, CMTime))original)(self, selector, rate, itemTime, hostTime);
    if (CVLPHasPositiveRate(rate)) [gate endMediaEntry];
}

static BOOL CVLPAVAudioPlayerPlay(id self, SEL selector) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (![gate beginMediaEntryForObject:self kind:CVLPMediaKindAudioPlayer]) return NO;
    IMP original = CVLPAVAudioPlayerPlayOriginal;
    BOOL result = original ? ((BOOL (*)(id, SEL))original)(self, selector) : NO;
    [gate endMediaEntry];
    return result;
}

static BOOL CVLPAVAudioPlayerPlayAtTime(id self, SEL selector, NSTimeInterval time) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (![gate beginMediaEntryForObject:self kind:CVLPMediaKindAudioPlayer]) return NO;
    IMP original = CVLPAVAudioPlayerPlayAtTimeOriginal;
    BOOL result = original ? ((BOOL (*)(id, SEL, NSTimeInterval))original)(self, selector, time) : NO;
    [gate endMediaEntry];
    return result;
}

static void CVLPAVAudioPlayerSetRate(id self, SEL selector, float rate) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (CVLPHasPositiveRate(rate) &&
        ![gate beginMediaEntryForObject:self kind:CVLPMediaKindAudioPlayer]) return;
    IMP original = CVLPAVAudioPlayerSetRateOriginal;
    if (original) ((void (*)(id, SEL, float))original)(self, selector, rate);
    if (CVLPHasPositiveRate(rate)) [gate endMediaEntry];
}

static BOOL CVLPAVAudioEngineStart(id self, SEL selector, NSError **error) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (![gate beginMediaEntryForObject:self kind:CVLPMediaKindAudioEngine]) {
        if (error) *error = CVLPMediaHoldError();
        return NO;
    }
    IMP original = CVLPAVAudioEngineStartOriginal;
    BOOL result = original ? ((BOOL (*)(id, SEL, NSError **))original)(self, selector, error) : NO;
    [gate endMediaEntry];
    return result;
}

static BOOL CVLPAVAudioSessionSetActive(id self, SEL selector, BOOL active, NSError **error) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (active && ![gate beginSessionActivation]) {
        if (error) *error = CVLPMediaHoldError();
        return NO;
    }
    IMP original = CVLPAVAudioSessionSetActiveOriginal;
    BOOL result = original ? ((BOOL (*)(id, SEL, BOOL, NSError **))original)(self, selector, active, error) : NO;
    if (active) [gate endMediaEntry];
    return result;
}

static BOOL CVLPAVAudioSessionSetActiveWithOptions(id self, SEL selector, BOOL active,
                                                   NSUInteger options, NSError **error) {
    CVLPCooperativeMediaGate *gate = CVLPSharedMediaGate();
    if (active && ![gate beginSessionActivation]) {
        if (error) *error = CVLPMediaHoldError();
        return NO;
    }
    IMP original = CVLPAVAudioSessionSetActiveWithOptionsOriginal;
    BOOL result = original ? ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))original)(self, selector, active, options, error) : NO;
    if (active) [gate endMediaEntry];
    return result;
}

@implementation CVLPCooperativeMediaGate

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;

    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    _stateLock = lock;
    _controlQueue = dispatch_queue_create("org.example.cvlp.cooperative-media-gate", DISPATCH_QUEUE_SERIAL);
    _mediaQueue = dispatch_queue_create("org.example.cvlp.cooperative-media-gate.media", DISPATCH_QUEUE_SERIAL);
    _players = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    _audioPlayers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    _audioEngines = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    _consumedTokens = [NSMutableSet setWithCapacity:CVLPMediaTokenLimit];
    _hooks = [NSMutableArray arrayWithCapacity:10];
    return self;
}

+ (BOOL)install {
    return [CVLPSharedMediaGate() installHooks];
}

+ (void)beginHoldWithToken:(NSUUID *)token
           maximumDuration:(NSTimeInterval)duration
                completion:(void (^)(BOOL applied))completion
                expiration:(void (^)(void))expiration {
    [CVLPSharedMediaGate() beginHoldWithToken:token maximumDuration:duration completion:completion expiration:expiration];
}

+ (BOOL)endHoldWithToken:(NSUUID *)token {
    return [CVLPSharedMediaGate() endHoldWithToken:token];
}

+ (void)invalidate {
    [CVLPSharedMediaGate() invalidateGate];
}

- (BOOL)installSelector:(SEL)selector
                onClass:(Class)targetClass
                wrapper:(IMP)wrapper
             returnType:(const char *)returnType
          argumentTypes:(const char *const *)argumentTypes
          argumentCount:(NSUInteger)argumentCount
   originalImplementation:(IMP *)originalImplementation {
    for (CVLPMediaHook *existing in self.hooks) {
        if (existing.targetClass == targetClass && existing.selector == selector) {
            return method_getImplementation(existing.method) == existing.wrapperImplementation;
        }
    }

    Method inheritedOrOwnedMethod = class_getInstanceMethod(targetClass, selector);
    if (!inheritedOrOwnedMethod || !CVLPMethodHasSignature(inheritedOrOwnedMethod, returnType,
                                                              argumentTypes, argumentCount)) return NO;

    BOOL hadOwnMethod = CVLPClassOwnsSelector(targetClass, selector);
    IMP previous = method_getImplementation(inheritedOrOwnedMethod);
    if (!previous || previous == wrapper) return NO;

    // Publish the trampoline target before making the wrapper reachable.
    if (originalImplementation) *originalImplementation = previous;
    Method installedMethod = inheritedOrOwnedMethod;
    if (hadOwnMethod) {
        IMP replaced = method_setImplementation(inheritedOrOwnedMethod, wrapper);
        if (!replaced) return NO;
        previous = replaced;
        if (originalImplementation) *originalImplementation = previous;
    } else {
        const char *encoding = method_getTypeEncoding(inheritedOrOwnedMethod);
        if (!encoding || !class_addMethod(targetClass, selector, wrapper, encoding)) return NO;
        installedMethod = class_getInstanceMethod(targetClass, selector);
    }

    if (!installedMethod || method_getImplementation(installedMethod) != wrapper) return NO;
    CVLPMediaHook *hook = [CVLPMediaHook new];
    hook.targetClass = targetClass;
    hook.selector = selector;
    hook.method = installedMethod;
    hook.originalImplementation = previous;
    hook.wrapperImplementation = wrapper;
    [self.hooks addObject:hook];
    return YES;
}

- (BOOL)installHooks {
    // AVPlayer playback control was main-queue-only before iOS 16. This gate
    // performs pause calls on its dedicated worker, so fail closed there.
    if (@available(iOS 16.0, *)) {
    } else {
        os_unfair_lock_lock(&_stateLock);
        self.invalidated = YES;
        self.held = YES;
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    os_unfair_lock_lock(&_stateLock);
    BOOL allInstalled = YES;
    const char *objectVoidArgs[] = {@encode(id), @encode(SEL)};
    const char *objectFloatArgs[] = {@encode(id), @encode(SEL), @encode(float)};
    const char *objectFloatCMTimeArgs[] = {@encode(id), @encode(SEL), @encode(float), @encode(CMTime), @encode(CMTime)};
    const char *objectDoubleArgs[] = {@encode(id), @encode(SEL), @encode(NSTimeInterval)};
    const char *objectErrorArgs[] = {@encode(id), @encode(SEL), @encode(NSError * __autoreleasing *)};
    const char *objectBoolErrorArgs[] = {@encode(id), @encode(SEL), @encode(BOOL), @encode(NSError * __autoreleasing *)};
    const char *objectBoolOptionsErrorArgs[] = {@encode(id), @encode(SEL), @encode(BOOL), @encode(NSUInteger), @encode(NSError * __autoreleasing *)};

    allInstalled = [self installSelector:@selector(play) onClass:AVPlayer.class
                                  wrapper:(IMP)CVLPAVPlayerPlay returnType:@encode(void)
                           argumentTypes:objectVoidArgs argumentCount:2
                  originalImplementation:&CVLPAVPlayerPlayOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(setRate:) onClass:AVPlayer.class
                                  wrapper:(IMP)CVLPAVPlayerSetRate returnType:@encode(void)
                           argumentTypes:objectFloatArgs argumentCount:3
                  originalImplementation:&CVLPAVPlayerSetRateOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(playImmediatelyAtRate:) onClass:AVPlayer.class
                                  wrapper:(IMP)CVLPAVPlayerPlayImmediatelyAtRate returnType:@encode(void)
                           argumentTypes:objectFloatArgs argumentCount:3
                  originalImplementation:&CVLPAVPlayerPlayImmediatelyAtRateOriginal] && allInstalled;
    allInstalled = [self installSelector:sel_registerName("setRate:time:atHostTime:") onClass:AVPlayer.class
                                  wrapper:(IMP)CVLPAVPlayerSetRateAtTime returnType:@encode(void)
                           argumentTypes:objectFloatCMTimeArgs argumentCount:5
                  originalImplementation:&CVLPAVPlayerSetRateAtTimeOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(play) onClass:AVAudioPlayer.class
                                  wrapper:(IMP)CVLPAVAudioPlayerPlay returnType:@encode(BOOL)
                           argumentTypes:objectVoidArgs argumentCount:2
                  originalImplementation:&CVLPAVAudioPlayerPlayOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(playAtTime:) onClass:AVAudioPlayer.class
                                  wrapper:(IMP)CVLPAVAudioPlayerPlayAtTime returnType:@encode(BOOL)
                           argumentTypes:objectDoubleArgs argumentCount:3
                  originalImplementation:&CVLPAVAudioPlayerPlayAtTimeOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(setRate:) onClass:AVAudioPlayer.class
                                  wrapper:(IMP)CVLPAVAudioPlayerSetRate returnType:@encode(void)
                           argumentTypes:objectFloatArgs argumentCount:3
                  originalImplementation:&CVLPAVAudioPlayerSetRateOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(startAndReturnError:) onClass:AVAudioEngine.class
                                  wrapper:(IMP)CVLPAVAudioEngineStart returnType:@encode(BOOL)
                           argumentTypes:objectErrorArgs argumentCount:3
                  originalImplementation:&CVLPAVAudioEngineStartOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(setActive:error:) onClass:AVAudioSession.class
                                  wrapper:(IMP)CVLPAVAudioSessionSetActive returnType:@encode(BOOL)
                           argumentTypes:objectBoolErrorArgs argumentCount:4
                  originalImplementation:&CVLPAVAudioSessionSetActiveOriginal] && allInstalled;
    allInstalled = [self installSelector:@selector(setActive:withOptions:error:) onClass:AVAudioSession.class
                                  wrapper:(IMP)CVLPAVAudioSessionSetActiveWithOptions returnType:@encode(BOOL)
                           argumentTypes:objectBoolOptionsErrorArgs argumentCount:5
                  originalImplementation:&CVLPAVAudioSessionSetActiveWithOptionsOriginal] && allInstalled;

    self.installed = allInstalled && self.hooks.count == 10 && [self hooksAreOwnedLocked];
    if (!self.installed) {
        self.invalidated = YES;
        self.held = YES;
    }
    BOOL result = self.installed;
    os_unfair_lock_unlock(&_stateLock);
    if (!result) [self pauseTrackedMedia];
    return result;
}

- (BOOL)hooksAreOwnedLocked {
    if (!self.installed && self.hooks.count != 10) return NO;
    if (self.hooks.count != 10) return NO;
    for (CVLPMediaHook *hook in self.hooks) {
        if (!hook.method || method_getImplementation(hook.method) != hook.wrapperImplementation) return NO;
    }
    return YES;
}

- (void)beginHoldWithToken:(NSUUID *)token
           maximumDuration:(NSTimeInterval)duration
                completion:(void (^)(BOOL applied))completion
                expiration:(void (^)(void))expiration {
    if (!completion) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    if (![token isKindOfClass:NSUUID.class] || !expiration || !isfinite(duration) ||
        duration <= 0.0 || duration > CVLPMediaMaximumHoldDuration) {
        completion(NO);
        return;
    }

    NSArray<AVPlayer *> *players = nil;
    NSArray<AVAudioPlayer *> *audioPlayers = nil;
    NSArray<AVAudioEngine *> *audioEngines = nil;
    BOOL shouldPause = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!self.installed || self.invalidated || self.held || self.activeToken ||
        self.inFlightEntries != 0 || [self.consumedTokens containsObject:token] ||
        self.consumedTokens.count >= CVLPMediaTokenLimit ||
        ![self hooksAreOwnedLocked]) {
        if ((self.installed && ![self hooksAreOwnedLocked]) ||
            self.consumedTokens.count >= CVLPMediaTokenLimit) {
            self.invalidated = YES;
            self.held = YES;
        }
        shouldPause = self.held && self.invalidated;
        os_unfair_lock_unlock(&_stateLock);
        if (shouldPause) [self pauseTrackedMedia];
        completion(NO);
        return;
    }

    [self.consumedTokens addObject:token];
    self.activeToken = token;
    self.expirationHandler = [expiration copy];
    self.activeDeadlineUptime = NSProcessInfo.processInfo.systemUptime + duration;
    self.held = YES;
    self.holdApplying = YES;

    // Snapshot weak registries while closing admission. Start the independent
    // expiration timer before enqueueing any potentially blocking AV call.
    players = self.players.allObjects;
    audioPlayers = self.audioPlayers.allObjects;
    audioEngines = self.audioEngines.allObjects;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.controlQueue);
    if (!timer) {
        self.invalidated = YES;
        self.held = YES;
        self.holdApplying = NO;
        self.activeToken = nil;
        self.expirationHandler = nil;
        self.activeDeadlineUptime = 0;
        os_unfair_lock_unlock(&_stateLock);
        completion(NO);
        return;
    }
    self.expirationTimer = timer;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf expireHoldForToken:token];
    });
    NSTimeInterval remaining = MAX(0.0, self.activeDeadlineUptime - NSProcessInfo.processInfo.systemUptime);
    uint64_t nanoseconds = (uint64_t)MAX(1.0, ceil(remaining * (NSTimeInterval)NSEC_PER_SEC));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanoseconds), DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
    os_unfair_lock_unlock(&_stateLock);

    CVLPCooperativeMediaGate *gate = self;
    dispatch_async(self.mediaQueue, ^{
        os_unfair_lock_lock(&gate->_stateLock);
        BOOL mayApply = gate.held && !gate.invalidated && gate.holdApplying &&
            gate.activeToken && [gate.activeToken isEqual:token] &&
            NSProcessInfo.processInfo.systemUptime < gate.activeDeadlineUptime &&
            [gate hooksAreOwnedLocked];
        os_unfair_lock_unlock(&gate->_stateLock);

        BOOL paused = NO;
        BOOL deactivated = NO;
        if (mayApply) {
            for (AVPlayer *player in players) [player pause];
            for (AVAudioPlayer *player in audioPlayers) [player pause];
            for (AVAudioEngine *engine in audioEngines) [engine pause];
            paused = YES;

            os_unfair_lock_lock(&gate->_stateLock);
            BOOL mayDeactivate = gate.held && !gate.invalidated && gate.holdApplying &&
                gate.activeToken && [gate.activeToken isEqual:token] &&
                NSProcessInfo.processInfo.systemUptime < gate.activeDeadlineUptime &&
                [gate hooksAreOwnedLocked];
            os_unfair_lock_unlock(&gate->_stateLock);
            if (mayDeactivate) deactivated = [gate deactivateAudioSessionForHold];
        }
        [gate completeHoldApplicationForToken:token paused:paused deactivated:deactivated completion:completion];
    });
}

- (BOOL)endHoldWithToken:(NSUUID *)token {
    if (![token isKindOfClass:NSUUID.class]) return NO;

    void (^expiration)(void) = nil;
    BOOL ended = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!self.held || self.invalidated || self.holdApplying || !self.activeToken || ![self.activeToken isEqual:token]) {
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    if (NSProcessInfo.processInfo.systemUptime >= self.activeDeadlineUptime) {
        expiration = [self finishExpirationLockedForToken:token];
        os_unfair_lock_unlock(&_stateLock);
        [self deliverExpiration:expiration];
        return NO;
    }
    if (![self hooksAreOwnedLocked]) {
        self.invalidated = YES;
        self.held = YES;
        [self cancelExpirationTimerLocked];
        self.activeToken = nil;
        self.expirationHandler = nil;
        self.activeDeadlineUptime = 0;
        os_unfair_lock_unlock(&_stateLock);
        [self pauseTrackedMedia];
        return NO;
    }

    [self cancelExpirationTimerLocked];
    self.activeToken = nil;
    self.expirationHandler = nil;
    self.activeDeadlineUptime = 0;
    self.held = NO;
    ended = YES;
    os_unfair_lock_unlock(&_stateLock);
    return ended;
}

- (void)invalidateGate {
    os_unfair_lock_lock(&_stateLock);
    self.invalidated = YES;
    self.held = YES;
    [self cancelExpirationTimerLocked];
    self.activeToken = nil;
    self.expirationHandler = nil;
    self.activeDeadlineUptime = 0;
    self.holdApplying = NO;
    os_unfair_lock_unlock(&_stateLock);
    [self pauseTrackedMedia];
}

- (void)cancelExpirationTimerLocked {
    if (self.expirationTimer) {
        dispatch_source_cancel(self.expirationTimer);
        self.expirationTimer = nil;
    }
}

- (nullable void (^)(void))finishExpirationLockedForToken:(NSUUID *)token {
    if (!self.activeToken || ![self.activeToken isEqual:token] || !self.held || self.invalidated) return nil;
    void (^handler)(void) = self.expirationHandler;
    self.invalidated = YES;
    self.held = YES;
    self.holdApplying = NO;
    self.activeToken = nil;
    self.expirationHandler = nil;
    self.activeDeadlineUptime = 0;
    [self cancelExpirationTimerLocked];
    return handler;
}

- (void)expireHoldForToken:(NSUUID *)token {
    void (^expiration)(void) = nil;
    os_unfair_lock_lock(&_stateLock);
    if (!self.activeToken || ![self.activeToken isEqual:token] || !self.held || self.invalidated) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    NSTimeInterval remaining = self.activeDeadlineUptime - NSProcessInfo.processInfo.systemUptime;
    if (remaining > 0.0 && self.expirationTimer) {
        uint64_t nanoseconds = (uint64_t)MAX(1.0, ceil(remaining * (NSTimeInterval)NSEC_PER_SEC));
        dispatch_source_set_timer(self.expirationTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanoseconds), DISPATCH_TIME_FOREVER, 0);
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    expiration = [self finishExpirationLockedForToken:token];
    os_unfair_lock_unlock(&_stateLock);
    [self deliverExpiration:expiration];
}

- (void)deliverExpiration:(nullable void (^)(void))handler {
    if (!handler) return;
    dispatch_async(self.controlQueue, ^{ handler(); });
}

- (BOOL)beginMediaEntryForObject:(nullable id)object kind:(CVLPMediaKind)kind {
    void (^expiration)(void) = nil;
    BOOL shouldBlock = YES;
    BOOL requestPause = NO;
    os_unfair_lock_lock(&_stateLock);
    if (self.held && !self.invalidated && self.activeToken &&
        NSProcessInfo.processInfo.systemUptime >= self.activeDeadlineUptime) {
        expiration = [self finishExpirationLockedForToken:self.activeToken];
    }

    if (!self.installed || ![self hooksAreOwnedLocked]) {
        if (self.installed) {
            self.invalidated = YES;
            self.held = YES;
            [self cancelExpirationTimerLocked];
            self.activeToken = nil;
            self.expirationHandler = nil;
            self.activeDeadlineUptime = 0;
            requestPause = YES;
        }
    } else if (!self.held && !self.invalidated && self.inFlightEntries < CVLPMediaRegistryLimit) {
        NSHashTable *registry = nil;
        switch (kind) {
            case CVLPMediaKindPlayer: registry = self.players; break;
            case CVLPMediaKindAudioPlayer: registry = self.audioPlayers; break;
            case CVLPMediaKindAudioEngine: registry = self.audioEngines; break;
        }
        BOOL tracked = YES;
        if (object && registry && ![registry containsObject:object]) {
            if (registry.count >= CVLPMediaRegistryLimit) {
                tracked = NO;
            } else {
                [registry addObject:object];
                tracked = [registry containsObject:object];
            }
        }
        if (tracked) {
            self.inFlightEntries += 1;
            shouldBlock = NO;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    [self deliverExpiration:expiration];
    if (requestPause) [self pauseTrackedMedia];
    return !shouldBlock;
}

- (BOOL)beginSessionActivation {
    return [self beginMediaEntryForObject:nil kind:CVLPMediaKindPlayer];
}

- (void)endMediaEntry {
    os_unfair_lock_lock(&_stateLock);
    if (self.inFlightEntries > 0) self.inFlightEntries -= 1;
    os_unfair_lock_unlock(&_stateLock);
}

- (BOOL)deactivateAudioSessionForHold {
    IMP original = CVLPAVAudioSessionSetActiveOriginal;
    if (!original) return NO;

    NSError *error = nil;
    BOOL deactivated = ((BOOL (*)(id, SEL, BOOL, NSError **))original)(
        AVAudioSession.sharedInstance, @selector(setActive:error:), NO, &error);
    if (deactivated) return YES;

    // Apple documents this exact result as a completed deactivation when audio
    // objects were still running. Other false results remain unproved.
    return error && [error.domain isEqualToString:NSOSStatusErrorDomain] &&
        error.code == AVAudioSessionErrorCodeIsBusy;
}

- (void)completeHoldApplicationForToken:(NSUUID *)token
                                  paused:(BOOL)paused
                             deactivated:(BOOL)deactivated
                              completion:(void (^)(BOOL applied))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^expiration)(void) = nil;
        BOOL applied = NO;
        BOOL shouldPause = NO;
        os_unfair_lock_lock(&self->_stateLock);
        BOOL tokenMatches = self.activeToken && [self.activeToken isEqual:token];
        BOOL holdCurrent = tokenMatches && self.held && !self.invalidated && self.holdApplying;
        BOOL hooksOwned = [self hooksAreOwnedLocked];
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;

        if (holdCurrent && now >= self.activeDeadlineUptime) {
            expiration = [self finishExpirationLockedForToken:token];
        } else if (holdCurrent && paused && deactivated && hooksOwned) {
            // This is the only path that can acknowledge application. Check
            // token, deadline, and hook ownership on main immediately before YES.
            self.holdApplying = NO;
            applied = YES;
        } else if (holdCurrent) {
            self.invalidated = YES;
            self.held = YES;
            self.holdApplying = NO;
            [self cancelExpirationTimerLocked];
            self.activeToken = nil;
            self.expirationHandler = nil;
            self.activeDeadlineUptime = 0;
            shouldPause = YES;
        }
        os_unfair_lock_unlock(&self->_stateLock);

        if (shouldPause) [self pauseTrackedMedia];
        [self deliverExpiration:expiration];
        completion(applied);
    });
}

- (void)pauseTrackedMedia {
    os_unfair_lock_lock(&_stateLock);
    if (self.pauseRequestScheduled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    self.pauseRequestScheduled = YES;
    os_unfair_lock_unlock(&_stateLock);

    CVLPCooperativeMediaGate *gate = self;
    dispatch_async(self.mediaQueue, ^{
        NSArray<AVPlayer *> *players = nil;
        NSArray<AVAudioPlayer *> *audioPlayers = nil;
        NSArray<AVAudioEngine *> *audioEngines = nil;
        os_unfair_lock_lock(&gate->_stateLock);
        BOOL owned = [gate hooksAreOwnedLocked];
        if (!owned) {
            gate.invalidated = YES;
            gate.held = YES;
        }
        players = gate.players.allObjects;
        audioPlayers = gate.audioPlayers.allObjects;
        audioEngines = gate.audioEngines.allObjects;
        os_unfair_lock_unlock(&gate->_stateLock);
        if (owned) {
            for (AVPlayer *player in players) [player pause];
            for (AVAudioPlayer *player in audioPlayers) [player pause];
            for (AVAudioEngine *engine in audioEngines) [engine pause];
        }
        os_unfair_lock_lock(&gate->_stateLock);
        gate.pauseRequestScheduled = NO;
        os_unfair_lock_unlock(&gate->_stateLock);
    });
}

@end
