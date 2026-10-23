#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>

static NSString *const kFloatOnTopDefaultsKey = @"FloatOnTop";
static NSString *const kWindowAutosaveName = @"LucidMainWindow";

typedef NS_ENUM(NSInteger, LucidState) {
  LucidStateRequestingAccess,
  LucidStateAccessDenied,
  LucidStateWaiting,
  LucidStateConnecting,
  LucidStateStreaming,
};

// Returns true for the screen device of a connected iPad or iPhone
static BOOL isIOSScreenDevice(AVCaptureDevice *device) {
  if (![device hasMediaType:AVMediaTypeMuxed]) {
    return NO;
  }
  // CoreMediaIO reports "iOS Device" as the model of every iOS screen. The name
  // check covers older systems that report a different model.
  return [device.modelID isEqualToString:@"iOS Device"] ||
         [device.localizedName containsString:@"iPad"] ||
         [device.localizedName containsString:@"iPhone"];
}

// Returns the pixel size of the video on the port, or zero if it is not known yet
static CGSize videoSizeForPort(AVCaptureInputPort *port) {
  CMFormatDescriptionRef format = port.formatDescription;
  if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
    return CGSizeZero;
  }
  CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
  return CGSizeMake(dimensions.width, dimensions.height);
}

static CGSize videoSizeForInput(AVCaptureInput *input) {
  for (AVCaptureInputPort *port in input.ports) {
    CGSize size = videoSizeForPort(port);
    if (size.width > 0 && size.height > 0) {
      return size;
    }
  }
  return CGSizeZero;
}

#pragma mark - PreviewView

// A view whose backing layer is the preview layer itself. AppKit then sizes the
// video directly during a resize, with no sublayer layout or implicit animation.
// The preview layer letterboxes the video, so a window that is wider or taller
// than the device shows black bars.
@interface PreviewView : NSView
- (instancetype)initWithFrame:(NSRect)frame session:(AVCaptureSession *)session;
@end

@implementation PreviewView {
  AVCaptureSession *_session;
}

- (instancetype)initWithFrame:(NSRect)frame session:(AVCaptureSession *)session {
  if ((self = [super initWithFrame:frame])) {
    _session = session;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
  }
  return self;
}

- (CALayer *)makeBackingLayer {
  AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
  layer.videoGravity = AVLayerVideoGravityResizeAspect;
  layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  return layer;
}

- (BOOL)isOpaque {
  return YES;
}

// Let the user drag the window from anywhere on the video
- (BOOL)mouseDownCanMoveWindow {
  return YES;
}

@end

#pragma mark - StatusView

// Centered spinner and text that show while there is no video
@interface StatusView : NSView
- (void)showTitle:(NSString *)title detail:(NSString *)detail spinning:(BOOL)spinning;
- (void)hide;
@end

@implementation StatusView {
  NSProgressIndicator *_spinner;
  NSTextField *_titleLabel;
  NSTextField *_detailLabel;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeLarge;
    _spinner.displayedWhenStopped = NO;
    _spinner.indeterminate = YES;

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    _titleLabel.textColor = [NSColor labelColor];
    _titleLabel.alignment = NSTextAlignmentCenter;

    _detailLabel = [NSTextField wrappingLabelWithString:@""];
    _detailLabel.font = [NSFont systemFontOfSize:13];
    _detailLabel.textColor = [NSColor secondaryLabelColor];
    _detailLabel.alignment = NSTextAlignmentCenter;
    _detailLabel.preferredMaxLayoutWidth = 360;
    _detailLabel.selectable = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[ _spinner, _titleLabel, _detailLabel ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    [stack setCustomSpacing:16 afterView:_spinner];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
      [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24],
      [stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:24],
    ]];
  }
  return self;
}

- (void)showTitle:(NSString *)title detail:(NSString *)detail spinning:(BOOL)spinning {
  _titleLabel.stringValue = title;
  _detailLabel.stringValue = detail ?: @"";
  _detailLabel.hidden = detail.length == 0;
  self.hidden = NO;
  // A stopped spinner costs nothing, so stop it whenever it is not visible
  if (spinning) {
    [_spinner startAnimation:nil];
  } else {
    [_spinner stopAnimation:nil];
  }
}

- (void)hide {
  [_spinner stopAnimation:nil];
  self.hidden = YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return YES;
}

@end

#pragma mark - AppDelegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation>
@property (strong) NSWindow *window;
@property (strong) PreviewView *previewView;
@property (strong) StatusView *statusView;

// All session changes run on this serial queue, because AVCaptureSession calls
// such as startRunning block the caller.
@property (strong) AVCaptureSession *session;
@property (strong) dispatch_queue_t sessionQueue;

// The properties below are read and written on the main thread only
@property (nonatomic) LucidState state;
@property (nonatomic) BOOL accessGranted;
@property (strong, nonatomic) AVCaptureDevice *device;
@property (nonatomic) CGSize videoSize;
@property (strong, nonatomic) NSMutableSet<NSString *> *failedDeviceIDs;
@property (copy, nonatomic) NSString *failureMessage;
@end

@implementation AppDelegate

#pragma mark Menu

static NSMenuItem *addMenuItem(NSMenu *menu, NSString *title, SEL action, NSString *key,
                               NSEventModifierFlags modifiers) {
  NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
  item.keyEquivalentModifierMask = modifiers;
  return item;
}

static NSMenu *addSubmenu(NSMenu *mainMenu, NSString *title) {
  NSMenuItem *item = [mainMenu addItemWithTitle:title action:NULL keyEquivalent:@""];
  NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
  item.submenu = menu;
  return menu;
}

- (void)buildMainMenu {
  NSString *appName = [[NSProcessInfo processInfo] processName];
  NSEventModifierFlags cmd = NSEventModifierFlagCommand;
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

  NSMenu *appMenu = addSubmenu(mainMenu, appName);
  addMenuItem(appMenu, [@"About " stringByAppendingString:appName],
              @selector(orderFrontStandardAboutPanel:), @"", 0);
  [appMenu addItem:[NSMenuItem separatorItem]];
  addMenuItem(appMenu, [@"Hide " stringByAppendingString:appName], @selector(hide:), @"h", cmd);
  addMenuItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h",
              cmd | NSEventModifierFlagOption);
  addMenuItem(appMenu, @"Show All", @selector(unhideAllApplications:), @"", 0);
  [appMenu addItem:[NSMenuItem separatorItem]];
  addMenuItem(appMenu, [@"Quit " stringByAppendingString:appName], @selector(terminate:), @"q", cmd);

  NSMenu *viewMenu = addSubmenu(mainMenu, @"View");
  addMenuItem(viewMenu, @"Fit Window to Device", @selector(fitWindowToDevice:), @"0", cmd);
  addMenuItem(viewMenu, @"Enter Full Screen", @selector(toggleFullScreen:), @"f",
              cmd | NSEventModifierFlagControl);

  NSMenu *windowMenu = addSubmenu(mainMenu, @"Window");
  addMenuItem(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m", cmd);
  addMenuItem(windowMenu, @"Zoom", @selector(performZoom:), @"", 0);
  [windowMenu addItem:[NSMenuItem separatorItem]];
  addMenuItem(windowMenu, @"Float on Top", @selector(toggleFloatOnTop:), @"t",
              cmd | NSEventModifierFlagOption);
  [windowMenu addItem:[NSMenuItem separatorItem]];
  addMenuItem(windowMenu, @"Close", @selector(performClose:), @"w", cmd);
  [windowMenu addItem:[NSMenuItem separatorItem]];
  addMenuItem(windowMenu, @"Bring All to Front", @selector(arrangeInFront:), @"", 0);

  NSApp.mainMenu = mainMenu;
  NSApp.windowsMenu = windowMenu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(fitWindowToDevice:)) {
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    return self.videoSize.width > 0 && !fullScreen;
  }
  if (item.action == @selector(toggleFloatOnTop:)) {
    item.state = self.window.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff;
  }
  return YES;
}

- (IBAction)toggleFloatOnTop:(id)sender {
  BOOL floatOnTop = self.window.level != NSFloatingWindowLevel;
  self.window.level = floatOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
  [[NSUserDefaults standardUserDefaults] setBool:floatOnTop forKey:kFloatOnTopDefaultsKey];
}

// Resizes the window to the aspect ratio of the device, keeping its height and
// center. The window stays inside the visible area of its screen.
- (IBAction)fitWindowToDevice:(id)sender {
  CGSize video = self.videoSize;
  if (video.width <= 0 || video.height <= 0) {
    return;
  }

  NSWindow *window = self.window;
  NSRect frame = window.frame;
  NSRect visible = (window.screen ?: [NSScreen mainScreen]).visibleFrame;

  NSSize size = NSMakeSize(round(frame.size.height * video.width / video.height), frame.size.height);
  CGFloat scale = MIN(1.0, MIN(visible.size.width / size.width, visible.size.height / size.height));
  size = NSMakeSize(floor(size.width * scale), floor(size.height * scale));

  NSRect fitted = NSMakeRect(NSMidX(frame) - size.width / 2, NSMidY(frame) - size.height / 2,
                             size.width, size.height);
  fitted.origin.x = MAX(NSMinX(visible), MIN(fitted.origin.x, NSMaxX(visible) - size.width));
  fitted.origin.y = MAX(NSMinY(visible), MIN(fitted.origin.y, NSMaxY(visible) - size.height));
  [window setFrame:fitted display:YES animate:YES];
}

#pragma mark Window

- (void)buildWindow {
  NSRect frame = NSMakeRect(0, 0, 800, 600);
  // No aspect ratio lock and a normal window level, so that window managers
  // such as Rectangle can move and resize the window to any size.
  NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                            NSWindowStyleMaskFullSizeContentView;
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  window.title = [[NSProcessInfo processInfo] processName];
  window.titleVisibility = NSWindowTitleHidden;
  window.titlebarAppearsTransparent = YES;
  window.movableByWindowBackground = YES;
  window.backgroundColor = [NSColor blackColor];
  window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorManaged;
  window.contentMinSize = NSMakeSize(240, 180);
  if ([[NSUserDefaults standardUserDefaults] boolForKey:kFloatOnTopDefaultsKey]) {
    window.level = NSFloatingWindowLevel;
  }

  NSView *content = [[NSView alloc] initWithFrame:frame];
  content.wantsLayer = YES;
  content.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

  self.previewView = [[PreviewView alloc] initWithFrame:content.bounds session:self.session];
  self.previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.previewView.hidden = YES;
  [content addSubview:self.previewView];

  self.statusView = [[StatusView alloc] initWithFrame:content.bounds];
  self.statusView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:self.statusView];

  window.contentView = content;

  // Restore the last frame. On the first run, center the window.
  if (![window setFrameUsingName:kWindowAutosaveName]) {
    [window center];
  }
  window.frameAutosaveName = kWindowAutosaveName;
  self.window = window;
}

- (void)setState:(LucidState)state {
  _state = state;
  [self updateStatus];
}

- (void)updateStatus {
  NSString *name = self.device.localizedName ?: @"device";
  self.previewView.hidden = self.state != LucidStateStreaming;
  self.window.title = self.state == LucidStateStreaming ? name : [[NSProcessInfo processInfo] processName];

  switch (self.state) {
  case LucidStateRequestingAccess:
    [self.statusView showTitle:@"Waiting for camera access"
                        detail:@"Lucid needs camera access to show the screen of an iPad or iPhone."
                      spinning:YES];
    break;
  case LucidStateAccessDenied:
    [self.statusView showTitle:@"Camera access is off"
                        detail:@"Allow Lucid in System Settings > Privacy & Security > Camera. Then open Lucid again."
                      spinning:NO];
    break;
  case LucidStateWaiting:
    [self.statusView showTitle:@"No device found"
                        detail:self.failureMessage ?: @"Connect an iPad or iPhone with a cable. Unlock it and tap Trust if it asks."
                      spinning:YES];
    break;
  case LucidStateConnecting:
    [self.statusView showTitle:[NSString stringWithFormat:@"Connecting to %@…", name]
                        detail:@"Unlock the device if the screen does not appear."
                      spinning:YES];
    break;
  case LucidStateStreaming:
    [self.statusView hide];
    break;
  }
}

#pragma mark Devices

- (NSArray<AVCaptureDevice *> *)connectedScreenDevices {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed];
#pragma clang diagnostic pop
  NSMutableArray<AVCaptureDevice *> *screens = [NSMutableArray array];
  for (AVCaptureDevice *device in devices) {
    if (device.isConnected && isIOSScreenDevice(device)) {
      [screens addObject:device];
    }
  }
  return screens;
}

- (BOOL)isCurrentDevice:(AVCaptureDevice *)device {
  return self.device && [device.uniqueID isEqualToString:self.device.uniqueID];
}

// Attaches the first connected screen that did not fail before. If there is no
// such screen, the app waits for the next connect notification.
- (void)attachFirstAvailableDevice {
  if (self.device || !self.accessGranted) {
    return;
  }
  for (AVCaptureDevice *device in [self connectedScreenDevices]) {
    if (![self.failedDeviceIDs containsObject:device.uniqueID]) {
      [self attachDevice:device];
      return;
    }
  }
  self.state = LucidStateWaiting;
}

- (void)attachDevice:(AVCaptureDevice *)device {
  NSLog(@"Attaching device: %@", device.localizedName);
  self.device = device;
  self.videoSize = CGSizeZero;
  self.state = LucidStateConnecting;

  AVCaptureSession *session = self.session;
  dispatch_async(self.sessionQueue, ^{
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    BOOL added = NO;
    if (input) {
      [session beginConfiguration];
      for (AVCaptureInput *old in session.inputs) {
        [session removeInput:old];
      }
      if ([session canAddInput:input]) {
        [session addInput:input];
        added = YES;
      }
      [session commitConfiguration];
      if (added && !session.isRunning) {
        [session startRunning];
      }
    }
    CGSize size = added ? videoSizeForInput(input) : CGSizeZero;

    dispatch_async(dispatch_get_main_queue(), ^{
      [self didAttachDevice:device added:added videoSize:size error:error];
    });
  });
}

- (void)didAttachDevice:(AVCaptureDevice *)device added:(BOOL)added videoSize:(CGSize)size error:(NSError *)error {
  // The device can disconnect while the session queue works
  if (![self isCurrentDevice:device]) {
    return;
  }

  if (!added) {
    NSLog(@"Failed to attach device %@: %@", device.localizedName, error);
    [self.failedDeviceIDs addObject:device.uniqueID];
    self.failureMessage = [NSString stringWithFormat:@"Lucid could not open %@. Disconnect it and connect it again.",
                                                     device.localizedName];
    self.device = nil;
    [self attachFirstAvailableDevice];
    return;
  }

  NSLog(@"Attached device: %@", device.localizedName);
  self.failureMessage = nil;
  // The video size is often not known yet. The port format notification then
  // reports it when the first frames arrive.
  if (size.width > 0) {
    self.videoSize = size;
    self.state = LucidStateStreaming;
  }
}

- (void)detachCurrentDevice {
  self.device = nil;
  self.videoSize = CGSizeZero;

  AVCaptureSession *session = self.session;
  dispatch_async(self.sessionQueue, ^{
    [session beginConfiguration];
    for (AVCaptureInput *input in session.inputs) {
      [session removeInput:input];
    }
    [session commitConfiguration];
    // Release the capture hardware while no device is attached
    if (session.isRunning) {
      [session stopRunning];
    }
  });
}

#pragma mark Notifications

// Device and port notifications can arrive on any thread
static void onMain(dispatch_block_t block) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

- (void)deviceConnected:(NSNotification *)notification {
  AVCaptureDevice *device = notification.object;
  onMain(^{
    NSLog(@"Device connected: %@", device.localizedName);
    if (isIOSScreenDevice(device)) {
      [self attachFirstAvailableDevice];
    }
  });
}

- (void)deviceDisconnected:(NSNotification *)notification {
  AVCaptureDevice *device = notification.object;
  onMain(^{
    NSLog(@"Device disconnected: %@", device.localizedName);
    // A reconnected device gets a new attempt
    if ([self.failedDeviceIDs containsObject:device.uniqueID]) {
      [self.failedDeviceIDs removeObject:device.uniqueID];
      if (self.failedDeviceIDs.count == 0) {
        self.failureMessage = nil;
        [self updateStatus];
      }
    }
    if ([self isCurrentDevice:device]) {
      [self detachCurrentDevice];
      [self attachFirstAvailableDevice];
    }
  });
}

// Posts when the video format of a port changes, for example when the first
// frames arrive or when the device rotates
- (void)portFormatChanged:(NSNotification *)notification {
  AVCaptureInputPort *port = notification.object;
  AVCaptureInput *input = port.input;
  if (![input isKindOfClass:[AVCaptureDeviceInput class]]) {
    return;
  }
  AVCaptureDevice *device = ((AVCaptureDeviceInput *)input).device;
  CGSize size = videoSizeForPort(port);
  if (size.width <= 0 || size.height <= 0) {
    return;
  }
  onMain(^{
    if (![self isCurrentDevice:device]) {
      return;
    }
    if (!CGSizeEqualToSize(size, self.videoSize)) {
      NSLog(@"Video size of %@: %.0fx%.0f", device.localizedName, size.width, size.height);
      self.videoSize = size;
    }
    if (self.state != LucidStateStreaming) {
      self.state = LucidStateStreaming;
    }
  });
}

- (void)sessionRuntimeError:(NSNotification *)notification {
  NSLog(@"Capture session error: %@", notification.userInfo[AVCaptureSessionErrorKey]);
  // The session stops after a runtime error. Start it again if it has a device.
  AVCaptureSession *session = self.session;
  dispatch_async(self.sessionQueue, ^{
    if (session.inputs.count > 0 && !session.isRunning) {
      [session startRunning];
    }
  });
}

#pragma mark Camera access

- (void)requestCameraAccess {
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
  case AVAuthorizationStatusAuthorized:
    [self cameraAccessGranted:YES];
    break;
  case AVAuthorizationStatusNotDetermined: {
    self.state = LucidStateRequestingAccess;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self cameraAccessGranted:granted];
      });
    }];
    break;
  }
  default:
    [self cameraAccessGranted:NO];
    break;
  }
}

- (void)cameraAccessGranted:(BOOL)granted {
  self.accessGranted = granted;
  if (!granted) {
    NSLog(@"Camera access denied. Allow it in System Settings > Privacy & Security > Camera.");
    self.state = LucidStateAccessDenied;
    return;
  }
  [self attachFirstAvailableDevice];
}

#pragma mark Application

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
  [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
  self.session = [[AVCaptureSession alloc] init];
  self.sessionQueue = dispatch_queue_create("lucid.session", DISPATCH_QUEUE_SERIAL);
  self.failedDeviceIDs = [NSMutableSet set];

  // 1. Listen for devices before CoreMediaIO exposes any. The iPad screen device
  // appears some seconds after screen capture devices are allowed.
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(deviceConnected:)
                 name:AVCaptureDeviceWasConnectedNotification
               object:nil];
  [center addObserver:self
             selector:@selector(deviceDisconnected:)
                 name:AVCaptureDeviceWasDisconnectedNotification
               object:nil];
  [center addObserver:self
             selector:@selector(portFormatChanged:)
                 name:AVCaptureInputPortFormatDescriptionDidChangeNotification
               object:nil];
  [center addObserver:self
             selector:@selector(sessionRuntimeError:)
                 name:AVCaptureSessionRuntimeErrorNotification
               object:self.session];

  // 2. Tell CoreMediaIO to expose iOS screens
  CMIOObjectPropertyAddress prop = {
    kCMIOHardwarePropertyAllowScreenCaptureDevices,
    kCMIOObjectPropertyScopeGlobal,
    kCMIOObjectPropertyElementMain
  };
  UInt32 allow = 1;
  CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &prop, 0, NULL, sizeof(allow), &allow);

  // 3. Show the window, then ask for camera access. Without it, the session
  // cannot read the iPad screen. A screen that is already exposed attaches as
  // soon as access is granted.
  [self buildWindow];
  [self requestCameraAccess];
  [self.window makeKeyAndOrderFront:nil];
  if (@available(macOS 14.0, *)) {
    [NSApp activate];
  } else {
    [NSApp activateIgnoringOtherApps:YES];
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  // Release the device before the process exits
  AVCaptureSession *session = self.session;
  dispatch_sync(self.sessionQueue, ^{
    if (session.isRunning) {
      [session stopRunning];
    }
  });
}

// Quit the app completely when the window is closed
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}

@end

// Standard C function to bootstrap the macOS AppKit lifecycle
void run_mac_app(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    // Make the app appear in the dock and able to receive focus
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    AppDelegate *delegate = [[AppDelegate alloc] init];
    [app setDelegate:delegate];
    [app run];
  }
}
