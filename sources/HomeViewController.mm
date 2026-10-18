#import "HomeViewController.h"
#import "HUDHelper.h"
#import "../esp/Core/pid.h"
#import "roothide/varCleanController.h"
#import "AntibanCleaner.h"
#include "API/APIClient.h"
#include "oxorany/oxorany.h"

#import <QuartzCore/QuartzCore.h>

// ========== THÊM MỚI: Thời gian tự động thoát ==========
static const CFTimeInterval kAutoExitTimeout = 30.0; // 30 giây
// ========================================================

@interface HomeViewController ()

@property (nonatomic, strong) UIScrollView *pageScrollView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *brandMark;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIView *gameCard;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *brandLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subTitleLabel;
@property (nonatomic, strong) UILabel *hudLabel;
@property (nonatomic, strong) UILabel *hudStatusLabel;
@property (nonatomic, strong) UILabel *gameNameLabel;
@property (nonatomic, strong) UILabel *gameStatusLabel;
@property (nonatomic, strong) UIView *gameStatusDot;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *autoCleanLabel;
@property (nonatomic, strong) UILabel *autoCleanDescription;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UISwitch *hudSwitch;
@property (nonatomic, strong) UISwitch *autoCleanSwitch;
@property (nonatomic, strong) UIButton *telegramButton;
@property (nonatomic, strong) CAGradientLayer *backgroundGradient;
@property (nonatomic, strong) NSTimer *pollTimer;

// ========== THÊM MỚI: Properties cho auto exit ==========
@property (nonatomic, strong) NSTimer  *autoExitTimer;
// ========================================================

@property (nonatomic, assign) BOOL      lastGameRunning;
@property (nonatomic, assign) NSInteger gameMissingStreak;
@property (nonatomic, assign) CFTimeInterval pendingHUDEnableUntil;

@end

@implementation HomeViewController

#pragma mark - Integrity Check Info.plist

- (void)checkInfoPlistIntegrity {
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    
    // Sử dụng chuỗi gốc trực tiếp không qua mã hóa server key
    NSString *displayName = infoDict[@"CFBundleDisplayName"];
    NSString *versionString = infoDict[@"CFBundleVersion"];
    NSString *bundleID = infoDict[@"CFBundleIdentifier"];
    
    NSString *originalName = @"FF EXTERNAL";
    NSString *originalBundleID = @"ext.ff";
    NSString *originalVersion = @"1.20.1";
    
    if (![displayName isEqualToString:originalName] ||
        ![bundleID isEqualToString:originalBundleID] ||
        ![versionString isEqualToString:originalVersion]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BUILD INTEGRITY"
                                                                           message:@"Application metadata has changed. This app will close."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *exitAction = [UIAlertAction actionWithTitle:@"Close"
                                                                 style:UIAlertActionStyleDestructive 
                                                               handler:^(UIAlertAction * action) {
                exit(0);
            }];
            
            [alert addAction:exitAction];
            
            UIViewController *top = [self topPresentedViewController];
            [top presentViewController:alert animated:YES completion:nil];
        });
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }
}

// ========== THÊM MỚI: Method tự động thoát ==========
- (void)autoExitApp {
    NSLog(@"⏰ [AutoExit] Đã %d giây - Tự động đóng app", (int)kAutoExitTimeout);
    SetHUDEnabled(NO);
    exit(0);
}
// =====================================================

#pragma mark - Lifecycle

- (void)viewDidLoad {

apiclient_set_token(oxorany("wZ3Q/xYPjTIWo5gRdA5jLXRDg7hkxxY4ZQlWdtF1uamNi0nwolEDstMEOrlEsxHyiUUj4M/7hRwYD6VApIf9c3kkgQYy6dWE/B69+eT5F0g="));
        apiclient_set_language(oxorany("en"));
        apiclient_set_contact_button_title(oxorany("Telegram: @FFEXTERNALMOD"));
        apiclient_set_description(oxorany("FF EXTERNAL support and community: @FFEXTERNALMOD."));
        
        // TẮT TÍNH NĂNG ẨN UI ĐỂ CHO PHÉP QUAY/CHỤP MÀN HÌNH BẢNG LOGIN VÀ POPUP LỖI
        apiclient_hide_ui(false);      // Đổi thành false để hiện UI khi chụp/quay màn hình, phục vụ hỗ trợ khách hàng
        
        apiclient_strict_mode(true);   // Bật bảo mật thắt chặt chống bypass bộ nhớ
        apiclient_silent_mode(false);  // Để false để bung popup thông báo khi có lỗi phát sinh (Hết hạn, sai HWID...)
        apiclient_set_window_mode(1);  // Chế độ cửa sổ chuẩn của Server

        // Bọc phần khởi tạo menu vào hàm kiểm tra key đã mua của server
        apiclient_paid(^{

    [super viewDidLoad];
    
    // Quét kiểm tra tính toàn vẹn hệ thống
    [self checkInfoPlistIntegrity];
    
    UIColor *backgroundTop = [UIColor colorWithRed:0.035f green:0.047f blue:0.043f alpha:1.0f];
    UIColor *backgroundBottom = [UIColor colorWithRed:0.070f green:0.082f blue:0.073f alpha:1.0f];
    UIColor *cardColor = [UIColor colorWithRed:0.080f green:0.094f blue:0.085f alpha:1.0f];
    UIColor *accent = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:1.0f];
    UIColor *muted = [UIColor colorWithRed:0.59f green:0.63f blue:0.59f alpha:1.0f];

    self.view.backgroundColor = backgroundTop;
    self.view.tintColor = accent;
    _backgroundGradient = [CAGradientLayer layer];
    _backgroundGradient.colors = @[(__bridge id)backgroundTop.CGColor, (__bridge id)backgroundBottom.CGColor];
    _backgroundGradient.startPoint = CGPointMake(0.0f, 0.0f);
    _backgroundGradient.endPoint = CGPointMake(1.0f, 1.0f);
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _pageScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _pageScrollView.backgroundColor = [UIColor clearColor];
    _pageScrollView.showsVerticalScrollIndicator = NO;
    _pageScrollView.alwaysBounceVertical = YES;
    _pageScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_pageScrollView];

    _contentView = [[UIView alloc] initWithFrame:CGRectZero];
    _contentView.backgroundColor = [UIColor clearColor];
    [_pageScrollView addSubview:_contentView];

    _brandMark = [[UIView alloc] initWithFrame:CGRectZero];
    _brandMark.backgroundColor = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:0.09f];
    _brandMark.layer.cornerRadius = 12.0f;
    _brandMark.layer.borderWidth = 1.0f;
    _brandMark.layer.borderColor = [accent colorWithAlphaComponent:0.34f].CGColor;
    [_contentView addSubview:_brandMark];

    UILabel *markLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    markLabel.text = @"FF";
    markLabel.textAlignment = NSTextAlignmentCenter;
    markLabel.textColor = accent;
    markLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightBlack];
    markLabel.tag = 1001;
    [_brandMark addSubview:markLabel];

    _brandLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _brandLabel.text = @"FF EXTERNAL";
    _brandLabel.textColor = [UIColor colorWithWhite:0.96f alpha:1.0f];
    _brandLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightBlack];
    [_contentView addSubview:_brandLabel];

    UILabel *suiteLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    suiteLabel.text = @"CONTROL SUITE";
    suiteLabel.textColor = muted;
    suiteLabel.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightMedium];
    suiteLabel.tag = 1002;
    [_contentView addSubview:suiteLabel];

    _versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionLabel.text = @"GAME  1.132.1";
    _versionLabel.textAlignment = NSTextAlignmentCenter;
    _versionLabel.textColor = accent;
    _versionLabel.font = [UIFont monospacedSystemFontOfSize:9.0f weight:UIFontWeightSemibold];
    _versionLabel.backgroundColor = [accent colorWithAlphaComponent:0.09f];
    _versionLabel.layer.cornerRadius = 11.0f;
    _versionLabel.layer.borderWidth = 1.0f;
    _versionLabel.layer.borderColor = [accent colorWithAlphaComponent:0.18f].CGColor;
    _versionLabel.clipsToBounds = YES;
    [_contentView addSubview:_versionLabel];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"SESSION\nCONTROL";
    _titleLabel.numberOfLines = 2;
    _titleLabel.textColor = [UIColor colorWithWhite:0.97f alpha:1.0f];
    _titleLabel.font = [UIFont systemFontOfSize:34.0f weight:UIFontWeightBlack];
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.82f;
    [_contentView addSubview:_titleLabel];

    _subTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subTitleLabel.text = @"A considered control surface for your game session.";
    _subTitleLabel.textColor = muted;
    _subTitleLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightRegular];
    _subTitleLabel.numberOfLines = 2;
    [_contentView addSubview:_subTitleLabel];

    _gameCard = [[UIView alloc] initWithFrame:CGRectZero];
    _gameCard.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.025f];
    _gameCard.layer.cornerRadius = 15.0f;
    _gameCard.layer.borderWidth = 1.0f;
    _gameCard.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.075f].CGColor;
    [_contentView addSubview:_gameCard];

    _gameStatusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _gameStatusDot.backgroundColor = muted;
    _gameStatusDot.layer.cornerRadius = 4.0f;
    [_gameCard addSubview:_gameStatusDot];

    _gameNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _gameNameLabel.text = @"FREE FIRE";
    _gameNameLabel.textColor = [UIColor colorWithWhite:0.96f alpha:1.0f];
    _gameNameLabel.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
    [_gameCard addSubview:_gameNameLabel];

    _gameStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _gameStatusLabel.text = @"WAITING FOR GAME";
    _gameStatusLabel.textColor = muted;
    _gameStatusLabel.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightMedium];
    _gameStatusLabel.textAlignment = NSTextAlignmentRight;
    _gameStatusLabel.adjustsFontSizeToFitWidth = YES;
    _gameStatusLabel.minimumScaleFactor = 0.75f;
    [_gameCard addSubview:_gameStatusLabel];

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.backgroundColor = cardColor;
    _cardView.layer.cornerRadius = 22.0f;
    _cardView.layer.borderWidth = 1.0f;
    _cardView.layer.borderColor = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:0.22f].CGColor;
    _cardView.clipsToBounds = YES;
    [_contentView addSubview:_cardView];

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectZero];
    accentBar.backgroundColor = accent;
    accentBar.tag = 1003;
    [_cardView addSubview:accentBar];

    UILabel *sectionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionLabel.text = @"01   /   OVERLAY CONTROL";
    sectionLabel.textColor = accent;
    sectionLabel.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightSemibold];
    sectionLabel.tag = 1004;
    [_cardView addSubview:sectionLabel];

    _hudLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hudLabel.text = @"Floating HUD";
    _hudLabel.textColor = [UIColor colorWithWhite:0.97f alpha:1.0f];
    _hudLabel.font = [UIFont systemFontOfSize:20.0f weight:UIFontWeightBold];
    [_cardView addSubview:_hudLabel];

    _hudStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hudStatusLabel.text = @"STANDBY";
    _hudStatusLabel.textColor = muted;
    _hudStatusLabel.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightSemibold];
    [_cardView addSubview:_hudStatusLabel];

    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.backgroundColor = muted;
    _statusDot.layer.cornerRadius = 3.5f;
    [_cardView addSubview:_statusDot];

    _hudSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _hudSwitch.onTintColor = [UIColor colorWithRed:0.47f green:0.64f blue:0.49f alpha:1.0f];
    _hudSwitch.thumbTintColor = [UIColor colorWithWhite:0.97f alpha:1.0f];
    [_hudSwitch addTarget:self action:@selector(hudSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_cardView addSubview:_hudSwitch];

    _descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _descLabel.text = @"A compact, touch-ready overlay with live visual controls.";
    _descLabel.textColor = [UIColor colorWithWhite:0.68f alpha:1.0f];
    _descLabel.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightRegular];
    _descLabel.numberOfLines = 2;
    [_cardView addSubview:_descLabel];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.08f];
    divider.tag = 999;
    [_cardView addSubview:divider];

    _autoCleanLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _autoCleanLabel.text = @"Pre-launch cleanup";
    _autoCleanLabel.textColor = [UIColor colorWithWhite:0.93f alpha:1.0f];
    _autoCleanLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightSemibold];
    [_cardView addSubview:_autoCleanLabel];

    _autoCleanDescription = [[UILabel alloc] initWithFrame:CGRectZero];
    _autoCleanDescription.text = @"Run VarClean before enabling the HUD";
    _autoCleanDescription.textColor = muted;
    _autoCleanDescription.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightRegular];
    _autoCleanDescription.adjustsFontSizeToFitWidth = YES;
    _autoCleanDescription.minimumScaleFactor = 0.8f;
    [_cardView addSubview:_autoCleanDescription];

    _autoCleanSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _autoCleanSwitch.onTintColor = [UIColor colorWithRed:0.47f green:0.64f blue:0.49f alpha:1.0f];
    _autoCleanSwitch.thumbTintColor = [UIColor colorWithWhite:0.97f alpha:1.0f];
    _autoCleanSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"AutoVarCleanBeforeHUD"];
    [_autoCleanSwitch addTarget:self action:@selector(autoCleanSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_cardView addSubview:_autoCleanSwitch];

    _telegramButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _telegramButton.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.035f];
    _telegramButton.layer.cornerRadius = 16.0f;
    _telegramButton.layer.borderWidth = 1.0f;
    _telegramButton.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.085f].CGColor;
    [_telegramButton addTarget:self action:@selector(openTelegramGroup) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:_telegramButton];

    UILabel *telegramKicker = [[UILabel alloc] initWithFrame:CGRectZero];
    telegramKicker.text = @"OFFICIAL TELEGRAM GROUP";
    telegramKicker.textColor = muted;
    telegramKicker.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightMedium];
    telegramKicker.tag = 1005;
    [_telegramButton addSubview:telegramKicker];

    UILabel *telegramTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    telegramTitle.text = @"@FFEXTERNALMOD";
    telegramTitle.textColor = [UIColor colorWithWhite:0.96f alpha:1.0f];
    telegramTitle.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightSemibold];
    telegramTitle.tag = 1006;
    [_telegramButton addSubview:telegramTitle];

    UIImageView *telegramArrow = [[UIImageView alloc] initWithFrame:CGRectZero];
    telegramArrow.image = [UIImage systemImageNamed:@"arrow.up.right"];
    telegramArrow.tintColor = accent;
    telegramArrow.contentMode = UIViewContentModeScaleAspectFit;
    telegramArrow.tag = 1007;
    [_telegramButton addSubview:telegramArrow];

    _footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footerLabel.text = @"FF EXTERNAL     •     GAME 1.132.1";
    _footerLabel.textAlignment = NSTextAlignmentCenter;
    _footerLabel.textColor = [UIColor colorWithWhite:0.43f alpha:1.0f];
    _footerLabel.font = [UIFont monospacedSystemFontOfSize:8.0f weight:UIFontWeightMedium];
    [_contentView addSubview:_footerLabel];

    // Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appBecameActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillTerminate)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    _gameMissingStreak     = 0;
    _pendingHUDEnableUntil = 0;

    // ========== THÊM MỚI: Khởi động timer 30s tự thoát ==========
    [self startAutoExitTimer];
    // ============================================================

    [self startPollingGameState];
    [self refreshHUDState];

  });
}

// ========== THÊM MỚI: Start / Stop auto exit timer ==========
- (void)startAutoExitTimer {
    [self stopAutoExitTimer]; // Hủy timer cũ nếu có
    
    _autoExitTimer = [NSTimer scheduledTimerWithTimeInterval:kAutoExitTimeout
                                                      target:self
                                                    selector:@selector(autoExitApp)
                                                    userInfo:nil
                                                     repeats:NO];
    NSLog(@"⏰ [AutoExit] Timer khởi động - App sẽ tự đóng sau %d giây", (int)kAutoExitTimeout);
}

- (void)stopAutoExitTimer {
    if (_autoExitTimer) {
        [_autoExitTimer invalidate];
        _autoExitTimer = nil;
    }
}
// ==============================================================


#pragma mark - App Lifecycle

- (void)appWillTerminate {
    SetHUDEnabled(NO);
}

- (void)openTelegramGroup {
    NSURL *url = [NSURL URLWithString:@"https://t.me/FFEXTERNALMOD"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)appDidEnterBackground {
    if (![self isGameRunning]) {
        SetHUDEnabled(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.hudSwitch.on) [self.hudSwitch setOn:NO animated:NO];
        });
    }
}

- (void)appBecameActive {
    [self checkInfoPlistIntegrity];
    
    // ========== THÊM MỚI: Reset timer khi app active trở lại ==========
    [self startAutoExitTimer];
    // ==================================================================
    
    [self refreshHUDState];
}

#pragma mark - Top VC Helper

- (UIViewController *)topPresentedViewController {
    UIViewController *vc = self;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;

    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat viewWidth = CGRectGetWidth(self.view.bounds);
    CGFloat viewHeight = CGRectGetHeight(self.view.bounds);
    CGFloat viewportHeight = MAX(0.0f, viewHeight - insets.top - insets.bottom);
    _pageScrollView.frame = CGRectMake(0, insets.top, viewWidth, viewportHeight);

    CGFloat contentWidth = MIN(MAX(0.0f, viewWidth - 40.0f), 560.0f);
    CGFloat contentHeight = 666.0f;
    CGFloat contentX = (viewWidth - contentWidth) * 0.5f;
    _contentView.frame = CGRectMake(contentX, 0, contentWidth, contentHeight);
    _pageScrollView.contentSize = CGSizeMake(viewWidth, contentHeight);

    _brandMark.frame = CGRectMake(0, 14, 38, 38);
    ((UILabel *)[_brandMark viewWithTag:1001]).frame = _brandMark.bounds;
    _brandLabel.frame = CGRectMake(50, 16, contentWidth - 150, 17);
    ((UILabel *)[_contentView viewWithTag:1002]).frame = CGRectMake(50, 33, contentWidth - 150, 13);
    _versionLabel.frame = CGRectMake(contentWidth - 100, 20, 100, 27);

    _titleLabel.frame = CGRectMake(0, 70, contentWidth, 78);
    _subTitleLabel.frame = CGRectMake(2, 153, contentWidth - 4, 34);

    _gameCard.frame = CGRectMake(0, 202, contentWidth, 60);
    _gameStatusDot.frame = CGRectMake(17, 27, 7, 7);
    _gameNameLabel.frame = CGRectMake(34, 0, contentWidth * 0.40f, 60);
    _gameStatusLabel.frame = CGRectMake(contentWidth * 0.43f, 0, contentWidth * 0.57f - 16, 60);

    _cardView.frame = CGRectMake(0, 278, contentWidth, 244);
    ((UIView *)[_cardView viewWithTag:1003]).frame = CGRectMake(18, 0, 34, 2);
    ((UILabel *)[_cardView viewWithTag:1004]).frame = CGRectMake(18, 15, contentWidth - 36, 14);
    _hudLabel.frame = CGRectMake(18, 41, contentWidth - 108, 28);
    _statusDot.frame = CGRectMake(20, 80, 7, 7);
    _hudStatusLabel.frame = CGRectMake(34, 74, contentWidth - 130, 18);
    CGSize hudSwitchSize = _hudSwitch.intrinsicContentSize;
    _hudSwitch.frame = CGRectMake(contentWidth - hudSwitchSize.width - 18, 43, hudSwitchSize.width, hudSwitchSize.height);
    _descLabel.frame = CGRectMake(18, 105, contentWidth - 36, 36);
    [_cardView viewWithTag:999].frame = CGRectMake(18, 153, contentWidth - 36, 1);
    _autoCleanLabel.frame = CGRectMake(18, 166, contentWidth - 100, 18);
    _autoCleanDescription.frame = CGRectMake(18, 188, contentWidth - 100, 16);
    CGSize cleanSwitchSize = _autoCleanSwitch.intrinsicContentSize;
    _autoCleanSwitch.frame = CGRectMake(contentWidth - cleanSwitchSize.width - 18, 171, cleanSwitchSize.width, cleanSwitchSize.height);

    _telegramButton.frame = CGRectMake(0, 540, contentWidth, 68);
    ((UILabel *)[_telegramButton viewWithTag:1005]).frame = CGRectMake(17, 13, contentWidth - 70, 13);
    ((UILabel *)[_telegramButton viewWithTag:1006]).frame = CGRectMake(17, 31, contentWidth - 70, 21);
    ((UIImageView *)[_telegramButton viewWithTag:1007]).frame = CGRectMake(contentWidth - 39, 25, 16, 16);
    _footerLabel.frame = CGRectMake(0, 627, contentWidth, 18);
}

#pragma mark - Dealloc

- (void)dealloc {
    SetHUDEnabled(NO);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_pollTimer invalidate]; _pollTimer = nil;
    [self stopAutoExitTimer]; // ========== THÊM MỚI ==========
}

#pragma mark - Game State

- (BOOL)isGameRunning {
    return GetGameProcesspid((char *)"FreeFire") != -1;
}

- (void)startPollingGameState {
    __weak __typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf refreshHUDState];
    }];
}

#pragma mark - Actions

- (void)autoCleanSwitchChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"AutoVarCleanBeforeHUD"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)hudSwitchChanged:(UISwitch *)sw {
    if (sw.on) {
        if (![self isGameRunning]) {
            [sw setOn:NO animated:YES];
            UIAlertController *a =
                [UIAlertController alertControllerWithTitle:@"GAME NOT RUNNING"
                                                    message:@"Open Free Fire, then return here to enable the HUD."
                                             preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }

        BOOL autoClean = [[NSUserDefaults standardUserDefaults] boolForKey:@"AutoVarCleanBeforeHUD"];
        _pendingHUDEnableUntil = CACurrentMediaTime() + 2.5;

        [UIView animateWithDuration:0.18
                         animations:^{ sw.transform = CGAffineTransformMakeScale(1.15, 1.15); }
                         completion:^(BOOL f) {
            [UIView animateWithDuration:0.18
                             animations:^{ sw.transform = CGAffineTransformIdentity; }];
        }];

        if (autoClean) {
            sw.enabled = NO;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [[varCleanController sharedInstance] runVarCleanNow];
                dispatch_async(dispatch_get_main_queue(), ^{
                    SetHUDEnabled(YES);
                    sw.enabled = YES;
                    [self refreshHUDState];
                });
            });
        } else {
            SetHUDEnabled(YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self refreshHUDState];
            });
        }

    } else {
        _pendingHUDEnableUntil = 0;
        SetHUDEnabled(NO);

        [UIView animateWithDuration:0.18
                         animations:^{ sw.transform = CGAffineTransformMakeScale(1.15, 1.15); }
                         completion:^(BOOL f) {
            [UIView animateWithDuration:0.18
                             animations:^{ sw.transform = CGAffineTransformIdentity; }];
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self refreshHUDState];
        });
    }
}

#pragma mark - Refresh HUD

- (void)refreshHUDState {
    BOOL gameNow = [self isGameRunning];
    BOOL hud     = IsHUDEnabled();

    if (!gameNow) _gameMissingStreak++;
    else          _gameMissingStreak = 0;

    BOOL game = gameNow || (_gameMissingStreak < 3);

    // ── ANTIBAN AUTO-TRIGGER ─────────────────────────────────────────────────
    // _lastGameRunning starts as NO → первый цикл где game detected = startLoop.
    // Когда game пропала (game == NO после grace) = stopLoop.
    if (game && !_lastGameRunning) {
        NSLog(@"[ANTIBAN] Game appeared — starting antiban loop");
        [[AntibanCleaner shared] startLoop];
    } else if (!game && _lastGameRunning) {
        NSLog(@"[ANTIBAN] Game gone — stopping antiban loop");
        [[AntibanCleaner shared] stopLoop];
        // Финальный разовый прогон при выходе из матча
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [[AntibanCleaner shared] cleanOnce];
        });
    }
    _lastGameRunning = game;
    // ─────────────────────────────────────────────────────────────────────────

    UIColor *accent = [UIColor colorWithRed:0.77f green:0.70f blue:0.50f alpha:1.0f];
    UIColor *sage = [UIColor colorWithRed:0.47f green:0.64f blue:0.49f alpha:1.0f];
    UIColor *muted = [UIColor colorWithRed:0.59f green:0.63f blue:0.59f alpha:1.0f];

    if (!game) {
        if (hud) { SetHUDEnabled(NO); hud = NO; }
        _hudSwitch.enabled = NO;
        if (_hudSwitch.on) [_hudSwitch setOn:NO animated:YES];
        _descLabel.alpha = 0.58f;
        _gameStatusLabel.text = @"NOT DETECTED";
        _gameStatusLabel.textColor = muted;
        _gameStatusDot.backgroundColor = muted;
        _hudStatusLabel.text = @"GAME REQUIRED";
        _hudStatusLabel.textColor = muted;
        _statusDot.backgroundColor = muted;
        _pendingHUDEnableUntil = 0;
        return;
    }

    _hudSwitch.enabled = YES;
    _descLabel.alpha = 1.0f;
    _gameStatusLabel.text = @"PROCESS DETECTED";
    _gameStatusLabel.textColor = sage;
    _gameStatusDot.backgroundColor = sage;
    _hudStatusLabel.text = hud ? @"OVERLAY ACTIVE" : @"READY TO ENABLE";
    _hudStatusLabel.textColor = hud ? sage : accent;
    _statusDot.backgroundColor = hud ? sage : accent;

    CFTimeInterval now   = CACurrentMediaTime();
    BOOL inGrace = (_pendingHUDEnableUntil > 0 && now < _pendingHUDEnableUntil);

    if (!hud && inGrace) {
        if (!_hudSwitch.on) [_hudSwitch setOn:YES animated:NO];
        return;
    }

    if (_hudSwitch.on != hud) [_hudSwitch setOn:hud animated:YES];
    if (hud) _pendingHUDEnableUntil = 0;
}

@end