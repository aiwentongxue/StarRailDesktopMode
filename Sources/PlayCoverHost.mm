#import "Runtime.hpp"
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "DesktopState.hpp"
#include <array>
#include <cstring>
#include <type_traits>
#include <dlfcn.h>
#include <mach-o/dyld.h>

namespace {

using starrail::Point;
using starrail::Rect;

template<class Result = id, class... Args>
Result Send(id object, const char *selector, Args... args) {
    if (!object) {
        if constexpr (std::is_void_v<Result>) return;
        else return Result{};
    }
    return reinterpret_cast<Result (*)(id, SEL, Args...)>(objc_msgSend)(
        object, sel_registerName(selector), args...);
}

Rect RectFromCGRect(CGRect rect) {
    return {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}

id MacApplication() {
    return Send(NSClassFromString(@"NSApplication"), "sharedApplication");
}

double CameraGain() {
    NSString *usersLibrary = [NSHomeDirectoryForUser(NSUserName()) stringByAppendingPathComponent:@"Library"];
    NSString *manager = [NSBundle.mainBundle objectForInfoDictionaryKey:@"SRDMPlayCoverManager"];
    if (![manager isEqualToString:@"com.iven.playcover.custom"]) manager = @"io.playcover.PlayCover";
    NSString *directory = [usersLibrary stringByAppendingPathComponent:@"Containers"];
    directory = [[directory stringByAppendingPathComponent:manager] stringByAppendingPathComponent:@"App Settings"];
    NSString *plist = [NSBundle.mainBundle.bundleIdentifier stringByAppendingPathExtension:@"plist"];
    NSNumber *setting = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:plist]][@"sensitivity"];
    return [setting isKindOfClass:NSNumber.class] ? starrail::SensitivityGain(setting.doubleValue) : 1;
}

UIView *FindMetalView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    if ([view.layer isKindOfClass:CAMetalLayer.class]) return view;
    for (UIView *child in view.subviews.reverseObjectEnumerator) {
        if (UIView *found = FindMetalView(child)) return found;
    }
    return nil;
}

UIView *ForegroundMetalView() {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *window = ((UIWindowScene *)scene).keyWindow;
        UIViewController *root = window.rootViewController;
        if (root.presentedViewController) continue;
        if (UIView *view = FindMetalView(root.viewIfLoaded)) return view;
    }
    return nil;
}

Rect ScreenViewport(id window, UIView *view, double primaryTop) {
    if (!window || !view.window || Send<BOOL>(window, "isMiniaturized") ||
        !Send<BOOL>(window, "isKeyWindow") || Send<BOOL>(window, "isSheet")) return {};
    CGRect content = Send<CGRect>(window, "contentLayoutRect");
    if (Send<NSUInteger>(window, "styleMask") & (1UL << 14)) {
        id contentView = Send(window, "contentView");
        if (!contentView) return {};
        content = Send<CGRect>(contentView, "convertRect:toView:", Send<CGRect>(contentView, "bounds"), (id)nil);
    }
    content = Send<CGRect>(window, "convertRectToScreen:", content);
    const CGRect rectInWindow = [view convertRect:view.bounds toView:view.window];
    return GameViewport(QuartzRect(RectFromCGRect(content), primaryTop),
                        RectFromCGRect(view.window.bounds), RectFromCGRect(rectInWindow));
}

bool IsEditing(id window) {
    id responder = Send(window, "firstResponder");
    return [responder isKindOfClass:NSClassFromString(@"NSTextView")] ||
           [responder isKindOfClass:NSClassFromString(@"NSTextField")];
}

bool GameReceivesPointerAt(UIView *view, const Rect &bounds, Point point) {
    if (!bounds.contains(point)) return false;
    const CGRect viewBounds = view.bounds;
    CGPoint local = CGPointMake(viewBounds.origin.x + (point.x - bounds.x) * viewBounds.size.width / bounds.width,
                                viewBounds.origin.y + (point.y - bounds.y) * viewBounds.size.height / bounds.height);
    const CGPoint inWindow = [view convertPoint:local toView:view.window];
    UIView *target = [view.window hitTest:inWindow withEvent:nil];
    return target == view || [target isDescendantOfView:view];
}

char gameLockPreference;
char gameLockHook;

void SetGamePointerLock(UIViewController *controller, bool locked) {
    if (!controller) return;
    NSNumber *current = objc_getAssociatedObject(controller, &gameLockPreference);
    if (current.boolValue == locked) return;
    const SEL selector = @selector(prefersPointerLocked);
    Class type = object_getClass(controller);
    if (!objc_getAssociatedObject(type, &gameLockHook)) {
        Method method = class_getInstanceMethod(type, selector);
        if (!method) return;
        auto original = reinterpret_cast<BOOL (*)(UIViewController *, SEL)>(method_getImplementation(method));
        IMP requested = imp_implementationWithBlock(^BOOL(UIViewController *root) {
            NSNumber *setting = objc_getAssociatedObject(root, &gameLockPreference);
            return setting ? setting.boolValue : original(root, selector);
        });
        class_replaceMethod(type, selector, requested, method_getTypeEncoding(method));
        objc_setAssociatedObject(type, &gameLockHook, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(controller, &gameLockPreference, @(locked), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller setNeedsUpdateOfPrefersPointerLocked];
}

bool SetQuartzPointerCapture(bool enabled) {
    using Associate = CGError (*)(boolean_t);
    using ChangeVisibility = CGError (*)(CGDirectDisplayID);
    static const auto associate = reinterpret_cast<Associate>(dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition"));
    static const auto hide = reinterpret_cast<ChangeVisibility>(dlsym(RTLD_DEFAULT, "CGDisplayHideCursor"));
    static const auto show = reinterpret_cast<ChangeVisibility>(dlsym(RTLD_DEFAULT, "CGDisplayShowCursor"));
    if (!associate || !hide || !show) return false;

    if (!enabled) {
        associate(true);
        show(kCGNullDirectDisplay);
        return false;
    }
    if (associate(false) != kCGErrorSuccess) return false;
    if (hide(kCGNullDirectDisplay) == kCGErrorSuccess) return true;
    associate(true);
    return false;
}

using SetCursor = void (*)(id, SEL);
SetCursor originalSetCursor;
bool ownsVisibleArrow;
id customCursor;

id Arrow() {
    return Send(NSClassFromString(@"NSCursor"), "arrowCursor");
}

void SetCursorInGame(id cursor, SEL selector) {
    if (NSThread.isMainThread && ownsVisibleArrow && cursor == Arrow()) cursor = customCursor;
    originalSetCursor(cursor, selector);
}

id LoadCursor() {
    NSURL *resource = [SRDMApplicationSupport() URLByAppendingPathComponent:@"cursor.png"];
    if (!resource) return nil;
    NSNumber *size = nil;
    if (![resource getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || size.unsignedIntegerValue > 1024 * 1024) return nil;
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)resource, nullptr);
    if (!imageSource) return nil;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nullptr);
    NSDictionary *metadata = CFBridgingRelease(properties);
    bool valid = CGImageSourceGetCount(imageSource) == 1 &&
                 [(__bridge NSString *)CGImageSourceGetType(imageSource) isEqualToString:@"public.png"] &&
                 [metadata[(__bridge NSString *)kCGImagePropertyPixelWidth] intValue] == 64 &&
                 [metadata[(__bridge NSString *)kCGImagePropertyPixelHeight] intValue] == 64;
    CFRelease(imageSource);
    if (!valid) return nil;

    id image = Send(Send(NSClassFromString(@"NSImage"), "alloc"), "initWithContentsOfURL:", resource);
    if (!image) return nil;
    Send<void>(image, "setSize:", CGSizeMake(32, 32));
    // The reference arrow tip is at (16, 6) in the 2× raster.
    return Send(Send(NSClassFromString(@"NSCursor"), "alloc"), "initWithImage:hotSpot:", image, CGPointMake(8, 3));
}

void RefreshCursor(bool owns) {
    if (!customCursor || !originalSetCursor) return;
    ownsVisibleArrow = owns;
    id currentCursor = Send(NSClassFromString(@"NSCursor"), "currentCursor");
    if (owns && currentCursor == Arrow()) {
        originalSetCursor(customCursor, sel_registerName("set"));
    } else if (!owns && currentCursor == customCursor) {
        originalSetCursor(Arrow(), sel_registerName("set"));
    }
}

struct UnityImage {
    const mach_header_64 *header = nullptr;
    intptr_t slide = 0;
};

UnityImage FindVerifiedUnityImage() {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !std::string_view(name).ends_with("/UnityFramework.framework/UnityFramework")) continue;
        const auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return {};
        const auto *cursor = reinterpret_cast<const uint8_t *>(header + 1);
        uint32_t remaining = header->sizeofcmds;
        for (uint32_t command = 0; command < header->ncmds; ++command) {
            if (remaining < sizeof(load_command)) return {};
            const auto *item = reinterpret_cast<const load_command *>(cursor);
            if (item->cmdsize < sizeof(load_command) || item->cmdsize > remaining) return {};
            if (item->cmd == LC_UUID && item->cmdsize == sizeof(uuid_command)) {
                std::array<uint8_t, 16> uuid{};
                std::memcpy(uuid.data(), reinterpret_cast<const uuid_command *>(item)->uuid, uuid.size());
                NSBundle *bundle = NSBundle.mainBundle;
                if (starrail::Matches(starrail::China470, bundle.bundleIdentifier.UTF8String,
                    [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "",
                    [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "", uuid)) {
                    return {header, _dyld_get_image_vmaddr_slide(i)};
                }
                return {};
            }
            cursor += item->cmdsize;
            remaining -= item->cmdsize;
        }
        return {};
    }
    return {};
}

} // namespace

NSURL *SRDMApplicationSupport(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"StarRailDesktopMode" isDirectory:YES];
}

bool SRDMGameAcceptsKeyboard() {
    id app = MacApplication();
    if (!Send<BOOL>(app, "isActive")) return false;
    id window = Send(app, "keyWindow");
    return Send<BOOL>(window, "isKeyWindow") && !Send<BOOL>(window, "isSheet") &&
           !IsEditing(window) && ForegroundMetalView();
}

@interface SRDMPlayCoverHost : NSObject
- (void)startWithImage:(const mach_header_64 *)header slide:(intptr_t)slide;
- (void)frame:(CADisplayLink *)displayLink;
@end

@implementation SRDMPlayCoverHost {
    starrail::PointerTransition _pointer;
    __weak UIView *_lastView;
    __weak UIViewController *_lockController;
    __weak id _mouseTrackingWindow;
    BOOL _initialMouseMovedEvents;
    bool _quartzPointerCaptured;
    bool _attemptedQuartzCapture;
    double _gain;
    bool _diagnosticsOnly;
    bool _diagnosticsEnabled;
    bool _loggedViewport;
    bool _loggedHostContext;
    bool _playToolsCursorHidden;
    bool _desktopLayout;
}

- (void)startWithImage:(const mach_header_64 *)header slide:(intptr_t)slide {
    NSURL *support = SRDMApplicationSupport();
    auto hasMarker = ^bool(NSString *name) {
        NSString *path = [support URLByAppendingPathComponent:name].path;
        return path && [NSFileManager.defaultManager fileExistsAtPath:path];
    };
    _diagnosticsOnly = hasMarker(@"diagnostics-only");
    _diagnosticsEnabled = _diagnosticsOnly || hasMarker(@"diagnostics");
    if (_diagnosticsEnabled) SRDMStartDiagnostics();

    if (!_diagnosticsOnly) {
        NSURL *legacy = [[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"UserPlugins"]
                         URLByAppendingPathComponent:@"libUnityDesktopMode.dylib"];
        if (legacy && [NSFileManager.defaultManager fileExistsAtPath:legacy.path]) {
            NSLog(@"[StarRailDesktopMode] remove the legacy desktop-mode plugin before enabling input");
            return;
        }
        _desktopLayout = SRDMEnableDesktopLayout(*header, slide);
    }
    if (_desktopLayout) {
        // Unity fills its native delegate table during player initialization.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            const bool enabled = SRDMEnableDesktopCursor(*header, slide);
            NSLog(@"[StarRailDesktopMode] game cursor lifecycle=%d", enabled);
            NSLog(@"[StarRailDesktopMode] native keyboard=%d", SRDMInstallKeyboard(*header, slide));
            NSLog(@"[StarRailDesktopMode] native mouse axes=%d", SRDMInstallMouse(*header, slide));
        });
        _gain = CameraGain();
        customCursor = LoadCursor();
        if (customCursor) {
            Method setter = class_getInstanceMethod(NSClassFromString(@"NSCursor"), sel_registerName("set"));
            if (setter) originalSetCursor = reinterpret_cast<SetCursor>(method_setImplementation(setter, (IMP)SetCursorInGame));
        }
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:UIPointerLockStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:@"SRDMUnityCursorChanged" object:nil];
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:@"NSWindowDidBecomeKeyNotification" object:nil];
        [center addObserver:self selector:@selector(playToolsCursorWillHide:)
                      name:@"playtools.cursorWillHide" object:nil];
        [center addObserver:self selector:@selector(playToolsCursorWillShow:)
                      name:@"playtools.cursorWillShow" object:nil];
        [center addObserver:self selector:@selector(lostFocus:)
                      name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(lostFocus:)
                      name:@"NSApplicationWillResignActiveNotification" object:nil];
        [center addObserver:self selector:@selector(lostFocus:)
                      name:@"NSApplicationWillTerminateNotification" object:nil];
    }
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSLog(@"[StarRailDesktopMode] host ready client=CN-4.7.0 diagnostic_only=%d desktop_layout=%d custom_arrow=%d",
          _diagnosticsOnly, _desktopLayout, customCursor != nil);
}

- (void)lostFocus:(NSNotification *)notification {
    (void)notification;
    _pointer.update(false, true);
    SetGamePointerLock(_lockController, false);
    _lockController = nil;
    SRDMSetCameraMouseCapture(false, _gain);
    [self updateQuartzCapture:false];
    [self setMouseTrackingWindow:nil];
    SRDMReleaseKeyboard();
    RefreshCursor(false);
}

- (void)updateQuartzCapture:(bool)requested {
    if (!requested) {
        if (_quartzPointerCaptured) _quartzPointerCaptured = SetQuartzPointerCapture(false);
        _attemptedQuartzCapture = false;
    } else if (!_attemptedQuartzCapture) {
        _attemptedQuartzCapture = true;
        _quartzPointerCaptured = SetQuartzPointerCapture(true);
        if (_diagnosticsEnabled) NSLog(@"[StarRailDesktopMode] Quartz pointer capture=%d", _quartzPointerCaptured);
    }
}

- (void)setMouseTrackingWindow:(id)window {
    if (_mouseTrackingWindow == window) return;
    Send<void>(_mouseTrackingWindow, "setAcceptsMouseMovedEvents:", _initialMouseMovedEvents);
    _mouseTrackingWindow = window;
    _initialMouseMovedEvents = Send<BOOL>(window, "acceptsMouseMovedEvents");
    Send<void>(window, "setAcceptsMouseMovedEvents:", YES);
}

- (void)playToolsCursorWillHide:(NSNotification *)notification {
    (void)notification;
    _playToolsCursorHidden = true;
    [self updatePointer];
}

- (void)playToolsCursorWillShow:(NSNotification *)notification {
    (void)notification;
    _playToolsCursorHidden = false;
    dispatch_async(dispatch_get_main_queue(), ^{ [self updatePointer]; });
}

- (void)pointerLockChanged:(NSNotification *)notification {
    (void)notification;
    [self updatePointer];
}

- (void)updatePointer {
    id app = MacApplication();
    id window = Send(app, "keyWindow");
    const bool appActive = Send<BOOL>(app, "isActive");
    UIView *view = appActive ? ForegroundMetalView() : nil;
    NSArray *screens = Send(NSClassFromString(@"NSScreen"), "screens");
    const CGRect primaryScreen = Send<CGRect>(screens.firstObject, "frame");
    const double primaryTop = CGRectGetMaxY(primaryScreen);
    const starrail::Rect viewport = screens.count ? ScreenViewport(window, view, primaryTop) : starrail::Rect{};
    const bool gameOwns = viewport.valid() && !IsEditing(window);
    if (!gameOwns) SRDMReleaseKeyboard();
    if (_diagnosticsEnabled && view && !_loggedHostContext) {
        _loggedHostContext = true;
        NSLog(@"[StarRailDesktopMode] window key=%d scene_view=%.0fx%.0f valid_viewport=%d editing=%d",
              Send<BOOL>(window, "isKeyWindow"), view.bounds.size.width, view.bounds.size.height,
              viewport.valid(), IsEditing(window));
    }

    static auto cursorVisible = reinterpret_cast<boolean_t (*)()>(dlsym(RTLD_DEFAULT, "CGCursorIsVisible"));
    static auto warp = reinterpret_cast<CGError (*)(CGPoint)>(dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition"));
    UIViewController *controller = gameOwns ? view.window.rootViewController : nil;
    if (_lockController != controller) {
        SetGamePointerLock(_lockController, false);
        _lockController = controller;
    }
    const auto requested = SRDMRequestedCursor();
    const bool needsLock = gameOwns && requested.known && !requested.visible &&
                           requested.locked && !_playToolsCursorHidden;
    [self updateQuartzCapture:needsLock];
    SetGamePointerLock(_lockController, needsLock && !_quartzPointerCaptured);
    const bool locked = _quartzPointerCaptured || view.window.windowScene.pointerLockState.isLocked;
    const bool systemVisible = !cursorVisible || cursorVisible() != 0;
    const bool visible = !locked && !_playToolsCursorHidden && systemVisible && (!requested.known || requested.visible);
    const CGPoint mousePosition = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
    starrail::Point mouse{mousePosition.x, primaryTop - mousePosition.y};

    if (_lastView != view) {
        _pointer.update(false, true);
        SRDMSetCameraMouseCapture(false, _gain);
        _lastView = view;
    }
    const bool pointerInside = gameOwns && GameReceivesPointerAt(view, viewport, mouse);
    const bool shouldCenter = _pointer.update(gameOwns && (visible || needsLock || locked || _playToolsCursorHidden || pointerInside), visible);
    const bool cameraCapture = needsLock && locked;
    [self setMouseTrackingWindow:cameraCapture ? window : nil];
    SRDMSetCameraMouseCapture(cameraCapture, _gain);
    if (shouldCenter && warp) {
        const auto spot = viewport.center();
        if (warp(CGPointMake(spot.x, spot.y)) == kCGErrorSuccess) {
            mouse = spot;
            if (_diagnosticsEnabled) {
                const CGPoint actual = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
                NSLog(@"[StarRailDesktopMode] pointer centered error=(%.2f,%.2f) pt",
                      actual.x - spot.x, primaryTop - actual.y - spot.y);
            }
        }
    }
    RefreshCursor(gameOwns && visible && GameReceivesPointerAt(view, viewport, mouse));

    if (_diagnosticsEnabled && gameOwns && !_loggedViewport) {
        _loggedViewport = true;
        NSLog(@"[StarRailDesktopMode] viewport %.0fx%.0f", viewport.width, viewport.height);
    }
}

- (void)frame:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (_desktopLayout) [self updatePointer];
    if (!_diagnosticsEnabled) return;
    SRDMSampleGraphics((CAMetalLayer *)ForegroundMetalView().layer);
}
@end

namespace {
void Activate() {
    static bool attempted = false;
    if (attempted) return;
    const auto image = FindVerifiedUnityImage();
    if (!image.header) {
        NSLog(@"[StarRailDesktopMode] Unity build does not match the CN-4.7.0 profile");
        return;
    }
    attempted = true;
    [[[SRDMPlayCoverHost alloc] init] startWithImage:image.header slide:image.slide];
}

void ImageAdded(const mach_header *header, intptr_t) {
    Dl_info info{};
    if (!dladdr(header, &info) || !info.dli_fname ||
        !std::string_view(info.dli_fname).ends_with("/UnityFramework.framework/UnityFramework")) return;
    dispatch_async(dispatch_get_main_queue(), ^{ Activate(); });
}

__attribute__((constructor)) void Initialize() {
    @autoreleasepool {
        const NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.miHoYo.hkrpg"]) return;
        _dyld_register_func_for_add_image(ImageAdded);
    }
}
} // namespace
