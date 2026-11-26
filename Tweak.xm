#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ReplayKit/ReplayKit.h>
#import <CallKit/CallKit.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>

// Experimental. CallKit suppression is OFF by default because it can break
// Google Meet's signaling, UI state, and audio activation.
#ifndef MLR_EXPERIMENTAL_CALLKIT_SUPPRESS
#define MLR_EXPERIMENTAL_CALLKIT_SUPPRESS 0
#endif

// A session-mode rewrite may remove echo cancellation and break WebRTC input.
#ifndef MLR_FORCE_DEFAULT_AUDIO
#define MLR_FORCE_DEFAULT_AUDIO 0
#endif

#if MLR_FORCE_DEFAULT_AUDIO
static BOOL MLRIsChatMode(AVAudioSessionMode mode) {
    return [mode isEqualToString:AVAudioSessionModeVoiceChat] ||
           [mode isEqualToString:AVAudioSessionModeVideoChat];
}

static AVAudioSessionCategoryOptions MLRAudioOptions(void) {
    return AVAudioSessionCategoryOptionMixWithOthers |
           AVAudioSessionCategoryOptionDefaultToSpeaker;
}
#endif

%hook AVAudioSession

- (BOOL)setMode:(AVAudioSessionMode)mode error:(NSError **)error {
#if MLR_FORCE_DEFAULT_AUDIO
    if (MLRIsChatMode(mode)) {
        return [self setCategory:AVAudioSessionCategoryPlayAndRecord
                           mode:AVAudioSessionModeDefault
                        options:MLRAudioOptions()
                          error:error];
    }
#endif
    return %orig(mode, error);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
              mode:(AVAudioSessionMode)mode
           options:(AVAudioSessionCategoryOptions)options
             error:(NSError **)error {
#if MLR_FORCE_DEFAULT_AUDIO
    if (MLRIsChatMode(mode)) {
        return %orig(AVAudioSessionCategoryPlayAndRecord,
                     AVAudioSessionModeDefault,
                     options | MLRAudioOptions(),
                     error);
    }
#endif
    return %orig(category, mode, options, error);
}

%end

%hook CXProvider

- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID
                               update:(CXCallUpdate *)update
                           completion:(void (^)(NSError *))completion {
#if MLR_EXPERIMENTAL_CALLKIT_SUPPRESS
    NSLog(@"[MeetLocalRecorder] Suppressing incoming CallKit report (experimental)");
    if (completion) completion(nil);
#else
    %orig(UUID, update, completion);
#endif
}

- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID
          startedConnectingAtDate:(NSDate *)date {
#if MLR_EXPERIMENTAL_CALLKIT_SUPPRESS
    NSLog(@"[MeetLocalRecorder] Suppressing outgoing connecting report (experimental)");
#else
    %orig(UUID, date);
#endif
}

- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID
                 connectedAtDate:(NSDate *)date {
#if MLR_EXPERIMENTAL_CALLKIT_SUPPRESS
    NSLog(@"[MeetLocalRecorder] Suppressing outgoing connected report (experimental)");
#else
    %orig(UUID, date);
#endif
}

%end

typedef NS_ENUM(NSInteger, MLRRecordingState) {
    MLRRecordingStateIdle = 0,
    MLRRecordingStateStarting,
    MLRRecordingStateRecording,
    MLRRecordingStateStopping,
    MLRRecordingStateSaving,
};

static UIWindow *MLRKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

@interface MLRController : NSObject <RPScreenRecorderDelegate>
@property(nonatomic, strong) UIButton *pill;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic, assign) MLRRecordingState state;
@property(nonatomic, strong) NSURL *pendingURL;
+ (instancetype)shared;
- (void)bootstrap;
- (void)attachPill;
- (void)startRecording;
- (void)stopRecording;
- (void)saveToPhotos:(NSURL *)url;
- (void)finishPhotoAuthorization:(PHAuthorizationStatus)status fileURL:(NSURL *)url;
@end

@implementation MLRController

+ (instancetype)shared {
    static MLRController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)bootstrap {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(attachPill)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(attachPill)
               name:UIWindowDidBecomeKeyNotification object:nil];
    [nc addObserver:self selector:@selector(attachPill)
               name:UIDeviceOrientationDidChangeNotification object:nil];
    [self attachPill];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self attachPill]; });
}

- (void)attachPill {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self attachPill]; });
        return;
    }
    UIWindow *window = MLRKeyWindow();
    if (!window) return;
    if (!self.pill) {
        UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
        pill.frame = CGRectMake(0, 0, 82, 42);
        pill.layer.cornerRadius = 21;
        pill.layer.masksToBounds = YES;
        pill.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        pill.accessibilityLabel = @"Start meeting recording";
        [pill addTarget:self action:@selector(toggleRecording)
                 forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                      initWithTarget:self action:@selector(dragPill:)];
        [pill addGestureRecognizer:pan];
        self.pill = pill;
        [self refreshPill];
    }
    if (self.pill.superview != window) {
        [self.pill removeFromSuperview];
        [window addSubview:self.pill];
        self.hostWindow = window;
        UIEdgeInsets insets = window.safeAreaInsets;
        self.pill.center = CGPointMake(CGRectGetWidth(window.bounds) - 52,
                                      insets.top + 36);
    } else {
        [window bringSubviewToFront:self.pill];
    }
    [self clampPill];
}

- (void)clampPill {
    UIWindow *window = self.hostWindow;
    if (!window || !self.pill) return;
    CGSize size = window.bounds.size;
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat halfW = CGRectGetWidth(self.pill.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.pill.bounds) / 2.0;
    CGFloat left = insets.left + halfW + 4.0;
    CGFloat right = MAX(left, size.width - insets.right - halfW - 4.0);
    CGFloat top = insets.top + halfH + 4.0;
    CGFloat bottom = MAX(top, size.height - insets.bottom - halfH - 4.0);
    CGPoint c = self.pill.center;
    c.x = MIN(MAX(c.x, left), right);
    c.y = MIN(MAX(c.y, top), bottom);
    self.pill.center = c;
}

- (void)dragPill:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view.superview) return;
    CGPoint delta = [gesture translationInView:view.superview];
    view.center = CGPointMake(view.center.x + delta.x, view.center.y + delta.y);
    [gesture setTranslation:CGPointZero inView:view.superview];
    [self clampPill];
}

- (void)refreshPill {
    NSString *title = @"REC";
    UIColor *background = [UIColor systemRedColor];
    BOOL enabled = YES;
    NSString *accessibility = @"Start meeting recording";
    switch (self.state) {
        case MLRRecordingStateStarting:
            title = @"START…"; enabled = NO; break;
        case MLRRecordingStateRecording:
            title = @"STOP"; accessibility = @"Stop and save meeting recording"; break;
        case MLRRecordingStateStopping:
            title = @"STOP…"; enabled = NO; break;
        case MLRRecordingStateSaving:
            title = @"SAVE…"; enabled = NO; break;
        default: break;
    }
    if (!enabled) background = [UIColor systemGrayColor];
    [self.pill setTitle:title forState:UIControlStateNormal];
    self.pill.backgroundColor = background;
    self.pill.enabled = enabled;
    self.pill.accessibilityLabel = accessibility;
}

- (void)setRecorderState:(MLRRecordingState)newState {
    self.state = newState;
    [self refreshPill];
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = MLRKeyWindow().rootViewController;
        if (!root) {
            NSLog(@"[MeetLocalRecorder] %@: %@", title, message);
            return;
        }
        while (root.presentedViewController) root = root.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}

- (void)toggleRecording {
    switch (self.state) {
        case MLRRecordingStateIdle: [self startRecording]; break;
        case MLRRecordingStateRecording: [self stopRecording]; break;
        default: break;
    }
}

- (void)startRecording {
    __weak id weakSelf = self;
    RPScreenRecorder *recorder = RPScreenRecorder.sharedRecorder;
    if (!recorder.isAvailable || recorder.isRecording) {
        MLRController *strongSelf = weakSelf;
        [strongSelf showMessage:@"Recording unavailable"
            message:@"ReplayKit is busy or unavailable for this app/session."];
        return;
    }
    recorder.delegate = self;
    recorder.microphoneEnabled = YES;
    MLRController *strongSelf = weakSelf;
    [strongSelf setRecorderState:MLRRecordingStateStarting];
    [recorder startRecordingWithHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MLRController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf setRecorderState:MLRRecordingStateIdle];
                [strongSelf showMessage:@"Cannot start recording"
                              message:error.localizedDescription ?: @"Unknown ReplayKit error"];
            } else {
                [strongSelf setRecorderState:MLRRecordingStateRecording];
            }
        });
    }];
}

- (void)stopRecording {
    __weak id weakSelf = self;
    MLRController *strongSelf = weakSelf;
    if (!strongSelf) return;
    if (strongSelf.state != MLRRecordingStateRecording) return;
    [strongSelf setRecorderState:MLRRecordingStateStopping];
    NSString *fileName = [NSString stringWithFormat:@"Meet-%@.mp4",
                          NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                       stringByAppendingPathComponent:fileName]];
    strongSelf.pendingURL = url;
    [RPScreenRecorder.sharedRecorder stopRecordingWithOutputURL:url
        completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MLRController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf setRecorderState:MLRRecordingStateIdle];
                [strongSelf showMessage:@"Cannot finish recording"
                          message:error.localizedDescription ?: @"Unknown ReplayKit error"];
                return;
            }
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
            NSNumber *fileSize = attrs[NSFileSize];
            if (fileSize == nil || fileSize.unsignedLongLongValue == 0) {
                [strongSelf setRecorderState:MLRRecordingStateIdle];
                [strongSelf showMessage:@"Empty recording"
                          message:@"ReplayKit did not produce a playable file."];
                return;
            }
            [strongSelf setRecorderState:MLRRecordingStateSaving];
            [strongSelf saveToPhotos:url];
        });
    }];
}

- (void)saveToPhotos:(NSURL *)url {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    __weak id weakSelf = self;
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
            handler:^(PHAuthorizationStatus result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MLRController *strongSelf = weakSelf;
                if (strongSelf) [strongSelf finishPhotoAuthorization:result fileURL:url];
            });
        }];
    } else {
        MLRController *strongSelf = weakSelf;
        [strongSelf finishPhotoAuthorization:status fileURL:url];
    }
}

- (void)finishPhotoAuthorization:(PHAuthorizationStatus)status fileURL:(NSURL *)url {
    __weak id weakSelf = self;
    MLRController *strongSelf = weakSelf;
    if (!strongSelf) return;
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
        [strongSelf setRecorderState:MLRRecordingStateIdle];
        [strongSelf showMessage:@"Photos permission required"
                  message:[NSString stringWithFormat:
                  @"Allow Add Photos permission in Settings. Recording retained temporarily at %@", url.path]];
        return;
    }
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MLRController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success) {
                NSError *cleanupError = nil;
                [NSFileManager.defaultManager removeItemAtURL:url error:&cleanupError];
                if (cleanupError) NSLog(@"[MeetLocalRecorder] temp cleanup: %@", cleanupError);
                strongSelf.pendingURL = nil;
                [strongSelf showMessage:@"Saved to Photos"
                    message:@"ReplayKit video saved. Verify whether remote audio is present; it is not guaranteed."];
            } else {
                [strongSelf showMessage:@"Failed to save to Photos"
                    message:[NSString stringWithFormat:@"%@\nThe temporary recording remains at %@",
                        error.localizedDescription ?: @"Unknown Photos error", url.path]];
            }
            [strongSelf setRecorderState:MLRRecordingStateIdle];
        });
    }];
}

- (void)screenRecorder:(RPScreenRecorder *)screenRecorder
    didStopRecordingWithError:(NSError *)error
       previewViewController:(RPPreviewViewController *)previewViewController {
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MLRController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.state == MLRRecordingStateSaving) return;
        [strongSelf setRecorderState:MLRRecordingStateIdle];
        [strongSelf showMessage:@"Recording interrupted"
                  message:error.localizedDescription ?: @"ReplayKit stopped unexpectedly."];
    });
}

@end

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MLRController shared] bootstrap];
        });
    }
}
