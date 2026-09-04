#import "WIOSAppDelegate.h"
#import "WIOSViewController.h"

@implementation WIOSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[WIOSViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

