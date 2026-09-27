#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One research-only synthetic guest launch. Keep the instance until settled or host restart.
@interface CVLPGuestSession : NSObject
@property(nonatomic, readonly) UIViewController *viewController;
@property(nonatomic, readonly) NSString *summary;
@property(nonatomic, readonly, getter=isSettled) BOOL settled;
- (void)startWithCompletion:(void (^)(BOOL success))completion NS_SWIFT_NAME(start(completion:));
- (void)revoke;
@end

NS_ASSUME_NONNULL_END
