#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>
#import "../Shared/SyntheticProbeReport.h"

@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray<NSExtensionItem *> *)items
                                completion:(void (^)(NSUUID *identifier))completion;
@end

@interface SyntheticProbeAppDelegate : UIResponder <UIApplicationDelegate, NSXPCListenerDelegate, SyntheticProbeReport>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) NSXPCConnection *reportConnection;
@property (nonatomic, strong) NSExtension *extension;
@property (nonatomic, strong) NSURL *syntheticFileURL;
@property (nonatomic, strong) NSTimer *timeoutTimer;
@property (nonatomic, assign) BOOL probePending;
@end

@implementation SyntheticProbeAppDelegate

static NSString *const SyntheticKeychainService = @"org.example.calcvault.synthetic-boundary-probe";
static NSString *const SyntheticKeychainAccount = @"synthetic-host-only";

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
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: SyntheticKeychainService,
        (__bridge id)kSecAttrAccount: SyntheticKeychainAccount
    };
}

- (void)runProbe {
    if (self.probePending) { return; }
    self.probePending = YES;
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
        [self failWithMessage:[NSString stringWithFormat:@"Keychain fixture setup failed (%d).", (int)addStatus]];
        return;
    }

    self.listener = [NSXPCListener anonymousListener];
    self.listener.delegate = self;
    [self.listener resume];
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
        @"reportEndpoint": self.listener.endpoint
    };
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

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyntheticProbeReport)];
    connection.exportedObject = self;
    self.reportConnection = connection;
    [connection activate];
    return YES;
}

- (void)reportFileReadable:(BOOL)fileReadable
             fileErrorCode:(NSInteger)fileErrorCode
            keychainStatus:(NSInteger)keychainStatus
             extensionPID:(int)extensionPID
                    reply:(void (^)(void))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.probePending) { reply(); return; }
        NSString *fileResult = fileReadable ? @"READABLE" : @"NOT READABLE";
        NSString *keychainResult = keychainStatus == errSecSuccess ? @"READABLE" : @"NOT READABLE";
        self.statusLabel.text = [NSString stringWithFormat:
            @"Host PID: %d\nExtension PID: %d\nHost file: %@ (error %ld)\nHost Keychain item: %@ (status %ld)",
            getpid(), extensionPID, fileResult, (long)fileErrorCode, keychainResult, (long)keychainStatus];
        NSLog(@"SYNTHETIC_DEVICE_BOUNDARY_RESULT hostPID=%d extensionPID=%d file=%@ keychain=%@ keychainStatus=%ld",
              getpid(), extensionPID, fileResult, keychainResult, (long)keychainStatus);
        reply();
        [self finishProbe];
    });
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
    [self.listener invalidate];
    self.listener = nil;
    [self.reportConnection invalidate];
    self.reportConnection = nil;
    SecItemDelete((__bridge CFDictionaryRef)[self syntheticKeychainQuery]);
    if (self.syntheticFileURL != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:self.syntheticFileURL error:nil];
        self.syntheticFileURL = nil;
    }
}

@end
