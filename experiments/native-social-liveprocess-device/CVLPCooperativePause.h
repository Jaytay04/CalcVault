#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Content-free commands only. Neither side exports host authentication or storage.
@protocol CVLPGuestMediaHoldControl
- (void)holdForLaunch:(NSUUID *)launch hold:(NSUUID *)hold duration:(double)duration
               reply:(void (^)(BOOL applied, int pid))reply;
- (void)releaseForLaunch:(NSUUID *)launch hold:(NSUUID *)hold
                  reply:(void (^)(BOOL released, int pid))reply;
@end

/// One anonymous endpoint and one connection per existing extension request.
@interface CVLPCooperativePauseClient : NSObject <NSXPCListenerDelegate>
@property(nonatomic, readonly) NSXPCListenerEndpoint *endpoint;
@property(nonatomic, readonly) NSUUID *launchToken;
@property(nonatomic, copy, nullable) void (^failureHandler)(void);
- (BOOL)isAvailableForPID:(int)pid;
- (void)pauseForPID:(int)pid reply:(void (^)(BOOL))reply;
- (void)resumeForPID:(int)pid reply:(void (^)(BOOL))reply;
- (void)invalidate;
@end

/// Called only in LiveProcess, before entering the guest application.
BOOL CVLPInstallGuestMediaHoldControl(NSDictionary *launchInfo);

NS_ASSUME_NONNULL_END
