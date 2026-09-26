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
    title.text = @"Synthetic isolation test";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.numberOfLines = 0;

    UILabel *explanation = [UILabel new];
    explanation.text = @"This disposable app tests whether its extension can read a synthetic host file and Keychain item. It does not open CalcVault data.";
    explanation.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    explanation.numberOfLines = 0;

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"Starting test…";
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.accessibilityIdentifier = @"syntheticProbeStatus";

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run test again" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, explanation, self.statusLabel, self.runButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
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

    self.hostOnlyAccessGroup = [self discoverDefaultAccessGroup];
    if (![self.hostOnlyAccessGroup hasSuffix:HostOnlyGroupSuffix]) {
        self.hostOnlyAccessGroup = nil;
#if TARGET_OS_SIMULATOR
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_HOST_GROUP_NOT_TESTED");
#else
        [self failWithMessage:@"Host-only Keychain group was not granted after signing. No isolation conclusion."];
        return;
#endif
    } else {
        NSRange prefixEnd = [self.hostOnlyAccessGroup rangeOfString:@"."];
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (prefixEnd.location != NSNotFound && prefixEnd.location > 0 && bundleID.length > 0) {
            self.sharedAppAccessGroup = [NSString stringWithFormat:@"%@.%@",
                [self.hostOnlyAccessGroup substringToIndex:prefixEnd.location], bundleID];
        }
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
#if TARGET_OS_SIMULATOR
            NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_SHARED_GROUP_NOT_TESTED status=%d", (int)addStatus);
#else
            [self failWithMessage:[NSString stringWithFormat:@"Keychain fixture setup failed (%d).", (int)addStatus]];
            return;
#endif
        } else {
            self.keychainFixtureCreated = YES;
        }
    }

    if (self.hostOnlyAccessGroup.length == 0) {
#if TARGET_OS_SIMULATOR
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_SIMULATOR_HOST_GROUP_FIXTURE_NOT_TESTED");
#else
        [self failWithMessage:@"Host-only Keychain group was not granted after signing. No isolation conclusion."];
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
    NSNumber *fileReadableValue = report[@"fileReadable"];
    NSNumber *fileErrorCodeValue = report[@"fileErrorCode"];
    NSNumber *keychainStatusValue = report[@"keychainStatus"];
    NSNumber *hostOnlyStatusValue = report[@"hostOnlyStatus"];
    NSNumber *extensionPIDValue = report[@"extensionPID"];
    if (![fileReadableValue isKindOfClass:NSNumber.class] ||
        ![fileErrorCodeValue isKindOfClass:NSNumber.class] ||
        ![keychainStatusValue isKindOfClass:NSNumber.class] ||
        ![hostOnlyStatusValue isKindOfClass:NSNumber.class] ||
        ![extensionPIDValue isKindOfClass:NSNumber.class]) {
        [self failWithMessage:@"Extension returned an invalid report."];
        return;
    }
    BOOL fileReadable = fileReadableValue.boolValue;
    NSInteger fileErrorCode = fileErrorCodeValue.integerValue;
    NSInteger keychainStatus = keychainStatusValue.integerValue;
    NSInteger hostOnlyStatus = hostOnlyStatusValue.integerValue;
    int extensionPID = extensionPIDValue.intValue;
    if (extensionPID <= 0 || extensionPID == getpid()) {
        [self failWithMessage:@"Separate extension process was not verified."];
        return;
    }
    NSString *fileResult = fileReadable ? @"READABLE" : @"NOT READABLE";
    NSString *keychainResult = self.keychainFixtureCreated
        ? (keychainStatus == errSecSuccess ? @"READABLE" : @"NOT READABLE")
        : @"NOT TESTED (host fixture unavailable)";
    NSString *hostOnlyResult = self.hostOnlyFixtureCreated
        ? (hostOnlyStatus == errSecSuccess ? @"READABLE" : @"NOT READABLE")
        : @"NOT TESTED (host fixture unavailable)";
    self.statusLabel.text = [NSString stringWithFormat:
        @"Host PID: %d\nExtension PID: %d\nHost file: %@ (error %ld)\nShared app-ID Keychain: %@ (status %ld)\nHost-only Keychain: %@ (status %ld)",
        getpid(), extensionPID, fileResult, (long)fileErrorCode, keychainResult, (long)keychainStatus,
        hostOnlyResult, (long)hostOnlyStatus];
    NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_RESULT hostPID=%d extensionPID=%d file=%@ sharedKeychain=%@ hostOnlyKeychain=%@",
          getpid(), extensionPID, fileResult, keychainResult, hostOnlyResult);
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
}

@end
