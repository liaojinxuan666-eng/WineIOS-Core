#import "WIOSViewController.h"
#import "WIOSCapabilityProbe.h"
#import "WIOSLog.h"
#import "WIOSRuntimeABI.h"

static void WIOSRuntimeLogCallback(void *context, const char *line)
{
    (void)context;
    @autoreleasepool {
        NSString *value = line ? [NSString stringWithUTF8String:line] : @"(null)";
        if (!value) value = @"(invalid utf8)";
        [[WIOSLog shared] appendLevel:@"INFO" key:@"WINE_RUNTIME" value:value];
    }
}

@interface WIOSViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation WIOSViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.text = [NSString stringWithFormat:@"Arcadia Wine Core %@ (%@)", version, build];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.layer.borderWidth = 1;
    self.textView.layer.borderColor = UIColor.separatorColor.CGColor;
    self.textView.layer.cornerRadius = 8;

    UIButton *runtimeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    runtimeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [runtimeButton setTitle:@"运行 Wine Runtime 探针" forState:UIControlStateNormal];
    [runtimeButton addTarget:self action:@selector(runWineRuntimeProbe)
            forControlEvents:UIControlEventTouchUpInside];

    UIButton *safeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    safeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [safeButton setTitle:@"重新运行安全探针" forState:UIControlStateNormal];
    [safeButton addTarget:self action:@selector(runSafeProbes)
           forControlEvents:UIControlEventTouchUpInside];

    UIButton *shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [shareButton setTitle:@"分享日志" forState:UIControlStateNormal];
    [shareButton addTarget:self action:@selector(shareLog)
            forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc]
        initWithArrangedSubviews:@[runtimeButton, safeButton, shareButton]];
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
    [[WIOSLog shared] appendLevel:@"INFO" key:@"VERSION"
                           value:[NSString stringWithFormat:@"%@ (%@)", version, build]];
    [[WIOSLog shared] appendLevel:@"INFO" key:@"WINE_BASELINE"
                           value:@"wine-11.0@db11d0fe6a169c457e23d007e20404643d067aa8"];

    [WIOSCapabilityProbe runSafeProbes];
    [self runWineRuntimeProbe];
}

- (void)runSafeProbes
{
    [WIOSCapabilityProbe runSafeProbes];
    [self refreshLog];
}

- (void)runWineRuntimeProbe
{
    const wios_runtime_api *api =
        wios_runtime_get_api(WIOS_RUNTIME_ABI_VERSION);

    if (!api)
    {
        [[WIOSLog shared] appendLevel:@"ERROR"
                                  key:@"WINE_RUNTIME"
                                value:@"RUNTIME_ABI=FAIL"];
        [self refreshLog];
        return;
    }

    NSString *bundleRoot = [NSBundle mainBundle].bundlePath;
    wios_runtime_config config = {
        .struct_size = sizeof(wios_runtime_config),
        .container_root_utf8 = bundleRoot.fileSystemRepresentation,
        .log_callback = WIOSRuntimeLogCallback,
        .log_context = NULL
    };

    int result = api->initialize(&config);
    if (result == 0)
    {
        [[WIOSLog shared] appendLevel:@"INFO"
                                  key:@"WINE_RUNTIME"
                                value:@"HOST_RUNTIME_INITIALIZE=PASS"];
    }
    else
    {
        const char *error = api->last_error ? api->last_error() : "";
        NSString *message = error && error[0]
            ? [NSString stringWithUTF8String:error]
            : @"unknown runtime error";
        [[WIOSLog shared] appendLevel:@"ERROR"
                                  key:@"WINE_RUNTIME"
                                value:[NSString stringWithFormat:
                                    @"HOST_RUNTIME_INITIALIZE=FAIL rc=%d error=%@",
                                    result, message]];
    }

    [self refreshLog];
}

- (void)shareLog
{
    UIActivityViewController *controller = [[UIActivityViewController alloc]
        initWithActivityItems:@[[WIOSLog shared].fileURL]
        applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.view;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)refreshLog
{
    self.textView.text = [[WIOSLog shared] contents];
    if (self.textView.text.length) {
        [self.textView scrollRangeToVisible:
            NSMakeRange(self.textView.text.length - 1, 1)];
    }
}

@end
