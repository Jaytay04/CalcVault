#pragma once

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CVLPApplicationIDGroupSelectionStatus) {
    CVLPApplicationIDGroupSelectionStatusUnavailable,
    CVLPApplicationIDGroupSelectionStatusMalformed,
    CVLPApplicationIDGroupSelectionStatusSelected
};

typedef NS_ENUM(NSUInteger, CVLPHostOnlyGroupSelectionStatus) {
    CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier,
    CVLPHostOnlyGroupSelectionStatusMalformedApplicationIdentifier,
    CVLPHostOnlyGroupSelectionStatusMissingExplicitGroups,
    CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups,
    CVLPHostOnlyGroupSelectionStatusWrongPrefix,
    CVLPHostOnlyGroupSelectionStatusNotEntitled,
    CVLPHostOnlyGroupSelectionStatusAmbiguous,
    CVLPHostOnlyGroupSelectionStatusSelected
};

static inline BOOL CVLPKeychainIdentityIsValidPart(NSString *part) {
    if (part.length == 0) { return NO; }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *validCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
        [validCharacters addCharactersInString:@"-"];
        invalidCharacters = [validCharacters invertedSet];
    });
    return [part rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static inline BOOL CVLPKeychainIdentityIsValidIdentifier(NSString *identifier) {
    if (identifier.length == 0) { return NO; }
    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
    if (parts.count < 2) { return NO; }
    for (NSString *part in parts) {
        if (!CVLPKeychainIdentityIsValidPart(part)) { return NO; }
    }
    return YES;
}

static inline NSString * _Nullable CVLPSelectApplicationIDControlGroup(
    NSString * _Nullable signedApplicationIdentifier,
    CVLPApplicationIDGroupSelectionStatus * _Nullable status
) {
    if (status != NULL) { *status = CVLPApplicationIDGroupSelectionStatusUnavailable; }
    if (signedApplicationIdentifier == nil || signedApplicationIdentifier.length == 0) { return nil; }
    if (!CVLPKeychainIdentityIsValidIdentifier(signedApplicationIdentifier)) {
        if (status != NULL) { *status = CVLPApplicationIDGroupSelectionStatusMalformed; }
        return nil;
    }
    if (status != NULL) { *status = CVLPApplicationIDGroupSelectionStatusSelected; }
    // This is the signed entitlement itself. Do not derive it from the bundle identifier.
    return [signedApplicationIdentifier copy];
}

static inline NSString * _Nullable CVLPSelectHostOnlyGroup(
    id _Nullable explicitGroups,
    NSString * _Nullable signedApplicationIdentifier,
    CVLPHostOnlyGroupSelectionStatus * _Nullable status
) {
    if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier; }
    if (signedApplicationIdentifier == nil || signedApplicationIdentifier.length == 0) { return nil; }
    if (!CVLPKeychainIdentityIsValidIdentifier(signedApplicationIdentifier)) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusMalformedApplicationIdentifier; }
        return nil;
    }

    if (explicitGroups == nil || explicitGroups == NSNull.null) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusMissingExplicitGroups; }
        return nil;
    }
    if (![explicitGroups isKindOfClass:NSArray.class]) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups; }
        return nil;
    }

    NSArray *groups = (NSArray *)explicitGroups;
    NSMutableSet<NSString *> *seenGroups = [NSMutableSet setWithCapacity:groups.count];
    NSMutableArray<NSString *> *hostOnlyCandidates = [NSMutableArray array];
    NSString *hostOnlySuffix = @".com.jaylintaylor.calcvault.hostonly";
    for (id value in groups) {
        if (![value isKindOfClass:NSString.class] || !CVLPKeychainIdentityIsValidIdentifier((NSString *)value)) {
            if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups; }
            return nil;
        }
        NSString *group = (NSString *)value;
        if ([seenGroups containsObject:group]) {
            if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusAmbiguous; }
            return nil;
        }
        [seenGroups addObject:group];
        if ([group hasSuffix:hostOnlySuffix]) { [hostOnlyCandidates addObject:group]; }
    }

    if (hostOnlyCandidates.count > 1) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusAmbiguous; }
        return nil;
    }
    if (hostOnlyCandidates.count == 0) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusNotEntitled; }
        return nil;
    }

    NSRange firstDelimiter = [signedApplicationIdentifier rangeOfString:@"."];
    NSString *applicationIDPrefix = [signedApplicationIdentifier substringToIndex:firstDelimiter.location];
    NSString *expectedHostOnlyGroup = [applicationIDPrefix stringByAppendingString:hostOnlySuffix];
    NSString *candidate = hostOnlyCandidates.firstObject;
    if (![candidate isEqualToString:expectedHostOnlyGroup]) {
        if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusWrongPrefix; }
        return nil;
    }

    if (status != NULL) { *status = CVLPHostOnlyGroupSelectionStatusSelected; }
    return [candidate copy];
}

static inline NSString *CVLPApplicationIDGroupSelectionStatusName(CVLPApplicationIDGroupSelectionStatus status) {
    switch (status) {
        case CVLPApplicationIDGroupSelectionStatusUnavailable: return @"unavailable";
        case CVLPApplicationIDGroupSelectionStatusMalformed: return @"malformed";
        case CVLPApplicationIDGroupSelectionStatusSelected: return @"selected";
    }
    return @"unknown";
}

static inline NSString *CVLPHostOnlyGroupSelectionStatusName(CVLPHostOnlyGroupSelectionStatus status) {
    switch (status) {
        case CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier: return @"application-identifier unavailable";
        case CVLPHostOnlyGroupSelectionStatusMalformedApplicationIdentifier: return @"application-identifier malformed";
        case CVLPHostOnlyGroupSelectionStatusMissingExplicitGroups: return @"explicit groups unavailable";
        case CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups: return @"explicit groups malformed";
        case CVLPHostOnlyGroupSelectionStatusWrongPrefix: return @"host-only group prefix mismatch";
        case CVLPHostOnlyGroupSelectionStatusNotEntitled: return @"host-only group not entitled";
        case CVLPHostOnlyGroupSelectionStatusAmbiguous: return @"explicit groups ambiguous";
        case CVLPHostOnlyGroupSelectionStatusSelected: return @"selected";
    }
    return @"unknown";
}

NS_ASSUME_NONNULL_END
