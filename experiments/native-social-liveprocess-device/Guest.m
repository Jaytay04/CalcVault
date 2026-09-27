#import <UIKit/UIKit.h>
#import <objc/message.h>

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
