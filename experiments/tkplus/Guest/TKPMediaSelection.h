#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TKPSelectedMediaKind) {
    TKPSelectedMediaJPEG = 1,
    TKPSelectedMediaPNG = 2,
    TKPSelectedMediaMP4 = 3,
};

typedef NS_ENUM(NSInteger, TKPMediaSelectionFailure) {
    TKPMediaSelectionInvalidInput = 1,
    TKPMediaSelectionUnsupportedKind,
    TKPMediaSelectionInvalidHostPolicy,
    TKPMediaSelectionNoApprovedOriginal,
};

FOUNDATION_EXPORT NSString *const TKPMediaSelectionErrorDomain;

/// An explicit selection, not permission to access Vault or fetch a URL.
/// URL query strings can be sensitive. Never log or serialize this to the host.
@interface TKPSelectedMedia : NSObject
@property(nonatomic, readonly) NSURL *originalURL;
@property(nonatomic, readonly) TKPSelectedMediaKind kind;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Returns the first policy-approved original in source order, without resizing,
/// transcoding, filename quality guesses or cached/display-image fallback.
/// Caller supplies an independently reviewed exact-host CDN policy. All rows and
/// the host policy are bounded/validated; malformed input is not silently truncated.
/// No requests, cookies, provider endpoints, private model calls or file writes occur.
FOUNDATION_EXPORT TKPSelectedMedia *_Nullable TKPSelectOriginalMedia(
    NSArray<NSString *> *originURLs,
    TKPSelectedMediaKind kind,
    NSSet<NSString *> *approvedHosts,
    NSError *_Nullable *_Nullable error
);

NS_ASSUME_NONNULL_END
