#import "CVLPCooperativePause.h"
#import "CVLPLiveness.h"
#import <unistd.h>

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
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldControl)];
    connection.exportedObject = control;
    // No remote host interface or generic host service is made available to the guest.
    void (^lostControl)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [CVLPCooperativeMediaGate invalidate];
            _exit(103);
        });
    };
    connection.interruptionHandler = lostControl;
    connection.invalidationHandler = lostControl;
    CVLPMediaControlConnection = connection;
    [connection resume];
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
@property(atomic) BOOL invalidated;
@property(nonatomic) BOOL pauseAttempted;
@property(nonatomic) BOOL resumeAttempted;
@property(nonatomic) BOOL held;
@property(nonatomic) NSUInteger operation;
@property(nonatomic, copy) void (^pendingReply)(BOOL);
- (void)failConnection;
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
    BOOL accept = !self.invalidated && !self.acceptedConnection && listener == self.listener;
    if (accept) self.acceptedConnection = YES;
    [self.connectionLock unlock];
    if (!accept) return NO;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(CVLPGuestMediaHoldControl)];
    __weak typeof(self) weakSelf = self;
    void (^lostControl)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failConnection]; });
    };
    connection.interruptionHandler = lostControl;
    connection.invalidationHandler = lostControl;
    [self.connectionLock lock];
    BOOL stillValid = !self.invalidated;
    if (stillValid) {
        self.connection = connection;
        [connection resume];
    }
    [self.connectionLock unlock];
    return stillValid;
}
- (BOOL)peerIsCurrent:(int)pid {
    return !self.invalidated && pid > 0 && self.connection &&
        self.connection.processIdentifier == pid && CVLPProcessPresenceObserved(CVLPSampleLiveness(pid));
}
- (BOOL)isAvailableForPID:(int)pid {
    NSAssert(NSThread.isMainThread, @"Media control must run on main");
    return !self.pauseAttempted && [self peerIsCurrent:pid];
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
