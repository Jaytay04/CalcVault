#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Synthetic-only observations for the disposable LiveProcess guest experiment.
@interface CVLPProbe : NSObject

/// Creates fresh synthetic fixtures and stages the signed guest payload. Returns a sanitized error on failure.
+ (nullable NSString *)prepareHost;

/// Returns non-secret launch metadata for the LiveProcess adapter.
+ (NSDictionary<NSString *, id> *)launchInfo;

/// Installs launch metadata and captures Security's original copy function before loader hooks run.
+ (void)acceptLaunchInfo:(NSDictionary<NSString *, id> *)launchInfo;

/// Runs synthetic file and Keychain probes for one allowlisted lifecycle stage.
+ (NSString *)recordStage:(NSString *)stage;

/// Returns host setup and post-guest observations without fixture values or entitlement identifiers.
+ (NSString *)hostSummary;

@end

NS_ASSUME_NONNULL_END
