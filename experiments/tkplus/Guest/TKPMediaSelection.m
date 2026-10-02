#import "TKPMediaSelection.h"

NSString *const TKPMediaSelectionErrorDomain = @"TKPlus.MediaSelection";

@interface TKPSelectedMedia ()
- (instancetype)initWithURL:(NSURL *)URL kind:(TKPSelectedMediaKind)kind;
@end

@implementation TKPSelectedMedia
- (instancetype)initWithURL:(NSURL *)URL kind:(TKPSelectedMediaKind)kind {
    self = [super init];
    if (self) {
        _originalURL = [URL copy];
        _kind = kind;
    }
    return self;
}
@end

static TKPSelectedMedia *TKPReject(NSError **error, TKPMediaSelectionFailure code) {
    if (error) *error = [NSError errorWithDomain:TKPMediaSelectionErrorDomain
                                          code:code userInfo:nil];
    return nil;
}

static BOOL TKPValidHost(NSString *host) {
    if (![host isKindOfClass:NSString.class] || host.length > 253 || host.length < 4 ||
        ![host isEqualToString:host.lowercaseString]) return NO;
    NSArray<NSString *> *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"abcdefghijklmnopqrstuvwxyz0123456789-"];
    for (NSString *label in labels) {
        if (label.length == 0 || label.length > 63 || [label hasPrefix:@"-"] ||
            [label hasSuffix:@"-"] ||
            [label rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    }
    NSString *last = labels.lastObject;
    NSCharacterSet *letters = [NSCharacterSet characterSetWithCharactersInString:
                              @"abcdefghijklmnopqrstuvwxyz"];
    if (last.length < 2 || [last rangeOfCharacterFromSet:letters.invertedSet].location != NSNotFound)
        return NO;
    if ([last isEqualToString:@"local"] || [last isEqualToString:@"localhost"] ||
        [last isEqualToString:@"internal"]) return NO;
    return YES;
}

TKPSelectedMedia *TKPSelectOriginalMedia(NSArray<NSString *> *originURLs,
                                       TKPSelectedMediaKind kind,
                                       NSSet<NSString *> *approvedHosts,
                                       NSError **error) {
    if (error) *error = nil;
    if (kind != TKPSelectedMediaJPEG && kind != TKPSelectedMediaPNG && kind != TKPSelectedMediaMP4)
        return TKPReject(error, TKPMediaSelectionUnsupportedKind);
    if (![originURLs isKindOfClass:NSArray.class] || originURLs.count == 0 || originURLs.count > 32)
        return TKPReject(error, TKPMediaSelectionInvalidInput);
    if (![approvedHosts isKindOfClass:NSSet.class] || approvedHosts.count == 0 || approvedHosts.count > 32)
        return TKPReject(error, TKPMediaSelectionInvalidHostPolicy);
    for (NSString *host in approvedHosts) {
        if (!TKPValidHost(host)) return TKPReject(error, TKPMediaSelectionInvalidHostPolicy);
    }
    NSMutableCharacterSet *invalid = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [invalid formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    // Validate every row before returning any selection. A malformed tail cannot
    // be hidden behind a usable first entry.
    for (NSString *value in originURLs) {
        if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 8192 ||
            [value rangeOfCharacterFromSet:invalid].location != NSNotFound)
            return TKPReject(error, TKPMediaSelectionInvalidInput);
    }
    for (NSString *value in originURLs) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:value];
        NSString *host = parts.host.lowercaseString;
        if (![parts.scheme.lowercaseString isEqualToString:@"https"] ||
            parts.user != nil || parts.password != nil || parts.fragment != nil ||
            (parts.port != nil && parts.port.integerValue != 443) ||
            !TKPValidHost(host) || ![approvedHosts containsObject:host] ||
            parts.path.length == 0 || ![parts.path hasPrefix:@"/"]) continue;
        NSURL *URL = parts.URL;
        if (!URL || URL.isFileURL) continue;
        return [[TKPSelectedMedia alloc] initWithURL:URL kind:kind];
    }
    return TKPReject(error, TKPMediaSelectionNoApprovedOriginal);
}
