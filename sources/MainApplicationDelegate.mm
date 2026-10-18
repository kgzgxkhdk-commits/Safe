#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "HomeViewController.h"
#import "InfoViewController.h"
#import "roothide/varCleanController.h"

#import "HUDHelper.h"

@implementation MainApplicationDelegate {
    HomeViewController *_homeViewController;
}

- (instancetype)init {
    self = [super init];
    if (self) {

    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {

    // FIX WINDOW
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    // ROOT VCs
    _homeViewController = [[HomeViewController alloc] init];
    InfoViewController *infoVC = [[InfoViewController alloc] init];
    varCleanController *varVC = [varCleanController sharedInstance];

    // NAVIGATION
    UINavigationController *homeNav =
    [[UINavigationController alloc] initWithRootViewController:_homeViewController];

    UINavigationController *infoNav =
    [[UINavigationController alloc] initWithRootViewController:infoVC];

    UINavigationController *varNav =
    [[UINavigationController alloc] initWithRootViewController:varVC];

    // NAV BAR
    homeNav.navigationBarHidden = YES;
    infoNav.navigationBarHidden = YES;
    varNav.navigationBarHidden  = NO;

    // IMPORTANT FIX
    homeNav.view.userInteractionEnabled = YES;
    infoNav.view.userInteractionEnabled = YES;
    varNav.view.userInteractionEnabled  = YES;

    // TAB ICONS
    if (@available(iOS 13.0, *)) {

        homeNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"Home"
         image:[UIImage systemImageNamed:@"house.fill"]
         tag:0];

        infoNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"Info"
         image:[UIImage systemImageNamed:@"info.circle.fill"]
         tag:1];

        varNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"Cleanup"
         image:[UIImage systemImageNamed:@"eraser.fill"]
         tag:2];

    } else {

        homeNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"Home"
                                      image:nil
                                        tag:0];

        infoNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"Info"
                                      image:nil
                                        tag:1];

        varNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"Cleanup"
                                      image:nil
                                        tag:2];
    }

    // TAB BAR
    UITabBarController *tab = [[UITabBarController alloc] init];

    tab.viewControllers = @[
        homeNav,
        infoNav,
        varNav
    ];

    tab.selectedIndex = 0;

    // FIX TOUCH
    tab.view.userInteractionEnabled = YES;
    tab.tabBar.userInteractionEnabled = YES;

    // STYLE
    UIColor *accent = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:1.0f];
    UIColor *muted = [UIColor colorWithRed:0.59f green:0.63f blue:0.59f alpha:1.0f];
    UIColor *bar = [UIColor colorWithRed:0.035f green:0.047f blue:0.043f alpha:1.0f];
    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = bar;
    appearance.shadowColor = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:0.14f];
    appearance.stackedLayoutAppearance.normal.iconColor = muted;
    appearance.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: muted};
    appearance.stackedLayoutAppearance.selected.iconColor = accent;
    appearance.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: accent};
    tab.tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) tab.tabBar.scrollEdgeAppearance = appearance;
    tab.tabBar.barStyle = UIBarStyleBlack;
    tab.tabBar.translucent = NO;
    tab.tabBar.tintColor = accent;
    tab.tabBar.unselectedItemTintColor = muted;
    tab.tabBar.backgroundColor = bar;

    // ROOT
    self.window.rootViewController = tab;

    // IMPORTANT
    [self.window makeKeyAndVisible];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Đồng bộ dữ liệu lần cuối trước khi refresh
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 2. Chỉ refresh nếu homeViewController tồn tại
        if (self->_homeViewController) {
            [self->_homeViewController refreshHUDState];
        }

        self.window.userInteractionEnabled = YES;
    });
}

@end