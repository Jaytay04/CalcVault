#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSData *SyntheticTone(void) {
    const uint32_t sampleRate = 22050, sampleCount = 22050, byteCount = sampleCount * 2;
    NSMutableData *data = [NSMutableData data];
    void (^u32)(uint32_t) = ^(uint32_t value) { value = CFSwapInt32HostToLittle(value); [data appendBytes:&value length:4]; };
    void (^u16)(uint16_t) = ^(uint16_t value) { value = CFSwapInt16HostToLittle(value); [data appendBytes:&value length:2]; };
    [data appendBytes:"RIFF" length:4]; u32(36 + byteCount);
    [data appendBytes:"WAVEfmt " length:8]; u32(16); u16(1); u16(1);
    u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16);
    [data appendBytes:"data" length:4]; u32(byteCount);
    for (uint32_t i = 0; i < sampleCount; i++) {
        u16((uint16_t)(int16_t)(2000 * sin(2 * M_PI * 440 * i / sampleRate)));
    }
    return data;
}

static NSString *RunProbe(NSString *stage) {
    Class probe = NSClassFromString(@"CVLPProbe");
    SEL selector = NSSelectorFromString(@"recordStage:");
    if (!probe || ![probe respondsToSelector:selector]) {
        return @"INCONCLUSIVE: the LiveProcess probe is unavailable.";
    }
    return ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(probe, selector, stage);
}

@interface CVLPGuestController : UIViewController
@property(nonatomic, strong) UILabel *report;
@property(nonatomic, strong) UILabel *counter;
@property(nonatomic) NSInteger taps;
@property(nonatomic) BOOL checked;
@property(nonatomic, strong) AVAudioPlayer *tone;
@property(nonatomic, strong) UIButton *toneButton;
@end

@implementation CVLPGuestController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILabel *title = [UILabel new];
    title.text = @"Synthetic native guest";
    title.numberOfLines = 0;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    [stack addArrangedSubview:title];
    self.counter = [UILabel new];
    self.counter.text = @"Taps: 0";
    [stack addArrangedSubview:self.counter];
    UIButton *tap = [UIButton buttonWithType:UIButtonTypeSystem];
    [tap setTitle:@"Tap native control" forState:UIControlStateNormal];
    [tap addTarget:self action:@selector(increment) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:tap];
    UIButton *check = [UIButton buttonWithType:UIButtonTypeSystem];
    [check setTitle:@"Run boundary tests again" forState:UIControlStateNormal];
    [check addTarget:self action:@selector(checkBoundary) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:check];
    self.toneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.toneButton setTitle:@"Start test tone (low volume)" forState:UIControlStateNormal];
    [self.toneButton addTarget:self action:@selector(toggleTone) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.toneButton];
    self.report = [UILabel new];
    self.report.numberOfLines = 0;
    self.report.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.report.text = @"Starting synthetic observations...";
    [stack addArrangedSubview:self.report];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.checked) {
        self.checked = YES;
        self.report.text = RunProbe(@"guest-entry");
        if (self.view.window.windowScene != nil && !CGRectIsEmpty(self.view.window.bounds)) {
            NSLog(@"CVLP_GUEST_VISIBLE");
        } else {
            NSLog(@"CVLP_UI_VIEW_UNATTACHED");
        }
    }
}
- (void)increment {
    self.taps += 1;
    self.counter.text = [NSString stringWithFormat:@"Taps: %ld", (long)self.taps];
}
- (void)checkBoundary { self.report.text = RunProbe(@"guest-button"); }
- (void)toggleTone {
    if (self.tone.isPlaying) {
        [self.tone stop];
        [AVAudioSession.sharedInstance setActive:NO error:nil];
        [self.toneButton setTitle:@"Start test tone (low volume)" forState:UIControlStateNormal];
        return;
    }
    NSError *error = nil;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (!error) [AVAudioSession.sharedInstance setActive:YES error:&error];
    if (!error) self.tone = [[AVAudioPlayer alloc] initWithData:SyntheticTone() error:&error];
    self.tone.numberOfLoops = -1;
    if (error || ![self.tone play]) {
        [self.toneButton setTitle:@"Test tone unavailable" forState:UIControlStateNormal];
        return;
    }
    [self.toneButton setTitle:@"Stop test tone" forState:UIControlStateNormal];
    NSLog(@"CVLP_GUEST_TONE_STARTED_BY_USER");
}
@end

@interface CVLPGuestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation CVLPGuestSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) {
        NSLog(@"CVLP_UI_UNEXPECTED_SCENE");
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    self.window.rootViewController = [CVLPGuestController new];
    [self.window makeKeyAndVisible];
    NSLog(@"CVLP_UI scene-attached");
}
@end

@interface CVLPGuestDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation CVLPGuestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSLog(@"CVLP_UI application-launched");
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
    options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Synthetic Guest Scene"
                                                                        sessionRole:connectingSceneSession.role];
    configuration.delegateClass = CVLPGuestSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(CVLPGuestDelegate.class));
    }
}
