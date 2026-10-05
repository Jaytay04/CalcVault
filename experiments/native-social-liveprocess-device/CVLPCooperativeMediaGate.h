#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A cooperative, process-local media pause gate for the native diagnostic.
/// A successful result means interception was installed or the hold was applied;
/// it does not prove that every system or third-party media path is quiescent.
@interface CVLPCooperativeMediaGate : NSObject

+ (BOOL)install;
/// Must run on the main thread. The gate closes before media work is queued.
/// Completion is delivered on the main thread and is YES only after tracked
/// media pause/audio-session deactivation succeeds and the hold remains current.
/// A caller timeout cannot cancel media work already running on the worker queue.
/// Completion runs on main; expiration runs on the independent control queue.
+ (void)beginHoldWithToken:(NSUUID *)token
           maximumDuration:(NSTimeInterval)duration
                completion:(void (^)(BOOL applied))completion
                expiration:(void (^)(void))expiration;
+ (BOOL)endHoldWithToken:(NSUUID *)token;
+ (void)invalidate;

@end

NS_ASSUME_NONNULL_END
