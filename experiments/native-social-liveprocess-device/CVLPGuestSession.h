#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One research-only synthetic guest launch. Keep the instance until settled or host restart.
@interface CVLPGuestSession : NSObject
@property(nonatomic, readonly) UIViewController *viewController;
@property(nonatomic, readonly) NSString *summary;
@property(nonatomic, readonly, getter=isSettled) BOOL settled;
@property(nonatomic, readonly, getter=isVerificationSignalProbeAvailable) BOOL verificationSignalProbeAvailable;
/// Default-off native diagnostic. YES means a signal request can be submitted,
/// not that the OS has acknowledged suspension or media quiescence.
@property(nonatomic, readonly, getter=isNativeSignalDiagnosticAvailable) BOOL nativeSignalDiagnosticAvailable;
- (BOOL)requestNativeSignalDiagnostic:(int)signal NS_SWIFT_NAME(requestNativeSignalDiagnostic(_:));
- (void)startWithCompletion:(void (^)(BOOL success))completion NS_SWIFT_NAME(start(completion:));
- (BOOL)requestVerificationSignal:(int)signal NS_SWIFT_NAME(requestVerificationSignal(_:));
- (void)revoke;
@end

NS_ASSUME_NONNULL_END
