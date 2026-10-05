#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A cooperative, process-local media pause gate for the native diagnostic.
/// A successful result means interception was installed or the hold was applied;
/// it does not prove that every system or third-party media path is quiescent.
@interface CVLPCooperativeMediaGate : NSObject

+ (BOOL)install;
/// Must run on the main thread. YES is returned only after tracked media has
/// been paused and the app audio session deactivated or its documented isBusy
/// deactivation result has been verified.
+ (BOOL)beginHoldWithToken:(NSUUID *)token
           maximumDuration:(NSTimeInterval)duration
                 expiration:(void (^)(void))expiration;
+ (BOOL)endHoldWithToken:(NSUUID *)token;
+ (void)invalidate;

@end

NS_ASSUME_NONNULL_END
