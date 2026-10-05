#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One research-only synthetic guest launch. Keep the instance until settled or host restart.
@interface CVLPGuestSession : NSObject
@property(nonatomic, readonly) UIViewController *viewController;
@property(nonatomic, readonly) NSString *summary;
@property(nonatomic, readonly, getter=isSettled) BOOL settled;
/// Called once when the extension scene ends unexpectedly. Explicit revoke is not an unexpected exit.
@property(nonatomic, copy, nullable) void (^terminationHandler)(void);
@property(nonatomic, readonly, getter=isVerificationSignalProbeAvailable) BOOL verificationSignalProbeAvailable;
/// Default-off native diagnostic. YES means a signal request can be submitted,
/// not that the OS has acknowledged suspension or media quiescence.
@property(nonatomic, readonly, getter=isNativeSignalDiagnosticAvailable) BOOL nativeSignalDiagnosticAvailable;
- (BOOL)requestNativeSignalDiagnostic:(int)signal NS_SWIFT_NAME(requestNativeSignalDiagnostic(_:));
/// Default-off cooperative known-media gate, not proof of universal media quiescence.
@property(nonatomic, readonly, getter=isCooperativePauseAvailable) BOOL cooperativePauseAvailable;
- (void)pauseMediaWithCompletion:(void (^)(BOOL applied))completion NS_SWIFT_NAME(pauseMedia(completion:));
- (void)resumeMediaWithCompletion:(void (^)(BOOL released))completion NS_SWIFT_NAME(resumeMedia(completion:));
- (void)startWithCompletion:(void (^)(BOOL success))completion NS_SWIFT_NAME(start(completion:));
- (BOOL)requestVerificationSignal:(int)signal NS_SWIFT_NAME(requestVerificationSignal(_:));
- (void)revoke;
@end

NS_ASSUME_NONNULL_END
