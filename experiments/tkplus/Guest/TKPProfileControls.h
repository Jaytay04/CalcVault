#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TKPProfileControlsStatus) {
    TKPProfileControlsStatusInstalled = 0,
    TKPProfileControlsStatusAlreadyInstalled,
    TKPProfileControlsStatusSuppressionEnabled,
    TKPProfileControlsStatusSuppressionDisabled,
    TKPProfileControlsStatusInvalidImageURL,
    TKPProfileControlsStatusMainThreadRequired,
    TKPProfileControlsStatusClassUnavailable,
    TKPProfileControlsStatusGetterUnavailable,
    TKPProfileControlsStatusInheritedGetter,
    TKPProfileControlsStatusSignatureMismatch,
    TKPProfileControlsStatusImageMismatch,
    TKPProfileControlsStatusHookConflict,
    TKPProfileControlsStatusNotInstalled,
};

/// Installs the two profile-view eligibility wrappers after validating the
/// exact runtime class, own instance methods, signatures, and trusted image.
/// The host must obtain expectedImageURL through its separately reviewed
/// profile and digest gate. This function does not establish package authenticity.
/// Installation is explicit and must run on the main thread. The wrappers stay
/// installed for the process lifetime; toggling suppression never restores an
/// implementation. No unload or unhook operation is provided.
/// If either method changes during installation, any wrapper still owned by
/// this module is rolled back and that process-lifetime install attempt becomes
/// terminal; a later call will not retry or replace the conflicting method.
FOUNDATION_EXPORT TKPProfileControlsStatus
TKPProfileControlsInstall(NSURL *expectedImageURL);

/// Enables or disables suppression for only the two validated eligibility
/// checks. Suppression defaults to OFF. State changes must run on the main
/// thread. Wrappers may execute on other threads: their suppression flag and
/// saved original IMPs use atomic access. The module does not protect against
/// a hostile concurrent runtime swizzle; a detected replacement disables
/// suppression and is reported without reclaiming the method.
FOUNDATION_EXPORT TKPProfileControlsStatus
TKPProfileControlsSetSuppressionEnabled(BOOL enabled);

FOUNDATION_EXPORT BOOL TKPProfileControlsSuppressionEnabled(void);

/// Returns a fixed diagnostic string for a status; it never includes paths.
FOUNDATION_EXPORT NSString *
TKPProfileControlsDiagnostic(TKPProfileControlsStatus status);

NS_ASSUME_NONNULL_END
