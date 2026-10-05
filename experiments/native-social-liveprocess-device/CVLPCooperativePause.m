#import "CVLPCooperativePause.h"
#import "CVLPLiveness.h"
#import <unistd.h>

NSXPCConnection *CVLPCreateGuestMediaHoldConnection(NSXPCListenerEndpoint *endpoint,
    NSUUID *launch, id<CVLPGuestMediaHoldControl> control,
    void (^lostControl)(void), void (^startupReply)(BOOL)) {
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldControl)];
    connection.exportedObject = control;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldBootstrap)];
    __block BOOL startupFinished = NO; // Accessed only on main, including errors and timeout.
    void (^finishStartup)(BOOL) = ^(BOOL registered) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (startupFinished) return;
            startupFinished = YES;
            startupReply(registered);
        });
    };
    void (^lost)(void) = ^{
        finishStartup(NO);
        dispatch_async(dispatch_get_main_queue(), lostControl);
    };
    connection.interruptionHandler = lost;
    connection.invalidationHandler = lost;
    [connection resume];
    id<CVLPGuestMediaHoldBootstrap> bootstrap = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        finishStartup(NO);
    }];
    // Apple's listener delegate is invoked for the first actual message, not resume().
    [bootstrap announceForLaunch:launch reply:^(BOOL registered) { finishStartup(registered); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!startupFinished) finishStartup(NO);
    });
    return connection;
}

#if defined(CVLP_COOPERATIVE_GUEST)
#import "CVLPCooperativeMediaGate.m"

@interface CVLPGuestMediaHoldEndpoint : NSObject <CVLPGuestMediaHoldControl>
@property(nonatomic, strong) NSUUID *launchToken;
@end
@implementation CVLPGuestMediaHoldEndpoint
- (void)holdForLaunch:(NSUUID *)launch hold:(NSUUID *)hold duration:(double)duration
               reply:(void (^)(BOOL, int))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL allowed = [launch isKindOfClass:NSUUID.class] &&
            [hold isKindOfClass:NSUUID.class] && [launch isEqual:self.launchToken];
        if (!allowed) { reply(NO, (int)getpid()); return; }
        [CVLPCooperativeMediaGate beginHoldWithToken:hold
            maximumDuration:duration completion:^(BOOL applied) {
                reply(applied, (int)getpid());
            } expiration:^{
                // Expiration never resumes media. The host also has an independent deadline.
                [CVLPCooperativeMediaGate invalidate];
                _exit(102);
            }];
    });
}
- (void)releaseForLaunch:(NSUUID *)launch hold:(NSUUID *)hold
                  reply:(void (^)(BOOL, int))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL allowed = [launch isKindOfClass:NSUUID.class] &&
            [hold isKindOfClass:NSUUID.class] && [launch isEqual:self.launchToken];
        BOOL released = allowed && [CVLPCooperativeMediaGate endHoldWithToken:hold];
        reply(released, (int)getpid());
    });
}
@end

static NSXPCConnection *CVLPMediaControlConnection;
BOOL CVLPInstallGuestMediaHoldControl(NSDictionary *launchInfo) {
    id endpoint = launchInfo[@"cvlpMediaHoldEndpoint"];
    id token = launchInfo[@"cvlpMediaHoldLaunch"];
    if (!endpoint && !token) return YES; // Default-off, including ordinary synthetic guests.
    if (CVLPMediaControlConnection || ![endpoint isKindOfClass:NSXPCListenerEndpoint.class] ||
        ![token isKindOfClass:NSUUID.class] || ![CVLPCooperativeMediaGate install]) return NO;
    CVLPGuestMediaHoldEndpoint *control = [CVLPGuestMediaHoldEndpoint new];
    control.launchToken = token;
    // The only remote host method is content-free registration, not a Vault service.
    void (^lostControl)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [CVLPCooperativeMediaGate invalidate];
            _exit(103);
        });
    };
    CVLPMediaControlConnection = CVLPCreateGuestMediaHoldConnection(endpoint, token, control, lostControl,
        ^(BOOL registered) {
            NSLog(@"CVLP_MEDIA_STARTUP registered=%d", registered);
            if (!registered) {
                [CVLPCooperativeMediaGate invalidate];
                _exit(104);
            }
        });
    return YES;
}
#else

@interface CVLPCooperativePauseClient ()
@property(nonatomic, strong) NSXPCListener *listener;
@property(atomic, strong) NSXPCConnection *connection;
@property(nonatomic, strong) NSUUID *launchToken;
@property(nonatomic, strong) NSUUID *holdToken;
@property(nonatomic, strong) NSLock *connectionLock;
@property(nonatomic) BOOL acceptedConnection;
@property(nonatomic) BOOL bootstrapReceived;
@property(nonatomic, copy) NSString *startupFailureReason;
@property(atomic) BOOL invalidated;
@property(atomic) BOOL transportLost;
@property(nonatomic) BOOL pauseAttempted;
@property(nonatomic) BOOL resumeAttempted;
@property(nonatomic) BOOL held;
@property(nonatomic) NSUInteger operation;
@property(nonatomic, copy) void (^pendingReply)(BOOL);
- (void)failConnection;
- (void)registerLaunch:(NSUUID *)launch connection:(NSXPCConnection *)connection
                 reply:(void (^)(BOOL))reply;
@end

@interface CVLPMediaBootstrapReceiver : NSObject <CVLPGuestMediaHoldBootstrap>
@property(nonatomic, weak) CVLPCooperativePauseClient *owner;
@end
@implementation CVLPMediaBootstrapReceiver
- (void)announceForLaunch:(NSUUID *)launch reply:(void (^)(BOOL))reply {
    // Capture the authenticated connection while on its invocation queue.
    NSXPCConnection *connection = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        CVLPCooperativePauseClient *owner = self.owner;
        if (!owner) { reply(NO); return; }
        [owner registerLaunch:launch connection:connection reply:reply];
    });
}
@end

@implementation CVLPCooperativePauseClient
- (instancetype)init {
    if ((self = [super init])) {
        _launchToken = NSUUID.UUID;
        _connectionLock = [NSLock new];
        _listener = NSXPCListener.anonymousListener;
        _listener.delegate = self;
        [_listener resume];
    }
    return self;
}
- (NSXPCListenerEndpoint *)endpoint { return self.listener.endpoint; }
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    // The guest may connect before the extension begin callback supplies its PID.
    // Accept at most one candidate; no command is sent until the OS peer PID matches.
    [self.connectionLock lock];
    BOOL accept = !self.invalidated && !self.transportLost && !self.acceptedConnection && listener == self.listener;
    if (accept) self.acceptedConnection = YES;
    [self.connectionLock unlock];
    if (!accept) return NO;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldControl)];
    CVLPMediaBootstrapReceiver *bootstrap = [CVLPMediaBootstrapReceiver new];
    bootstrap.owner = self;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldBootstrap)];
    connection.exportedObject = bootstrap;
    __weak typeof(self) weakSelf = self;
    void (^lostControl)(void) = ^{
        // Fence readiness immediately on the XPC queue, before main-queue cleanup.
        weakSelf.transportLost = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failConnection]; });
    };
    connection.interruptionHandler = lostControl;
    connection.invalidationHandler = lostControl;
    [self.connectionLock lock];
    BOOL stillValid = !self.invalidated && !self.transportLost;
    if (stillValid) {
        self.connection = connection;
        [connection resume];
    }
    [self.connectionLock unlock];
    return stillValid;
}
- (void)registerLaunch:(NSUUID *)launch connection:(NSXPCConnection *)connection
                 reply:(void (^)(BOOL))reply {
    NSAssert(NSThread.isMainThread, @"Media registration must run on main");
    BOOL valid = !self.invalidated && !self.transportLost && connection && connection == self.connection &&
        [launch isKindOfClass:NSUUID.class] && [launch isEqual:self.launchToken] &&
        !self.bootstrapReceived;
    if (!valid) {
        self.startupFailureReason = self.bootstrapReceived ? @"duplicate-startup" : @"startup-rejected";
        reply(NO);
        [self failConnection];
        return;
    }
    // Receipt is not authorization. Only peerIsCurrent: may enable media commands.
    self.bootstrapReceived = YES;
    reply(YES);
}
- (BOOL)peerIsCurrent:(int)pid {
    return !self.invalidated && !self.transportLost && self.bootstrapReceived && pid > 0 && self.connection &&
        self.connection.processIdentifier == pid && CVLPProcessPresenceObserved(CVLPSampleLiveness(pid));
}
- (BOOL)isAvailableForPID:(int)pid {
    NSAssert(NSThread.isMainThread, @"Media control must run on main");
    return !self.pauseAttempted && [self peerIsCurrent:pid];
}
- (NSString *)diagnosticForPID:(int)pid {
    NSAssert(NSThread.isMainThread, @"Media diagnostics must run on main");
    BOOL connected = self.connection != nil;
    BOOL peerMatch = connected && pid > 0 && self.connection.processIdentifier == pid;
    BOOL presence = pid > 0 && CVLPProcessPresenceObserved(CVLPSampleLiveness(pid));
    NSString *reason = self.startupFailureReason ?: (self.transportLost ? @"connection-lost" : (self.invalidated ? @"invalidated" :
        (!connected ? @"waiting-connection" : (!self.bootstrapReceived ? @"waiting-startup" :
        (!peerMatch ? @"peer-mismatch" : (!presence ? @"presence-unproved" :
        (self.pauseAttempted ? @"pause-consumed" : @"ready")))))));
    return [NSString stringWithFormat:@"connection=%d startup=%d peerMatch=%d presence=%d invalidated=%d reason=%@",
        connected, self.bootstrapReceived, peerMatch, presence, self.invalidated, reason];
}
- (void)finishOperation:(NSUInteger)operation pid:(int)pid reportedPID:(int)reportedPID
                success:(BOOL)success pausing:(BOOL)pausing {
    NSAssert(NSThread.isMainThread, @"Media control replies must run on main");
    if (self.invalidated || self.operation != operation || !self.pendingReply) return;
    BOOL accepted = success && reportedPID == pid && [self peerIsCurrent:pid];
    self.held = accepted && pausing;
    void (^reply)(BOOL) = self.pendingReply;
    self.pendingReply = nil;
    if (!accepted) [self invalidate];
    reply(accepted);
}
- (void)failConnection {
    if (self.invalidated) return;
    void (^reply)(BOOL) = self.pendingReply;
    void (^failure)(void) = self.failureHandler;
    self.pendingReply = nil;
    [self invalidate];
    if (reply) reply(NO);
    if (failure) failure();
}
- (NSUInteger)beginOperation:(void (^)(BOOL))reply {
    self.pendingReply = reply;
    NSUInteger operation = ++self.operation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.invalidated || self.operation != operation || !self.pendingReply) return;
        [self failConnection];
    });
    return operation;
}
- (void)pauseForPID:(int)pid reply:(void (^)(BOOL))reply {
    NSAssert(NSThread.isMainThread, @"Media control must run on main");
    if (![self isAvailableForPID:pid]) { reply(NO); return; }
    self.pauseAttempted = YES;
    self.holdToken = NSUUID.UUID;
    NSUInteger operation = [self beginOperation:reply];
    __weak typeof(self) weakSelf = self;
    id<CVLPGuestMediaHoldControl> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failConnection]; });
    }];
    [proxy holdForLaunch:self.launchToken hold:self.holdToken duration:120 reply:^(BOOL success, int reportedPID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation:operation pid:pid reportedPID:reportedPID success:success pausing:YES];
        });
    }];
}
- (void)resumeForPID:(int)pid reply:(void (^)(BOOL))reply {
    NSAssert(NSThread.isMainThread, @"Media control must run on main");
    if (!self.held || self.resumeAttempted || self.pendingReply || ![self peerIsCurrent:pid]) {
        reply(NO); return;
    }
    self.resumeAttempted = YES;
    NSUInteger operation = [self beginOperation:reply];
    __weak typeof(self) weakSelf = self;
    id<CVLPGuestMediaHoldControl> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failConnection]; });
    }];
    [proxy releaseForLaunch:self.launchToken hold:self.holdToken reply:^(BOOL success, int reportedPID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation:operation pid:pid reportedPID:reportedPID success:success pausing:NO];
        });
    }];
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Media control invalidation must run on main");
    [self.connectionLock lock];
    self.invalidated = YES;
    [self.connectionLock unlock];
    ++self.operation;
    void (^reply)(BOOL) = self.pendingReply;
    self.pendingReply = nil;
    self.failureHandler = nil;
    [self.connection invalidate];
    [self.listener invalidate];
    // Resolve at most once after every authority is revoked; late XPC replies
    // cannot restore the operation. Terminal callers may safely reenter here.
    if (reply) reply(NO);
}
- (void)dealloc {
    _invalidated = YES;
    [_connection invalidate];
    [_listener invalidate];
}
@end
#endif
