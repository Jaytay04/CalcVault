#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Content-free commands only. Neither side exports host authentication or storage.
@protocol CVLPGuestMediaHoldControl
- (void)holdForLaunch:(NSUUID *)launch hold:(NSUUID *)hold duration:(double)duration
               reply:(void (^)(BOOL applied, int pid))reply;
- (void)releaseForLaunch:(NSUUID *)launch hold:(NSUUID *)hold
                  reply:(void (^)(BOOL released, int pid))reply;
@end

/// Registration only. This receiver has no authentication, storage or command authority.
@protocol CVLPGuestMediaHoldBootstrap
- (void)announceForLaunch:(NSUUID *)launch reply:(void (^)(BOOL registered))reply;
@end

/// Starts the connection with an actual message; resume alone cannot notify a listener.
NSXPCConnection *CVLPCreateGuestMediaHoldConnection(NSXPCListenerEndpoint *endpoint,
    NSUUID *launch, id<CVLPGuestMediaHoldControl> control,
    void (^lostControl)(void), void (^startupReply)(BOOL registered));

/// One anonymous endpoint and one connection per existing extension request.
@interface CVLPCooperativePauseClient : NSObject <NSXPCListenerDelegate>
@property(nonatomic, readonly) NSXPCListenerEndpoint *endpoint;
@property(nonatomic, readonly) NSUUID *launchToken;
@property(nonatomic, copy, nullable) void (^failureHandler)(void);
- (BOOL)isAvailableForPID:(int)pid;
- (NSString *)diagnosticForPID:(int)pid;
- (void)pauseForPID:(int)pid reply:(void (^)(BOOL))reply;
- (void)resumeForPID:(int)pid reply:(void (^)(BOOL))reply;
- (void)invalidate;
@end

/// Called only in LiveProcess, before entering the guest application.
BOOL CVLPInstallGuestMediaHoldControl(NSDictionary *launchInfo);

NS_ASSUME_NONNULL_END
