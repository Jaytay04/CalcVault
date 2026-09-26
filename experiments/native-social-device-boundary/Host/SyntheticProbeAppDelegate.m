#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <TargetConditionals.h>
#import <unistd.h>

@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray<NSExtensionItem *> *)items
                                completion:(void (^)(NSUUID *identifier))completion;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *identifier, NSArray<NSExtensionItem *> *items))completion;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *identifier, NSError *error))cancellation;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *identifier))interruption;
@end

@interface SyntheticProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) NSExtension *extension;
@property (nonatomic, strong) NSURL *syntheticFileURL;
@property (nonatomic, strong) NSURL *syntheticGuestFolderURL;
@property (nonatomic, strong) NSTimer *timeoutTimer;
@property (nonatomic, assign) BOOL probePending;
@property (nonatomic, assign) BOOL keychainFixtureCreated;
@property (nonatomic, copy) NSString *sharedAppAccessGroup;
@property (nonatomic, copy) NSString *hostOnlyAccessGroup;
@property (nonatomic, assign) BOOL hostOnlyFixtureCreated;
@end

@implementation SyntheticProbeAppDelegate

static NSString *const SyntheticKeychainService = @"org.example.calcvault.synthetic-boundary-probe";
static NSString *const SyntheticKeychainAccount = @"synthetic-host-only";
static NSString *const HostOnlyKeychainAccount = @"synthetic-host-explicit-group";
static NSString *const HostOnlyGroupSuffix = @".com.jaylintaylor.calcvault.hostonly";

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.text = @"Synthetic bookmark test";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.numberOfLines = 0;

    UILabel *explanation = [UILabel new];
    explanation.text = @"This disposable app grants its extension a synthetic guest-folder bookmark, then checks host file and Keychain isolation. It does not open CalcVault data.";
    explanation.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    explanation.numberOfLines = 0;

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"Starting test…";
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.accessibilityIdentifier = @"syntheticProbeStatus";

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run test again" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, explanation, self.statusLabel, self.runButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.centerYAnchor]
    ]];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self runProbe];
    });
    return YES;
}

- (NSDictionary *)syntheticKeychainQuery {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: SyntheticKeychainService,
        (__bridge id)kSecAttrAccount: SyntheticKeychainAccount
    } mutableCopy];
    if (self.sharedAppAccessGroup.length > 0) {
        query[(__bridge id)kSecAttrAccessGroup] = self.sharedAppAccessGroup;
    }
    return query;
}

- (NSString *)discoverDefaultAccessGroup {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: SyntheticKeychainService,
        (__bridge id)kSecAttrAccount: @"synthetic-group-discovery"
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) { return nil; }
    NSMutableDictionary *item = [query mutableCopy];
    item[(__bridge id)kSecValueData] = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    memset(bytes, 0, sizeof(bytes));
    if (SecItemAdd((__bridge CFDictionaryRef)item, NULL) != errSecSuccess) { return nil; }
    NSMutableDictionary *attributesQuery = [query mutableCopy];
    attributesQuery[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)attributesQuery, &result);
    id attributesValue = status == errSecSuccess && result != NULL ? (__bridge id)result : nil;
    NSDictionary *attributes = [attributesValue isKindOfClass:NSDictionary.class] ? attributesValue : nil;
    NSString *group = [attributes[(__bridge id)kSecAttrAccessGroup] copy];
    if (result != NULL) { CFRelease(result); }
    SecItemDelete((__bridge CFDictionaryRef)query);
    return group;
}

- (NSDictionary *)hostOnlyKeychainQuery {
    if (self.hostOnlyAccessGroup.length == 0) { return nil; }
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: SyntheticKeychainService,
        (__bridge id)kSecAttrAccount: HostOnlyKeychainAccount,
        (__bridge id)kSecAttrAccessGroup: self.hostOnlyAccessGroup
    };
}

- (void)runProbe {
    if (self.probePending) { return; }
    self.probePending = YES;
    self.keychainFixtureCreated = NO;
    self.sharedAppAccessGroup = nil;
    self.hostOnlyFixtureCreated = NO;
    self.hostOnlyAccessGroup = nil;
    self.runButton.enabled = NO;
    self.statusLabel.text = @"Preparing synthetic fixtures…";

    NSError *error = nil;
    NSURL *supportURL = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:&error];
    if (supportURL == nil) {
        [self failWithMessage:@"Host file setup failed."];
        return;
    }
    NSString *fileName = [NSString stringWithFormat:@"synthetic-boundary-%@.txt", NSUUID.UUID.UUIDString];
    self.syntheticFileURL = [supportURL URLByAppendingPathComponent:fileName];
    NSData *fixture = [@"Synthetic host-only fixture" dataUsingEncoding:NSUTF8StringEncoding];
    if (![fixture writeToURL:self.syntheticFileURL options:NSDataWritingAtomic error:&error]) {
        [self failWithMessage:@"Host file setup failed."];
        return;
    }

    NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                 inDomains:NSUserDomainMask].firstObject;
    if (documentsURL == nil) {
        [self failWithMessage:@"Synthetic guest folder setup failed."];
        return;
    }
    self.syntheticGuestFolderURL = [documentsURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"synthetic-guest-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:self.syntheticGuestFolderURL
                                  withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self failWithMessage:@"Synthetic guest folder setup failed."];
        return;
    }
    NSURL *guestMarkerURL = [self.syntheticGuestFolderURL URLByAppendingPathComponent:@"guest-marker.txt"];
    NSData *guestMarker = [@"Synthetic guest bookmark fixture" dataUsingEncoding:NSUTF8StringEncoding];
    if (![guestMarker writeToURL:guestMarkerURL options:NSDataWritingAtomic error:&error]) {
        [self failWithMessage:@"Synthetic guest folder setup failed."];
        return;
    }
    NSData *guestBookmark = [self.syntheticGuestFolderURL bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)(1 << 11)
                                  includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    if (guestBookmark.length == 0) {
        [self failWithMessage:@"Guest-folder bookmark creation failed. No isolation conclusion."];
        return;
    }

    NSString *defaultAccessGroup = [self discoverDefaultAccessGroup];
    NSRange prefixEnd = [defaultAccessGroup rangeOfString:@"."];
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (prefixEnd.location == NSNotFound || prefixEnd.location == 0 || bundleID.length == 0) {
#if TARGET_OS_SIMULATOR
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_GROUP_DISCOVERY_NOT_TESTED");
#else
        [self failWithMessage:@"Signed Keychain group could not be discovered. No isolation conclusion."];
        return;
#endif
    } else {
        NSString *teamPrefix = [defaultAccessGroup substringToIndex:prefixEnd.location];
        self.sharedAppAccessGroup = [NSString stringWithFormat:@"%@.%@", teamPrefix, bundleID];
        self.hostOnlyAccessGroup = [teamPrefix stringByAppendingString:HostOnlyGroupSuffix];
    }
    if (self.sharedAppAccessGroup.length == 0) {
#if TARGET_OS_SIMULATOR
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_SHARED_GROUP_NOT_TESTED");
#else
        [self failWithMessage:@"App-ID Keychain group could not be derived after signing. No isolation conclusion."];
        return;
#endif
    } else {
        SecItemDelete((__bridge CFDictionaryRef)[self syntheticKeychainQuery]);
        uint8_t randomBytes[32];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(randomBytes), randomBytes) != errSecSuccess) {
            [self failWithMessage:@"Keychain fixture setup failed."];
            return;
        }
        NSMutableDictionary *item = [[self syntheticKeychainQuery] mutableCopy];
        item[(__bridge id)kSecValueData] = [NSData dataWithBytes:randomBytes length:sizeof(randomBytes)];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        memset(randomBytes, 0, sizeof(randomBytes));
        OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (addStatus != errSecSuccess) {
            NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SHARED_GROUP_CONTROL_NOT_TESTED status=%d", (int)addStatus);
        } else {
            self.keychainFixtureCreated = YES;
        }
    }

    if (self.hostOnlyAccessGroup.length == 0) {
#if TARGET_OS_SIMULATOR
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_HOST_GROUP_FIXTURE_NOT_TESTED");
#else
        [self failWithMessage:@"Host-only Keychain group could not be derived after signing. No isolation conclusion."];
        return;
#endif
    } else {
        NSDictionary *hostOnlyQuery = [self hostOnlyKeychainQuery];
        SecItemDelete((__bridge CFDictionaryRef)hostOnlyQuery);
        uint8_t groupBytes[32];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(groupBytes), groupBytes) != errSecSuccess) {
            [self failWithMessage:@"Host-only Keychain fixture setup failed."];
            return;
        }
        NSMutableDictionary *groupItem = [hostOnlyQuery mutableCopy];
        groupItem[(__bridge id)kSecValueData] = [NSData dataWithBytes:groupBytes length:sizeof(groupBytes)];
        groupItem[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        memset(groupBytes, 0, sizeof(groupBytes));
        OSStatus groupAddStatus = SecItemAdd((__bridge CFDictionaryRef)groupItem, NULL);
        if (groupAddStatus != errSecSuccess) {
#if TARGET_OS_SIMULATOR
            NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_HOST_GROUP_NOT_TESTED status=%d", (int)groupAddStatus);
#else
            [self failWithMessage:[NSString stringWithFormat:@"Host-only Keychain fixture setup failed (%d).", (int)groupAddStatus]];
            return;
#endif
        } else {
            self.hostOnlyFixtureCreated = YES;
            NSMutableDictionary *verifyQuery = [hostOnlyQuery mutableCopy];
            verifyQuery[(__bridge id)kSecReturnData] = @YES;
            CFTypeRef verifiedValue = NULL;
            OSStatus verifyStatus = SecItemCopyMatching((__bridge CFDictionaryRef)verifyQuery, &verifiedValue);
            if (verifiedValue != NULL) { CFRelease(verifiedValue); }
            if (verifyStatus != errSecSuccess) {
                [self failWithMessage:[NSString stringWithFormat:@"Host-only Keychain readback failed (%d).", (int)verifyStatus]];
                return;
            }
        }
    }

    NSBundle *extensionBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"SyntheticBoundaryExtension.appex"]];
    if (extensionBundle.bundleIdentifier.length == 0) {
        [self failWithMessage:@"Extension missing after signing. Stop the test."];
        return;
    }
    self.extension = [NSExtension extensionWithIdentifier:extensionBundle.bundleIdentifier error:&error];
    if (self.extension == nil) {
        [self failWithMessage:[NSString stringWithFormat:@"Extension activation unavailable (%ld).", (long)error.code]];
        return;
    }

    NSExtensionItem *request = [NSExtensionItem new];
    request.userInfo = @{
        @"hostFile": self.syntheticFileURL.path,
        @"guestBookmark": guestBookmark,
        @"keychainService": SyntheticKeychainService,
        @"sharedGroup": self.sharedAppAccessGroup ?: @"",
        @"hostOnlyGroup": self.hostOnlyAccessGroup ?: @""
    };
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestCompletionBlock:^(NSUUID *identifier, NSArray<NSExtensionItem *> *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleExtensionItems:items];
        });
    }];
    [self.extension setRequestCancellationBlock:^(NSUUID *identifier, NSError *requestError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.probePending) {
                [weakSelf failWithMessage:[NSString stringWithFormat:@"Extension cancelled (%ld).", (long)requestError.code]];
            }
        });
    }];
    [self.extension setRequestInterruptionBlock:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.probePending) { [weakSelf failWithMessage:@"Extension process interrupted."]; }
        });
    }];
    self.statusLabel.text = @"Waiting for the separate extension process…";
    self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:45
                                                        target:self
                                                      selector:@selector(probeTimedOut)
                                                      userInfo:nil
                                                       repeats:NO];
    [self.extension beginExtensionRequestWithInputItems:@[request] completion:^(NSUUID *identifier) {
        if (identifier == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.probePending) { [self failWithMessage:@"Extension request failed to start."]; }
            });
        }
    }];
}

- (void)handleExtensionItems:(NSArray<NSExtensionItem *> *)items {
    if (!self.probePending) { return; }
    NSDictionary *report = items.firstObject.userInfo;
    NSNumber *bookmarkActiveValue = report[@"bookmarkActive"];
    NSNumber *bookmarkResolvedValue = report[@"bookmarkResolved"];
    NSNumber *bookmarkStaleValue = report[@"bookmarkStale"];
    NSNumber *bookmarkErrorValue = report[@"bookmarkError"];
    NSNumber *guestMarkerValue = report[@"guestMarkerReadable"];
    NSNumber *guestReadErrorValue = report[@"guestReadError"];
    NSNumber *fileBeforeValue = report[@"fileReadableBefore"];
    NSNumber *fileBeforeErrorValue = report[@"fileErrorBefore"];
    NSNumber *fileAfterValue = report[@"fileReadableAfter"];
    NSNumber *fileAfterErrorValue = report[@"fileErrorAfter"];
    NSNumber *fileWriteValue = report[@"fileWriteSucceeded"];
    NSNumber *sharedStatusValue = report[@"sharedStatusAfter"];
    NSNumber *hostOnlyBeforeValue = report[@"hostOnlyStatusBefore"];
    NSNumber *hostOnlyAfterValue = report[@"hostOnlyStatusAfter"];
    NSNumber *extensionPIDValue = report[@"extensionPID"];
    if (![bookmarkActiveValue isKindOfClass:NSNumber.class] ||
        ![bookmarkResolvedValue isKindOfClass:NSNumber.class] ||
        ![bookmarkStaleValue isKindOfClass:NSNumber.class] ||
        ![bookmarkErrorValue isKindOfClass:NSNumber.class] ||
        ![guestMarkerValue isKindOfClass:NSNumber.class] ||
        ![guestReadErrorValue isKindOfClass:NSNumber.class] ||
        ![fileBeforeValue isKindOfClass:NSNumber.class] ||
        ![fileBeforeErrorValue isKindOfClass:NSNumber.class] ||
        ![fileAfterValue isKindOfClass:NSNumber.class] ||
        ![fileAfterErrorValue isKindOfClass:NSNumber.class] ||
        ![fileWriteValue isKindOfClass:NSNumber.class] ||
        ![sharedStatusValue isKindOfClass:NSNumber.class] ||
        ![hostOnlyBeforeValue isKindOfClass:NSNumber.class] ||
        ![hostOnlyAfterValue isKindOfClass:NSNumber.class] ||
        ![extensionPIDValue isKindOfClass:NSNumber.class]) {
        [self failWithMessage:@"Extension returned an invalid report."];
        return;
    }
    BOOL bookmarkActive = bookmarkActiveValue.boolValue;
    BOOL bookmarkResolved = bookmarkResolvedValue.boolValue;
    BOOL bookmarkStale = bookmarkStaleValue.boolValue;
    BOOL guestMarkerReadable = guestMarkerValue.boolValue;
    BOOL fileBefore = fileBeforeValue.boolValue;
    BOOL fileAfter = fileAfterValue.boolValue;
    BOOL fileWrite = fileWriteValue.boolValue;
    NSInteger sharedStatus = sharedStatusValue.integerValue;
    NSInteger hostOnlyBefore = hostOnlyBeforeValue.integerValue;
    NSInteger hostOnlyAfter = hostOnlyAfterValue.integerValue;
    int extensionPID = extensionPIDValue.intValue;
    if (extensionPID <= 0 || extensionPID == getpid()) {
        [self failWithMessage:@"Separate extension process was not verified."];
        return;
    }
    NSData *currentHostData = [NSData dataWithContentsOfURL:self.syntheticFileURL];
    NSString *currentHostValue = currentHostData == nil ? nil
        : [[NSString alloc] initWithData:currentHostData encoding:NSUTF8StringEncoding];
    BOOL hostFileUnchanged = [currentHostValue isEqualToString:@"Synthetic host-only fixture"];
    NSString *sharedResult = self.keychainFixtureCreated
        ? (sharedStatus == errSecSuccess ? @"READABLE" : @"NOT READABLE")
        : @"NOT TESTED (host fixture unavailable)";
    NSString *hostOnlyBeforeResult = self.hostOnlyFixtureCreated
        ? (hostOnlyBefore == errSecSuccess ? @"READABLE" : @"NOT READABLE")
        : @"NOT TESTED (host fixture unavailable)";
    NSString *hostOnlyAfterResult = self.hostOnlyFixtureCreated
        ? (hostOnlyAfter == errSecSuccess ? @"READABLE" : @"NOT READABLE")
        : @"NOT TESTED (host fixture unavailable)";
    self.statusLabel.text = [NSString stringWithFormat:
        @"Host PID: %d\nExtension PID: %d\nBookmark resolved: %@ (%ld)\nBookmark stale: %@\nBookmark access: %@\nGuest marker: %@ (%ld)\nHost file before: %@ (%ld)\nHost file after: %@ (%ld)\nHost write after: %@\nHost file unchanged: %@\nShared Keychain after: %@ (%ld)\nHost-only before: %@ (%ld)\nHost-only after: %@ (%ld)",
        getpid(), extensionPID,
        bookmarkResolved ? @"YES" : @"NO", (long)bookmarkErrorValue.integerValue,
        bookmarkStale ? @"YES" : @"NO",
        bookmarkActive ? @"ACTIVE" : @"NOT ACTIVE",
        guestMarkerReadable ? @"READABLE" : @"NOT READABLE", (long)guestReadErrorValue.integerValue,
        fileBefore ? @"READABLE" : @"NOT READABLE", (long)fileBeforeErrorValue.integerValue,
        fileAfter ? @"READABLE" : @"NOT READABLE", (long)fileAfterErrorValue.integerValue,
        fileWrite ? @"SUCCEEDED" : @"DENIED", hostFileUnchanged ? @"YES" : @"NO",
        sharedResult, (long)sharedStatus, hostOnlyBeforeResult, (long)hostOnlyBefore,
        hostOnlyAfterResult, (long)hostOnlyAfter];
    NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_RESULT hostPID=%d extensionPID=%d bookmarkResolved=%@ bookmarkError=%ld bookmarkStale=%@ bookmark=%@ guest=%@ guestError=%ld fileBefore=%@ fileAfter=%@ write=%@ unchanged=%@ sharedKeychain=%@ hostOnlyBefore=%@ hostOnlyAfter=%@",
          getpid(), extensionPID, bookmarkResolved ? @"YES" : @"NO", (long)bookmarkErrorValue.integerValue,
          bookmarkStale ? @"YES" : @"NO", bookmarkActive ? @"ACTIVE" : @"NOT_ACTIVE",
          guestMarkerReadable ? @"READABLE" : @"NOT_READABLE", (long)guestReadErrorValue.integerValue,
          fileBefore ? @"READABLE" : @"NOT_READABLE", fileAfter ? @"READABLE" : @"NOT_READABLE",
          fileWrite ? @"SUCCEEDED" : @"DENIED", hostFileUnchanged ? @"YES" : @"NO",
          sharedResult, hostOnlyBeforeResult, hostOnlyAfterResult);
    [self finishProbe];
}

- (void)probeTimedOut {
    if (self.probePending) { [self failWithMessage:@"Extension did not report within 45 seconds. No isolation conclusion."]; }
}

- (void)failWithMessage:(NSString *)message {
    self.statusLabel.text = message;
    NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_INCONCLUSIVE %@", message);
    [self finishProbe];
}

- (void)finishProbe {
    self.probePending = NO;
    self.runButton.enabled = YES;
    [self.timeoutTimer invalidate];
    self.timeoutTimer = nil;
    if (self.keychainFixtureCreated) {
        SecItemDelete((__bridge CFDictionaryRef)[self syntheticKeychainQuery]);
        self.keychainFixtureCreated = NO;
    }
    self.sharedAppAccessGroup = nil;
    if (self.hostOnlyFixtureCreated) {
        SecItemDelete((__bridge CFDictionaryRef)[self hostOnlyKeychainQuery]);
        self.hostOnlyFixtureCreated = NO;
    }
    self.hostOnlyAccessGroup = nil;
    if (self.syntheticFileURL != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:self.syntheticFileURL error:nil];
        self.syntheticFileURL = nil;
    }
    if (self.syntheticGuestFolderURL != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:self.syntheticGuestFolderURL error:nil];
        self.syntheticGuestFolderURL = nil;
    }
}

@end
