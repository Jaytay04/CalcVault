#import <Foundation/Foundation.h>
#import <unistd.h>
#include <stdio.h>
#import "../CVLPCooperativePause.h"

static BOOL CVLPWaitForFlag(BOOL (^condition)(void), NSTimeInterval timeout);

@interface CVLPFakeMediaControl : NSObject <CVLPGuestMediaHoldControl>
@property(nonatomic, strong) NSUUID *expectedLaunch;
@property(nonatomic, strong) NSUUID *receivedHoldLaunch;
@property(nonatomic, strong) NSUUID *receivedHoldToken;
@property(nonatomic, strong) NSUUID *receivedReleaseLaunch;
@property(nonatomic, strong) NSUUID *receivedReleaseToken;
@property(nonatomic) double receivedDuration;
@property(nonatomic) NSUInteger holdCallCount;
@property(nonatomic) NSUInteger releaseCallCount;
@property(nonatomic) BOOL holding;
@property(nonatomic) BOOL holdArgumentsValid;
@property(nonatomic) BOOL releaseArgumentsValid;
@end

@implementation CVLPFakeMediaControl
- (void)holdForLaunch:(NSUUID *)launch hold:(NSUUID *)hold duration:(double)duration
               reply:(void (^)(BOOL, int))reply {
    BOOL valid = [launch isEqual:self.expectedLaunch] &&
        [hold isKindOfClass:NSUUID.class] && duration == 120.0;
    @synchronized (self) {
        self.holdCallCount += 1;
        self.receivedHoldLaunch = launch;
        self.receivedHoldToken = hold;
        self.receivedDuration = duration;
        self.holdArgumentsValid = valid && !self.holding;
        if (self.holdArgumentsValid) self.holding = YES;
        valid = self.holdArgumentsValid;
    }
    reply(valid, (int)getpid());
}
- (void)releaseForLaunch:(NSUUID *)launch hold:(NSUUID *)hold
                  reply:(void (^)(BOOL, int))reply {
    @synchronized (self) {
        self.releaseCallCount += 1;
        self.receivedReleaseLaunch = launch;
        self.receivedReleaseToken = hold;
        self.releaseArgumentsValid = self.holding &&
            [launch isEqual:self.expectedLaunch] &&
            [launch isEqual:self.receivedHoldLaunch] &&
            [hold isEqual:self.receivedHoldToken];
        if (self.releaseArgumentsValid) self.holding = NO;
    }
    reply(self.releaseArgumentsValid, (int)getpid());
}
@end

@interface CVLPFixturePair : NSObject
@property(nonatomic, strong) CVLPCooperativePauseClient *client;
@property(nonatomic, strong) CVLPFakeMediaControl *guest;
@property(nonatomic, strong) NSXPCConnection *guestConnection;
@end

@implementation CVLPFixturePair
- (instancetype)init {
    if ((self = [super init])) {
        _client = [CVLPCooperativePauseClient new];
        _guest = [CVLPFakeMediaControl new];
        _guest.expectedLaunch = _client.launchToken;
    }
    return self;
}
- (BOOL)connectManually {
    self.guestConnection = [[NSXPCConnection alloc]
        initWithListenerEndpoint:self.client.endpoint];
    self.guestConnection.exportedInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(CVLPGuestMediaHoldControl)];
    self.guestConnection.exportedObject = self.guest;
    self.guestConnection.remoteObjectInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(CVLPGuestMediaHoldBootstrap)];
    [self.guestConnection resume];
    return self.guestConnection != nil;
}
- (BOOL)connectWithLaunch:(NSUUID *)launch registered:(BOOL *)registered {
    __block BOOL completed = NO;
    __block BOOL outcome = NO;
    self.guestConnection = CVLPCreateGuestMediaHoldConnection(
        self.client.endpoint, launch, self.guest, ^{}, ^(BOOL didRegister) {
            outcome = didRegister;
            completed = YES;
        });
    BOOL finished = CVLPWaitForFlag(^BOOL{ return completed; }, 3.0);
    if (registered) *registered = finished && outcome;
    return finished && self.guestConnection != nil;
}
- (BOOL)announceLaunch:(NSUUID *)launch registered:(BOOL *)registered {
    if (!self.guestConnection) return NO;
    __block BOOL completed = NO;
    __block BOOL outcome = NO;
    id<CVLPGuestMediaHoldBootstrap> bootstrap =
        [self.guestConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                outcome = NO;
                completed = YES;
            });
        }];
    [bootstrap announceForLaunch:launch reply:^(BOOL didRegister) {
        dispatch_async(dispatch_get_main_queue(), ^{
            outcome = didRegister;
            completed = YES;
        });
    }];
    BOOL finished = CVLPWaitForFlag(^BOOL{ return completed; }, 3.0);
    if (registered) *registered = finished && outcome;
    return finished;
}
- (void)invalidate {
    [self.client invalidate];
    [self.guestConnection invalidate];
}
@end

static BOOL CVLPWaitForFlag(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSCAssert(NSThread.isMainThread, @"Fixture run loop must be pumped on main");
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
    while (!condition() && deadline.timeIntervalSinceNow > 0.0) {
        NSDate *next = [NSDate dateWithTimeIntervalSinceNow:0.01];
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:
            [next earlierDate:deadline]];
    }
    return condition();
}

static void CVLPRecord(NSString *name, BOOL passed, NSUInteger *failures) {
    const char *label = name.UTF8String;
    fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", label);
    if (!passed) *failures += 1;
}

static BOOL CVLPResume(CVLPFixturePair *pair, int pid, BOOL expected) {
    __block BOOL completed = NO;
    __block BOOL outcome = NO;
    [pair.client resumeForPID:pid reply:^(BOOL success) {
        outcome = success;
        completed = YES;
    }];
    return CVLPWaitForFlag(^BOOL{ return completed; }, 3.0) && outcome == expected;
}

static BOOL CVLPPause(CVLPFixturePair *pair, int pid, BOOL expected) {
    __block BOOL completed = NO;
    __block BOOL outcome = NO;
    [pair.client pauseForPID:pid reply:^(BOOL success) {
        outcome = success;
        completed = YES;
    }];
    return CVLPWaitForFlag(^BOOL{ return completed; }, 3.0) && outcome == expected;
}

static NSUInteger CVLPHoldCalls(CVLPFakeMediaControl *guest) {
    @synchronized (guest) { return guest.holdCallCount; }
}

static NSUInteger CVLPReleaseCalls(CVLPFakeMediaControl *guest) {
    @synchronized (guest) { return guest.releaseCallCount; }
}

static BOOL CVLPTestResumeOnlyHasNoReadiness(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL connected = [pair connectManually];
    BOOL unavailable = ![pair.client isAvailableForPID:(int)getpid()];
    BOOL resumeRejected = CVLPResume(pair, (int)getpid(), NO);
    BOOL untouched = CVLPReleaseCalls(pair.guest) == 0;
    [pair invalidate];
    return connected && unavailable && resumeRejected && untouched;
}

static BOOL CVLPTestExplicitAnnouncementRegistersPeer(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = NO;
    BOOL connected = [pair connectWithLaunch:pair.client.launchToken
                                  registered:&registered];
    BOOL available = [pair.client isAvailableForPID:(int)getpid()];
    [pair invalidate];
    return connected && registered && available;
}

static BOOL CVLPTestWrongLaunchIsDenied(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = YES;
    BOOL connected = [pair connectWithLaunch:NSUUID.UUID registered:&registered];
    BOOL unavailable = ![pair.client isAvailableForPID:(int)getpid()];
    [pair invalidate];
    return connected && !registered && unavailable;
}

static BOOL CVLPTestWrongPassedPIDIsDenied(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = NO;
    BOOL connected = [pair connectWithLaunch:pair.client.launchToken
                                  registered:&registered];
    int wrongPID = (int)getpid() + 1;
    BOOL unavailable = ![pair.client isAvailableForPID:wrongPID];
    BOOL pauseRejected = CVLPPause(pair, wrongPID, NO);
    BOOL untouched = CVLPHoldCalls(pair.guest) == 0;
    [pair invalidate];
    return connected && registered && unavailable && pauseRejected && untouched;
}

static BOOL CVLPTestDuplicateAnnouncementFailsClosed(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL connected = [pair connectManually];
    BOOL firstRegistered = NO;
    BOOL firstFinished = [pair announceLaunch:pair.client.launchToken
                                   registered:&firstRegistered];
    BOOL secondRegistered = YES;
    BOOL secondFinished = [pair announceLaunch:pair.client.launchToken
                                    registered:&secondRegistered];
    BOOL unavailable = ![pair.client isAvailableForPID:(int)getpid()];
    [pair invalidate];
    return connected && firstFinished && firstRegistered && secondFinished &&
        !secondRegistered && unavailable;
}

static BOOL CVLPTestInvalidationRevokesReadiness(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = NO;
    BOOL connected = [pair connectWithLaunch:pair.client.launchToken
                                  registered:&registered];
    [pair.client invalidate];
    BOOL unavailable = ![pair.client isAvailableForPID:(int)getpid()];
    BOOL pauseRejected = CVLPPause(pair, (int)getpid(), NO);
    BOOL untouched = CVLPHoldCalls(pair.guest) == 0;
    [pair.guestConnection invalidate];
    return connected && registered && unavailable && pauseRejected && untouched;
}

static BOOL CVLPTestPauseAndReleaseUseValidatedTokens(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = NO;
    BOOL connected = [pair connectWithLaunch:pair.client.launchToken
                                  registered:&registered];
    BOOL paused = CVLPPause(pair, (int)getpid(), YES);
    BOOL holdValid = NO;
    @synchronized (pair.guest) {
        holdValid = pair.guest.holdCallCount == 1 &&
            pair.guest.holdArgumentsValid &&
            [pair.guest.receivedHoldLaunch isEqual:pair.client.launchToken] &&
            [pair.guest.receivedHoldToken isKindOfClass:NSUUID.class] &&
            pair.guest.receivedDuration == 120.0;
    }
    BOOL resumed = CVLPResume(pair, (int)getpid(), YES);
    BOOL releaseValid = NO;
    @synchronized (pair.guest) {
        releaseValid = pair.guest.releaseCallCount == 1 &&
            pair.guest.releaseArgumentsValid &&
            [pair.guest.receivedReleaseLaunch isEqual:pair.client.launchToken] &&
            [pair.guest.receivedReleaseToken isEqual:pair.guest.receivedHoldToken];
    }
    [pair invalidate];
    return connected && registered && paused && holdValid && resumed && releaseValid;
}

static BOOL CVLPTestReleaseBeforePauseIsRejected(void) {
    CVLPFixturePair *pair = [CVLPFixturePair new];
    BOOL registered = NO;
    BOOL connected = [pair connectWithLaunch:pair.client.launchToken
                                  registered:&registered];
    BOOL rejected = CVLPResume(pair, (int)getpid(), NO);
    BOOL guestUntouched = CVLPReleaseCalls(pair.guest) == 0;
    [pair invalidate];
    return connected && registered && rejected && guestUntouched;
}

int main(void) {
    @autoreleasepool {
        NSUInteger failures = 0;
        CVLPRecord(@"resume-only-has-no-readiness", CVLPTestResumeOnlyHasNoReadiness(), &failures);
        CVLPRecord(@"explicit-announcement-registers-peer", CVLPTestExplicitAnnouncementRegistersPeer(), &failures);
        CVLPRecord(@"wrong-launch-is-denied", CVLPTestWrongLaunchIsDenied(), &failures);
        CVLPRecord(@"wrong-passed-pid-is-denied", CVLPTestWrongPassedPIDIsDenied(), &failures);
        CVLPRecord(@"duplicate-announcement-fails-closed", CVLPTestDuplicateAnnouncementFailsClosed(), &failures);
        CVLPRecord(@"invalidation-revokes-readiness", CVLPTestInvalidationRevokesReadiness(), &failures);
        CVLPRecord(@"pause-release-validate-launch-hold-duration", CVLPTestPauseAndReleaseUseValidatedTokens(), &failures);
        CVLPRecord(@"release-before-pause-is-rejected", CVLPTestReleaseBeforePauseIsRejected(), &failures);
        if (failures == 0) {
            fprintf(stdout, "LIMIT same-process anonymous XPC fixture only; no cross-process, phone, or AV proof\n");
            return 0;
        }
        fprintf(stderr, "FAIL %lu cooperative bootstrap fixture case(s)\n", (unsigned long)failures);
        return 1;
    }
}
