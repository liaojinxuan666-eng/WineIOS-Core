#import "WIOSViewController.h"
#import "WIOSCapabilityProbe.h"
#import "WIOSLog.h"

@interface WIOSViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation WIOSViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.text = @"Wine-iOS Core 0.0.1 (1)";

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.layer.borderWidth = 1;
    self.textView.layer.borderColor = UIColor.separatorColor.CGColor;
    self.textView.layer.cornerRadius = 8;

    UIButton *safeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    safeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [safeButton setTitle:@"重新运行安全探针" forState:UIControlStateNormal];
    [safeButton addTarget:self action:@selector(runSafeProbes) forControlEvents:UIControlEventTouchUpInside];

    UIButton *jitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    jitButton.translatesAutoresizingMaskIntoConstraints = NO;
    [jitButton setTitle:@"运行 JIT 执行探针" forState:UIControlStateNormal];
    [jitButton addTarget:self action:@selector(confirmJITProbe) forControlEvents:UIControlEventTouchUpInside];

    UIButton *shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [shareButton setTitle:@"分享日志" forState:UIControlStateNormal];
    [shareButton addTarget:self action:@selector(shareLog) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[safeButton, jitButton, shareButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 8;

    [self.view addSubview:title];
    [self.view addSubview:self.textView];
    [self.view addSubview:buttons];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [title.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [self.textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.textView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [buttons.topAnchor constraintEqualToAnchor:self.textView.bottomAnchor constant:10],
        [buttons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [buttons.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12]
    ]];

    [[WIOSLog shared] resetForNewSession];
    [[WIOSLog shared] appendLevel:@"INFO" key:@"VERSION" value:@"0.0.1 (1)"];
    [[WIOSLog shared] appendLevel:@"INFO" key:@"WINE_BASELINE"
                           value:@"wine-11.0@db11d0fe6a169c457e23d007e20404643d067aa8"];
    [[WIOSLog shared] appendLevel:@"INFO" key:@"WINE_RUNTIME" value:@"NOT_BUNDLED (expected in 0.0.1)"];
    [WIOSCapabilityProbe runSafeProbes];
    [self refreshLog];
}

- (void)runSafeProbes
{
    [WIOSCapabilityProbe runSafeProbes];
    [self refreshLog];
}

- (void)confirmJITProbe
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"JIT 执行探针"
        message:@"这个测试会执行 8 字节动态生成的 ARM64 代码。如果当前签名/JIT 环境冲突，App 可能退出。日志会先落盘。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"运行" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [WIOSCapabilityProbe runJITExecutionProbe];
            [self refreshLog];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareLog
{
    UIActivityViewController *controller = [[UIActivityViewController alloc]
        initWithActivityItems:@[[WIOSLog shared].fileURL] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.view;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)refreshLog
{
    self.textView.text = [[WIOSLog shared] contents];
    if (self.textView.text.length) {
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
    }
}

@end

