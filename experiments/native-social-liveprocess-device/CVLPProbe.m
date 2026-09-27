#import "CVLPProbe.h"
#import "CVLPKeychainIdentity.h"

#import <Security/Security.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <string.h>
#import <unistd.h>

typedef OSStatus (*CVLPSecItemCopyMatchingFunction)(CFDictionaryRef query, CFTypeRef _Nullable * _Nullable result);
extern void *SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);

static NSString *const CVLPGuestBundleIdentifier = @"org.example.syntheticnativeguest.app";
static NSString *const CVLPGuestResourceBundleName = @"SyntheticGuestResources.bundle";
static NSString *const CVLPPayloadName = @"SyntheticNativeGuestPayload.dylib";
static NSString *const CVLPLiveContainerSharedGroupSuffix = @".com.kdt.livecontainer.shared";

static NSDictionary<NSString *, id> *CVLPHostLaunchInfo;
static NSDictionary<NSString *, id> *CVLPMigrationFixture;
static NSDictionary<NSString *, id> *CVLPRuntimeLaunchInfo;
static NSMutableArray<NSString *> *CVLPHostObservations;
static NSMutableArray<NSString *> *CVLPStageObservations;
static NSData *CVLPHostSentinelContents;
static NSString *CVLPHostSentinelPath;
static NSString *CVLPSigningExportPath;
static CVLPSecItemCopyMatchingFunction CVLPOriginalSecItemCopyMatching;
static BOOL CVLPGuestBookmarkActivated;

static void CVLPAppendHostObservation(NSString *line) {
    @synchronized (CVLPProbe.class) {
        if (CVLPHostObservations == nil) { CVLPHostObservations = [NSMutableArray array]; }
        [CVLPHostObservations addObject:line];
    }
}

static BOOL CVLPWriteAll(int descriptor, const uint8_t *bytes, size_t length, off_t offset, int *errorCode) {
    size_t written = 0;
    while (written < length) {
        ssize_t amount = pwrite(descriptor, bytes + written, length - written, offset + (off_t)written);
        if (amount < 0) {
            if (errorCode != NULL) { *errorCode = errno; }
            if (errno == EINTR) { continue; }
            return NO;
        }
        if (amount == 0) {
            if (errorCode != NULL) { *errorCode = EIO; }
            return NO;
        }
        written += (size_t)amount;
    }
    return YES;
}

static NSData * _Nullable CVLPReadFile(int descriptor, int *errorCode) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        if (errorCode != NULL) { *errorCode = errno; }
        return nil;
    }
    NSMutableData *contents = [NSMutableData data];
    uint8_t buffer[512];
    for (;;) {
        ssize_t amount = read(descriptor, buffer, sizeof(buffer));
        if (amount < 0) {
            if (errorCode != NULL) { *errorCode = errno; }
            return nil;
        }
        if (amount == 0) { break; }
        [contents appendBytes:buffer length:(NSUInteger)amount];
        if (contents.length > 4096) {
            if (errorCode != NULL) { *errorCode = EFBIG; }
            return nil;
        }
    }
    return contents;
}

static NSString *CVLPFileReadOutcome(int errorCode) {
    return (errorCode == EACCES || errorCode == EPERM) ? @"DENIED" : @"INCONCLUSIVE";
}

static NSString *CVLPSigningExportOpenOutcome(void) {
    NSString *path = CVLPSigningExportPath;
    if (path.length == 0) { return @"INCONCLUSIVE (bundle path unavailable)"; }
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor >= 0) {
        close(descriptor);
        return @"OPENABLE (no bytes read)";
    }
    int openError = errno;
    if (openError == ENOENT) { return @"ABSENT"; }
    if (openError == EACCES || openError == EPERM) { return @"DENIED"; }
    return [NSString stringWithFormat:@"INCONCLUSIVE (open error %d)", openError];
}

static NSString *CVLPKeychainEntitlementType(CFTypeRef value) {
    if (value == NULL) { return @"unavailable"; }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) { return @"string"; }
    if (type == CFArrayGetTypeID()) { return @"array"; }
    if (type == CFDictionaryGetTypeID()) { return @"dictionary"; }
    if (type == CFBooleanGetTypeID()) { return @"boolean"; }
    if (type == CFNumberGetTypeID()) { return @"number"; }
    if (type == CFDataGetTypeID()) { return @"data"; }
    return @"other";
}

static NSString *CVLPKeychainEntitlementReadResult(CFTypeRef value, CFErrorRef error, BOOL taskAvailable) {
    if (!taskAvailable) { return @"unavailable"; }
    if (value != NULL) { return @"present"; }
    return error != NULL ? @"error" : @"missing";
}

static NSDictionary<NSString *, id> *CVLPReadKeychainIdentityEntitlements(void) {
    void *task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    BOOL taskAvailable = task != NULL;
    CFErrorRef applicationIDError = NULL;
    CFErrorRef groupsError = NULL;
    CFTypeRef rawApplicationID = taskAvailable
        ? SecTaskCopyValueForEntitlement(task, CFSTR("application-identifier"), &applicationIDError)
        : NULL;
    CFTypeRef rawGroups = taskAvailable
        ? SecTaskCopyValueForEntitlement(task, CFSTR("keychain-access-groups"), &groupsError)
        : NULL;

    NSString *applicationIDResult = CVLPKeychainEntitlementReadResult(rawApplicationID, applicationIDError, taskAvailable);
    NSString *applicationIDType = CVLPKeychainEntitlementType(rawApplicationID);
    NSString *groupsResult = CVLPKeychainEntitlementReadResult(rawGroups, groupsError, taskAvailable);
    NSString *groupsType = CVLPKeychainEntitlementType(rawGroups);
    NSString *groupsCount = [groupsType isEqualToString:@"array"]
        ? [NSString stringWithFormat:@"%lu", (unsigned long)CFArrayGetCount(rawGroups)]
        : @"not-applicable";

    if (taskAvailable) { CFRelease(task); }
    if (applicationIDError != NULL) { CFRelease(applicationIDError); }
    if (groupsError != NULL) { CFRelease(groupsError); }
    id applicationIDValue = rawApplicationID != NULL ? CFBridgingRelease(rawApplicationID) : NSNull.null;
    id groupsValue = rawGroups != NULL ? CFBridgingRelease(rawGroups) : NSNull.null;
    return @{
        @"applicationIdentifier": applicationIDValue,
        @"applicationIdentifierResult": applicationIDResult,
        @"applicationIdentifierType": applicationIDType,
        @"explicitGroups": groupsValue,
        @"explicitGroupsResult": groupsResult,
        @"explicitGroupsType": groupsType,
        @"explicitGroupsCount": groupsCount
    };
}

static NSDictionary<NSString *, id> *CVLPSeedKeychainItem(NSString *service, NSString *account, NSString *accessGroup) {
    NSMutableData *syntheticValue = [NSMutableData dataWithLength:32];
    OSStatus randomStatus = SecRandomCopyBytes(kSecRandomDefault, syntheticValue.length, syntheticValue.mutableBytes);
    OSStatus addStatus = errSecParam;
    OSStatus readStatus = errSecParam;
    BOOL addAttempted = NO;
    BOOL readAttempted = NO;
    BOOL byteMatch = NO;
    if (randomStatus != errSecSuccess) {
        [syntheticValue resetBytesInRange:NSMakeRange(0, syntheticValue.length)];
    } else {
        NSDictionary *baseQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecAttrAccessGroup: accessGroup
        };
        NSMutableDictionary *addQuery = [baseQuery mutableCopy];
        addQuery[(__bridge id)kSecValueData] = syntheticValue;
        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        addAttempted = YES;
        addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);

        NSMutableData *expectedValue = [syntheticValue mutableCopy];
        if (addStatus == errSecSuccess) {
            NSMutableDictionary *readQuery = [baseQuery mutableCopy];
            readQuery[(__bridge id)kSecReturnData] = @YES;
            CFTypeRef result = NULL;
            readAttempted = YES;
            readStatus = SecItemCopyMatching((__bridge CFDictionaryRef)readQuery, &result);
            if (readStatus == errSecSuccess && result != NULL) {
                id value = CFBridgingRelease(result);
                byteMatch = [value isKindOfClass:NSData.class] && [(NSData *)value isEqualToData:expectedValue];
            } else if (result != NULL) {
                CFRelease(result);
            }
        }
        [expectedValue resetBytesInRange:NSMakeRange(0, expectedValue.length)];
        [expectedValue setLength:0];
    }

    [syntheticValue resetBytesInRange:NSMakeRange(0, syntheticValue.length)];
    [syntheticValue setLength:0];
    return @{
        @"randomStatus": @(randomStatus),
        @"addStatus": addAttempted ? @(addStatus) : NSNull.null,
        @"readStatus": readAttempted ? @(readStatus) : NSNull.null,
        @"byteMatch": @(byteMatch),
        @"ready": @(randomStatus == errSecSuccess && addStatus == errSecSuccess && readStatus == errSecSuccess && byteMatch)
    };
}

static NSString *CVLPProbeStageName(NSString *stage) {
    static NSSet<NSString *> *allowedStages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedStages = [NSSet setWithArray:@[
            @"pre-bookmark", @"post-bookmark", @"post-loader", @"guest-entry", @"guest-button"
        ]];
    });
    return [allowedStages containsObject:stage] ? stage : @"stage-unknown";
}

static NSString *CVLPKeychainOutcome(NSString *service, NSString *account, NSString *accessGroup) {
    CVLPSecItemCopyMatchingFunction copyFunction = CVLPOriginalSecItemCopyMatching;
    if (copyFunction == NULL || service.length == 0 || account.length == 0 || accessGroup.length == 0) {
        return @"INCONCLUSIVE (probe precondition unavailable)";
    }
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUIFail
    };
    CFTypeRef result = NULL;
    OSStatus status = copyFunction((__bridge CFDictionaryRef)query, &result);
    NSString *outcome = @"INCONCLUSIVE";
    if (status == errSecSuccess && result != NULL) {
        outcome = @"EXPOSED";
        CFRelease(result);
    } else {
        if (result != NULL) { CFRelease(result); }
        if (status == errSecMissingEntitlement) { outcome = @"DENIED"; }
        else if (status == errSecItemNotFound) { outcome = @"INCONCLUSIVE (item not found)"; }
    }
    return outcome;
}

static void CVLPWriteGuestReportIfAuthorized(NSArray<NSString *> *lines) {
    if (!CVLPGuestBookmarkActivated) { return; }
    NSString *reportPath = CVLPRuntimeLaunchInfo[@"reportPath"];
    if (![reportPath isKindOfClass:NSString.class] || reportPath.length == 0) { return; }
    int descriptor = open(reportPath.fileSystemRepresentation, O_WRONLY | O_TRUNC | O_CREAT, S_IRUSR | S_IWUSR);
    if (descriptor < 0) { return; }
    NSData *encoded = [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *reportData = [encoded mutableCopy];
    [reportData appendBytes:"\n" length:1];
    if (encoded.length > 0) {
        int ignoredError = 0;
        CVLPWriteAll(descriptor, reportData.bytes, reportData.length, 0, &ignoredError);
        fsync(descriptor);
    }
    close(descriptor);
}

static NSString *CVLPHostSentinelVerification(void) {
    NSString *path = CVLPHostSentinelPath;
    NSData *expected = CVLPHostSentinelContents;
    if (path.length == 0 || expected.length == 0) { return @"INCONCLUSIVE (host fixture unavailable)"; }
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    if (descriptor < 0) { return [NSString stringWithFormat:@"INCONCLUSIVE (host read error %d)", errno]; }
    int readError = 0;
    NSData *contents = CVLPReadFile(descriptor, &readError);
    close(descriptor);
    if (contents == nil) { return [NSString stringWithFormat:@"INCONCLUSIVE (host read error %d)", readError]; }
    return [contents isEqualToData:expected] ? @"UNCHANGED" : @"CHANGED";
}

static NSString *CVLPHostSigningExportObservation(void) {
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    BOOL hasP12 = [[NSFileManager defaultManager] fileExistsAtPath:
        [[bundleURL URLByAppendingPathComponent:@"ALTCertificate.p12"] path]];
    BOOL hasDER = [[NSFileManager defaultManager] fileExistsAtPath:
        [[bundleURL URLByAppendingPathComponent:@"ALTCertificate.der"] path]];
    return [NSString stringWithFormat:
        @"Containing-app certificate export existence: P12=%@ (may contain private-key material); DER=%@ (certificate file alone does not prove a private key).",
        hasP12 ? @"present" : @"absent", hasDER ? @"present" : @"absent"];
}

static NSString *CVLPSeedOSStatusDescription(id status) {
    return [status isKindOfClass:NSNumber.class] ? [(NSNumber *)status stringValue] : @"not run";
}

static NSString *CVLPSeedObservation(NSString *controlName, NSDictionary<NSString *, id> * _Nullable seedResult, NSString *skipReason) {
    if (seedResult == nil) {
        return [NSString stringWithFormat:
            @"Keychain fixture %@: SKIPPED (%@); random/add/read OSStatus=not run; byte-match=no.", controlName, skipReason];
    }
    return [NSString stringWithFormat:
        @"Keychain fixture %@: %@; random OSStatus=%@; add OSStatus=%@; read OSStatus=%@; byte-match=%@.",
        controlName,
        [seedResult[@"ready"] boolValue] ? @"READY" : @"INCONCLUSIVE",
        CVLPSeedOSStatusDescription(seedResult[@"randomStatus"]),
        CVLPSeedOSStatusDescription(seedResult[@"addStatus"]),
        CVLPSeedOSStatusDescription(seedResult[@"readStatus"]),
        [seedResult[@"byteMatch"] boolValue] ? @"yes" : @"no"];
}

@implementation CVLPProbe

+ (NSDictionary<NSString *, NSString *> *)migrationIdentity {
    NSDictionary *identity = CVLPReadKeychainIdentityEntitlements();
    id raw = identity[@"applicationIdentifier"];
    NSString *appID = [raw isKindOfClass:NSString.class] ? raw : nil;
    NSString *source = CVLPSelectApplicationIDControlGroup(appID, NULL);
    NSString *destination = CVLPSelectHostOnlyGroup(identity[@"explicitGroups"], appID, NULL);
    if (source.length == 0 || destination.length == 0 || [source isEqualToString:destination]) { return @{}; }
    return @{@"source": source, @"destination": destination};
}

+ (void)setMigrationFixture:(NSDictionary<NSString *, id> *)fixture {
    @synchronized (self) { CVLPMigrationFixture = [fixture copy]; }
}

+ (NSString *)prepareHost {
    @synchronized (self) {
        CVLPHostLaunchInfo = nil;
        CVLPRuntimeLaunchInfo = nil;
        CVLPHostSentinelContents = nil;
        CVLPHostSentinelPath = nil;
        CVLPOriginalSecItemCopyMatching = NULL;
        CVLPGuestBookmarkActivated = NO;
        CVLPHostObservations = [NSMutableArray array];
        CVLPStageObservations = [NSMutableArray array];
    }
    CVLPAppendHostObservation(@"Build marker: build15.");
    CVLPAppendHostObservation(CVLPHostSigningExportObservation());
    CVLPAppendHostObservation(CVLPMigrationFixture[@"summary"] ?: @"Synthetic migration: NOT RUN.");
#if !TARGET_OS_SIMULATOR
    if (![CVLPMigrationFixture[@"ready"] boolValue]) {
        return @"Synthetic migration did not finish; guest launch blocked.";
    }
#endif

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *fileError = nil;
    NSURL *supportURL = [fileManager URLForDirectory:NSApplicationSupportDirectory
                                            inDomain:NSUserDomainMask
                                   appropriateForURL:nil
                                              create:YES
                                               error:&fileError];
    if (supportURL == nil) { return @"Synthetic fixture setup failed (host support directory unavailable)."; }

    NSString *runID = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *probeRoot = [supportURL URLByAppendingPathComponent:@"CalcVaultLiveProcessProbe" isDirectory:YES];
    NSURL *runDirectory = [probeRoot URLByAppendingPathComponent:runID isDirectory:YES];
    if (![fileManager createDirectoryAtURL:runDirectory withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        return @"Synthetic fixture setup failed (host fixture directory unavailable).";
    }

    NSData *sentinelContents = [[NSString stringWithFormat:@"Synthetic LiveProcess host sentinel %@\n", runID] dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *sentinelURL = [runDirectory URLByAppendingPathComponent:@"host-sentinel.txt"];
    int sentinelDescriptor = open(sentinelURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (sentinelDescriptor < 0) { return @"Synthetic fixture setup failed (host sentinel could not be created)."; }
    int sentinelError = 0;
    BOOL sentinelWritten = CVLPWriteAll(sentinelDescriptor, sentinelContents.bytes, sentinelContents.length, 0, &sentinelError);
    if (sentinelWritten) { fsync(sentinelDescriptor); }
    close(sentinelDescriptor);
    NSData *sentinelReadback = [NSData dataWithContentsOfURL:sentinelURL options:0 error:&fileError];
    if (!sentinelWritten || ![sentinelReadback isEqualToData:sentinelContents]) {
        return @"Synthetic fixture setup failed (host sentinel readback did not match).";
    }

    NSURL *documentsURL = [fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (documentsURL == nil) { return @"Synthetic guest staging failed (host documents directory unavailable)."; }
    NSURL *guestParent = [documentsURL URLByAppendingPathComponent:@"Applications" isDirectory:YES];
    NSURL *guestBundleURL = [guestParent URLByAppendingPathComponent:CVLPGuestBundleIdentifier isDirectory:YES];
    NSURL *guestDataURL = [[documentsURL URLByAppendingPathComponent:@"Data" isDirectory:YES]
        URLByAppendingPathComponent:@"Application/synthetic-liveprocess-device" isDirectory:YES];
    if (![fileManager createDirectoryAtURL:guestParent withIntermediateDirectories:YES attributes:nil error:&fileError] ||
        ![fileManager createDirectoryAtURL:guestDataURL withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        return @"Synthetic guest staging failed (guest directories unavailable).";
    }

    NSURL *resourceBundleURL = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:CVLPGuestResourceBundleName isDirectory:YES];
    NSURL *resourceInfoURL = [resourceBundleURL URLByAppendingPathComponent:@"GuestInfo.plist"];
    NSData *infoData = [NSData dataWithContentsOfURL:resourceInfoURL options:0 error:&fileError];
    if (infoData == nil) { return @"Synthetic guest staging failed (guest resource metadata unavailable)."; }
    NSPropertyListFormat propertyListFormat = NSPropertyListXMLFormat_v1_0;
    id infoValue = [NSPropertyListSerialization propertyListWithData:infoData options:NSPropertyListImmutable format:&propertyListFormat error:&fileError];
    if (![infoValue isKindOfClass:NSDictionary.class]) { return @"Synthetic guest staging failed (guest resource metadata invalid)."; }
    NSDictionary *guestInfo = (NSDictionary *)infoValue;
    NSString *bundleIdentifier = guestInfo[@"CFBundleIdentifier"];
    NSString *executableName = guestInfo[@"CFBundleExecutable"];
    NSString *payloadRelativePath = guestInfo[@"LCSyntheticGuestExecutable"];
    if (![bundleIdentifier isEqualToString:CVLPGuestBundleIdentifier] ||
        ![executableName isKindOfClass:NSString.class] || executableName.length == 0 ||
        [executableName containsString:@"/"] ||
        ![payloadRelativePath isEqualToString:@"Frameworks/SyntheticNativeGuestPayload.dylib"]) {
        return @"Synthetic guest staging failed (guest metadata did not match the allowlisted fixture).";
    }

    NSURL *payloadSource = [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:CVLPPayloadName];
    BOOL payloadIsFile = NO;
    if (![fileManager fileExistsAtPath:payloadSource.path isDirectory:&payloadIsFile] || payloadIsFile) {
        return @"Synthetic guest staging failed (signed synthetic payload unavailable).";
    }

    BOOL guestBundleExists = [fileManager fileExistsAtPath:guestBundleURL.path];
    NSURL *existingInfoURL = [guestBundleURL URLByAppendingPathComponent:@"Info.plist"];
    NSURL *stageMarkerURL = [guestBundleURL URLByAppendingPathComponent:@".cvlp-synthetic-guest"];
    if (guestBundleExists) {
        NSData *existingInfoData = [NSData dataWithContentsOfURL:existingInfoURL options:0 error:nil];
        NSDictionary *existingInfo = existingInfoData != nil
            ? [NSPropertyListSerialization propertyListWithData:existingInfoData options:NSPropertyListImmutable format:NULL error:nil]
            : nil;
        if (![existingInfo isKindOfClass:NSDictionary.class] ||
            ![existingInfo[@"CFBundleIdentifier"] isEqualToString:CVLPGuestBundleIdentifier] ||
            ![fileManager fileExistsAtPath:stageMarkerURL.path]) {
            return @"Synthetic guest staging stopped (existing guest path is not a verified probe fixture).";
        }
    } else if (![fileManager createDirectoryAtURL:guestBundleURL withIntermediateDirectories:NO attributes:nil error:&fileError]) {
        return @"Synthetic guest staging failed (guest bundle directory could not be created).";
    }

    NSURL *frameworksURL = [guestBundleURL URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
    if (![fileManager createDirectoryAtURL:frameworksURL withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        return @"Synthetic guest staging failed (guest frameworks directory unavailable).";
    }
    NSURL *embeddedPayloadURL = [frameworksURL URLByAppendingPathComponent:CVLPPayloadName];
    NSURL *rootExecutableURL = [guestBundleURL URLByAppendingPathComponent:executableName];
    NSURL *lcAppInfoURL = [guestBundleURL URLByAppendingPathComponent:@"LCAppInfo.plist"];
    NSDictionary *lcAppInfo = @{
        @"LCDataUUID": @"synthetic-liveprocess-device",
        @"LCSyntheticGuestExecutable": @"Frameworks/SyntheticNativeGuestPayload.dylib",
        @"dontInjectTweakLoader": @YES,
        @"dontLoadTweakLoader": @YES
    };
    NSData *lcAppInfoData = [NSPropertyListSerialization dataWithPropertyList:lcAppInfo
                                                                       format:NSPropertyListXMLFormat_v1_0
                                                                      options:0
                                                                        error:&fileError];
    NSData *signedPayload = [NSData dataWithContentsOfURL:payloadSource options:0 error:&fileError];
    if (signedPayload.length == 0 || lcAppInfoData.length == 0 ||
        ![infoData writeToURL:existingInfoURL options:NSDataWritingAtomic error:&fileError] ||
        ![lcAppInfoData writeToURL:lcAppInfoURL options:NSDataWritingAtomic error:&fileError] ||
        ![signedPayload writeToURL:embeddedPayloadURL options:NSDataWritingAtomic error:&fileError] ||
        ![signedPayload writeToURL:rootExecutableURL options:NSDataWritingAtomic error:&fileError] ||
        ![@"synthetic-liveprocess-device" writeToURL:stageMarkerURL atomically:YES encoding:NSUTF8StringEncoding error:&fileError]) {
        return @"Synthetic guest staging failed (fixture resources could not be staged).";
    }
    NSData *embeddedPayloadReadback = [NSData dataWithContentsOfURL:embeddedPayloadURL options:0 error:nil];
    NSData *rootExecutableReadback = [NSData dataWithContentsOfURL:rootExecutableURL options:0 error:nil];
    if (![embeddedPayloadReadback isEqualToData:signedPayload] || ![rootExecutableReadback isEqualToData:signedPayload]) {
        return @"Synthetic guest staging failed (payload copy did not preserve the signed fixture bytes).";
    }

    NSDictionary<NSString *, id> *entitlements = CVLPReadKeychainIdentityEntitlements();
    id rawApplicationIdentifier = entitlements[@"applicationIdentifier"];
    NSString *signedApplicationIdentifier = [rawApplicationIdentifier isKindOfClass:NSString.class]
        ? (NSString *)rawApplicationIdentifier
        : nil;
    id explicitGroups = entitlements[@"explicitGroups"];
    CVLPApplicationIDGroupSelectionStatus appIDSelectionStatus = CVLPApplicationIDGroupSelectionStatusUnavailable;
    NSString *appIDGroup = CVLPSelectApplicationIDControlGroup(signedApplicationIdentifier, &appIDSelectionStatus);
    CVLPHostOnlyGroupSelectionStatus hostOnlySelectionStatus = CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier;
    NSString *hostOnlyGroup = CVLPSelectHostOnlyGroup(explicitGroups, signedApplicationIdentifier, &hostOnlySelectionStatus);
    NSString *teamPrefix = nil;
    if (appIDGroup.length > 0) {
        NSRange delimiter = [appIDGroup rangeOfString:@"."];
        if (delimiter.location != NSNotFound && delimiter.location > 0) { teamPrefix = [appIDGroup substringToIndex:delimiter.location]; }
    }
    NSString *liveContainerSharedGroup = teamPrefix.length > 0 ? [teamPrefix stringByAppendingString:CVLPLiveContainerSharedGroupSuffix] : nil;
    NSArray *effectiveGroups = [explicitGroups isKindOfClass:NSArray.class] ? (NSArray *)explicitGroups : nil;
    BOOL hostOnlyGroupEntitled = hostOnlyGroup.length > 0;
    BOOL sharedGroupEntitled = liveContainerSharedGroup.length > 0 && [effectiveGroups containsObject:liveContainerSharedGroup];

    CVLPAppendHostObservation([NSString stringWithFormat:
        @"Signed Keychain entitlement read: application-identifier result=%@ type=%@; keychain-access-groups result=%@ type=%@ count=%@.",
        entitlements[@"applicationIdentifierResult"], entitlements[@"applicationIdentifierType"],
        entitlements[@"explicitGroupsResult"], entitlements[@"explicitGroupsType"], entitlements[@"explicitGroupsCount"]]);
    CVLPAppendHostObservation([NSString stringWithFormat:
        @"Keychain identity selection: app-ID control %@; host-only control %@.",
        CVLPApplicationIDGroupSelectionStatusName(appIDSelectionStatus),
        CVLPHostOnlyGroupSelectionStatusName(hostOnlySelectionStatus)]);

    NSString *service = [NSString stringWithFormat:@"org.example.calcvault.cvlp.%@", runID];
    NSString *hostOnlyAccount = [NSString stringWithFormat:@"host-only-%@", runID];
    NSString *sharedAccount = [NSString stringWithFormat:@"shared-control-%@", runID];
    NSDictionary<NSString *, id> *appIDSeedResult = appIDGroup != nil
        ? CVLPSeedKeychainItem(service, sharedAccount, appIDGroup)
        : nil;
    NSDictionary<NSString *, id> *hostOnlySeedResult = hostOnlyGroup != nil
        ? CVLPSeedKeychainItem(service, hostOnlyAccount, hostOnlyGroup)
        : nil;
    BOOL appIDFixtureReady = [appIDSeedResult[@"ready"] boolValue];
    BOOL hostOnlyFixtureReady = [hostOnlySeedResult[@"ready"] boolValue];
    CVLPAppendHostObservation(CVLPSeedObservation(@"app-ID control", appIDSeedResult,
        CVLPApplicationIDGroupSelectionStatusName(appIDSelectionStatus)));
    CVLPAppendHostObservation(CVLPSeedObservation(@"host-only control", hostOnlySeedResult,
        CVLPHostOnlyGroupSelectionStatusName(hostOnlySelectionStatus)));

    if (!appIDFixtureReady || !hostOnlyFixtureReady) {
#if !TARGET_OS_SIMULATOR
        CVLPAppendHostObservation(@"Guest launch skipped: both independent Keychain controls must be READY before device launch.");
        return @"Synthetic Keychain fixture setup is inconclusive; device probe stopped before guest launch. See the host report for each control's identity status and setup result.";
#else
        CVLPAppendHostObservation(@"Device guest launch would be skipped because one or both independent Keychain controls are not READY; simulator-only loader smoke continues.");
#endif
    } else {
        CVLPAppendHostObservation(@"Keychain fixture preconditions: app-ID control READY; host-only fixture READY (both independent host readbacks succeeded).");
    }

    NSURL *reportURL = [guestDataURL URLByAppendingPathComponent:[NSString stringWithFormat:@"CVLPProbeReport-%@.txt", runID]];
    NSDictionary<NSString *, id> *launchInfo = @{
        @"hostPID": @(getpid()),
        @"migrationFixture": CVLPMigrationFixture ?: @{},
        @"runID": runID,
        @"hostSentinelPath": sentinelURL.path,
        @"sentinelLength": @(sentinelContents.length),
        @"guestBundlePath": guestBundleURL.path,
        @"guestDataPath": guestDataURL.path,
        @"reportPath": reportURL.path,
        @"keychainService": service,
        @"hostOnlyAccount": hostOnlyAccount,
        @"hostOnlyGroup": hostOnlyFixtureReady ? hostOnlyGroup : @"",
        @"appIDControlAccount": sharedAccount,
        @"appIDControlGroup": appIDFixtureReady ? appIDGroup : @"",
        @"appIDFixtureReady": @(appIDFixtureReady),
        @"hostOnlyFixtureReady": @(hostOnlyFixtureReady),
        @"hostOnlyGroupEntitled": @(hostOnlyGroupEntitled),
        @"liveContainerSharedGroupEntitled": @(sharedGroupEntitled)
    };
    @synchronized (self) {
        CVLPHostLaunchInfo = launchInfo;
        CVLPHostSentinelContents = sentinelContents;
        CVLPHostSentinelPath = sentinelURL.path;
    }
    CVLPAppendHostObservation(@"Host synthetic file fixture: created and read back successfully.");
    CVLPAppendHostObservation(@"Guest staging: allowlisted bundle metadata and signed payload copied to the synthetic guest folder.");
    CVLPAppendHostObservation([NSString stringWithFormat:@"Keychain entitlement controls: host-only %@; LiveContainer shared group %@.",
        hostOnlyGroupEntitled ? @"present" : @"not present", sharedGroupEntitled ? @"present" : @"not present"]);
    return nil;
}

+ (NSDictionary<NSString *, id> *)launchInfo {
    @synchronized (self) {
        return CVLPHostLaunchInfo ?: @{};
    }
}

+ (void)acceptLaunchInfo:(NSDictionary<NSString *, id> *)launchInfo {
    // The adapter invokes this before LiveProcess installs the guest loader and Security hooks.
    CVLPSecItemCopyMatchingFunction original = (CVLPSecItemCopyMatchingFunction)dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    if (original == NULL) { original = (CVLPSecItemCopyMatchingFunction)dlsym(RTLD_NEXT, "SecItemCopyMatching"); }
    NSURL *extensionURL = NSBundle.mainBundle.bundleURL;
    NSURL *containingAppURL = extensionURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSString *signingExportPath = [extensionURL.pathExtension isEqualToString:@"appex"] &&
        [containingAppURL.pathExtension isEqualToString:@"app"]
        ? [containingAppURL URLByAppendingPathComponent:@"ALTCertificate.p12"].path : nil;
    @synchronized (self) {
        CVLPOriginalSecItemCopyMatching = original;
        CVLPSigningExportPath = signingExportPath;
        CVLPRuntimeLaunchInfo = [launchInfo copy];
        CVLPGuestBookmarkActivated = NO;
        CVLPStageObservations = [NSMutableArray array];
    }
}

+ (NSString *)recordStage:(NSString *)stage {
    NSDictionary<NSString *, id> *info;
    @synchronized (self) { info = CVLPRuntimeLaunchInfo; }
    NSString *stageName = CVLPProbeStageName(stage ?: @"");
    if (info == nil) { return @"Probe stage INCONCLUSIVE: launch context unavailable."; }

    if ([stageName isEqualToString:@"post-bookmark"] || [stageName isEqualToString:@"post-loader"] ||
        [stageName isEqualToString:@"guest-entry"] || [stageName isEqualToString:@"guest-button"]) {
        @synchronized (self) { CVLPGuestBookmarkActivated = YES; }
    }

    pid_t hostPID = [info[@"hostPID"] intValue];
    pid_t probePID = getpid();
    NSString *processObservation = hostPID > 0 && hostPID != probePID ? @"distinct" : @"not-distinct-or-unavailable";
    NSString *sentinelPath = info[@"hostSentinelPath"];
    NSUInteger sentinelLength = [info[@"sentinelLength"] unsignedIntegerValue];
    NSString *fileReadOutcome = @"INCONCLUSIVE";
    NSString *fileWriteOutcome = @"INCONCLUSIVE";
    if ([sentinelPath isKindOfClass:NSString.class] && sentinelLength > 0 && sentinelLength <= 4096) {
        int descriptor = open(sentinelPath.fileSystemRepresentation, O_RDONLY);
        if (descriptor < 0) {
            fileReadOutcome = CVLPFileReadOutcome(errno);
        } else {
            int readError = 0;
            NSData *observed = CVLPReadFile(descriptor, &readError);
            close(descriptor);
            if (observed == nil) {
                fileReadOutcome = CVLPFileReadOutcome(readError);
            } else {
                fileReadOutcome = @"EXPOSED";
            }
        }

        // This is an independent write attempt. It never creates a missing path and
        // deliberately leaves only this disposable sentinel changed for host readback.
        int writeDescriptor = open(sentinelPath.fileSystemRepresentation, O_WRONLY);
        if (writeDescriptor < 0) {
            fileWriteOutcome = CVLPFileReadOutcome(errno);
        } else {
            NSMutableData *mutationBytes = [NSMutableData dataWithLength:sentinelLength];
            memset(mutationBytes.mutableBytes, 'X', mutationBytes.length);
            ssize_t mutationAmount = pwrite(writeDescriptor, mutationBytes.bytes, mutationBytes.length, 0);
            int writeError = errno;
            if (mutationAmount > 0) {
                fileWriteOutcome = fsync(writeDescriptor) == 0
                    ? @"EXPOSED (synthetic sentinel mutated)"
                    : @"EXPOSED (write accepted; sync uncertain)";
            } else {
                fileWriteOutcome = CVLPFileReadOutcome(mutationAmount < 0 ? writeError : EIO);
            }
            [mutationBytes resetBytesInRange:NSMakeRange(0, mutationBytes.length)];
            close(writeDescriptor);
        }
    }

    NSString *service = info[@"keychainService"];
    NSString *hostOnlyKeychainOutcome = [info[@"hostOnlyFixtureReady"] boolValue]
        ? CVLPKeychainOutcome(service, info[@"hostOnlyAccount"], info[@"hostOnlyGroup"])
        : @"INCONCLUSIVE (host fixture setup unavailable)";
    NSString *sharedKeychainOutcome = [info[@"appIDFixtureReady"] boolValue]
        ? CVLPKeychainOutcome(service, info[@"appIDControlAccount"], info[@"appIDControlGroup"])
        : @"INCONCLUSIVE (host fixture setup unavailable)";
    NSString *signingExportOutcome = CVLPSigningExportOpenOutcome();
    NSDictionary *migration = info[@"migrationFixture"];
    NSString *migrationObservation = @"migration checks SKIPPED (fixture unavailable)";
    NSString *migrationService = migration[@"service"];
    NSString *migrationSource = migration[@"source"];
    NSString *migrationDestination = migration[@"destination"];
    if ([migration[@"ready"] boolValue] &&
        [migrationService isKindOfClass:NSString.class] &&
        [migrationService hasPrefix:@"org.example.calcvault.migration-probe."] &&
        [migrationSource isEqual:info[@"appIDControlGroup"]] &&
        [migrationDestination isEqual:info[@"hostOnlyGroup"]]) {
        NSMutableArray *results = [NSMutableArray array];
        for (NSString *account in @[@"metadata-v1", @"biometric-root-v1"]) {
            NSString *source = CVLPKeychainOutcome(migrationService, account, migrationSource);
            // Absence is meaningful only with the independent shared-group positive control.
            if ([source isEqualToString:@"INCONCLUSIVE (item not found)"] &&
                [sharedKeychainOutcome isEqualToString:@"EXPOSED"]) { source = @"ABSENT"; }
            NSString *destination = CVLPKeychainOutcome(migrationService, account, migrationDestination);
            [results addObject:[NSString stringWithFormat:@"%@ old copy %@, host-only copy %@", account, source, destination]];
        }
        migrationObservation = [results componentsJoinedByString:@"; "];
    }

    NSString *observation = [NSString stringWithFormat:
        @"Stage %@ (pid %d; host/extension processes %@): file read %@; synthetic file write %@; host-only Keychain %@; app-ID control Keychain %@; signing-export open %@; %@.",
        stageName, probePID, processObservation, fileReadOutcome, fileWriteOutcome, hostOnlyKeychainOutcome, sharedKeychainOutcome, signingExportOutcome, migrationObservation];
    NSLog(@"CVLP_STAGE %@", observation);
    NSArray<NSString *> *allStageObservations;
    BOOL bookmarkActivated;
    @synchronized (self) {
        if (CVLPStageObservations == nil) { CVLPStageObservations = [NSMutableArray array]; }
        [CVLPStageObservations addObject:observation];
        allStageObservations = [CVLPStageObservations copy];
        bookmarkActivated = CVLPGuestBookmarkActivated;
    }
    if (bookmarkActivated) { CVLPWriteGuestReportIfAuthorized(allStageObservations); }
    return [allStageObservations componentsJoinedByString:@"\n"];
}

+ (NSString *)hostSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"Synthetic LiveProcess boundary observations (not a security certification)"];
    @synchronized (self) {
        [lines addObjectsFromArray:CVLPHostObservations ?: @[]];
        [lines addObject:[NSString stringWithFormat:@"Host sentinel after guest activity: %@.", CVLPHostSentinelVerification()]];
    }

    NSDictionary *info;
    @synchronized (self) { info = CVLPHostLaunchInfo; }
    NSString *reportPath = info[@"reportPath"];
    if ([reportPath isKindOfClass:NSString.class]) {
        NSData *reportData = [NSData dataWithContentsOfFile:reportPath];
        NSString *report = reportData != nil ? [[NSString alloc] initWithData:reportData encoding:NSUTF8StringEncoding] : nil;
        if (report.length > 0) {
            [lines addObject:@"LiveProcess stages:"];
            for (NSString *line in [report componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                if (line.length > 0) { [lines addObject:line]; }
            }
        } else {
            [lines addObject:@"LiveProcess stages: no authorized guest report is available yet."];
        }
    } else {
        [lines addObject:@"LiveProcess stages: host setup has not completed."];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end
