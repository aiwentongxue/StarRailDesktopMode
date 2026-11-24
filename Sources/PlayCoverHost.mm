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

#ifdef SRDM_EMBED_CURSOR
#include "SRDMEmbeddedCursor.hpp"
#endif

using starrail::Point;
using starrail::Rect;
bool regionSwitchDialogOpen;
NSUInteger menuTrackingDepth;

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

id GameInputWindow() {
    id app = MacApplication();
    if (menuTrackingDepth || regionSwitchDialogOpen || !Send<BOOL>(app, "isActive") ||
        Send(app, "modalWindow")) return nil;
    return Send(app, "keyWindow");
}

double CameraGain() {
    if (NSProcessInfo.processInfo.environment[@"POMPOMIA_MODE"]) return 1;
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

using WarpPointer = CGError (*)(CGPoint);
using AssociatePointer = CGError (*)(boolean_t);
using ChangeVisibility = CGError (*)(CGDirectDisplayID);

WarpPointer QuartzWarp() {
    static const auto warp = reinterpret_cast<WarpPointer>(dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition"));
    return warp;
}

AssociatePointer QuartzAssociation() {
    static const auto associate = reinterpret_cast<AssociatePointer>(dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition"));
    return associate;
}

ChangeVisibility QuartzCursorVisibility(bool visible) {
    static const auto hide = reinterpret_cast<ChangeVisibility>(dlsym(RTLD_DEFAULT, "CGDisplayHideCursor"));
    static const auto show = reinterpret_cast<ChangeVisibility>(dlsym(RTLD_DEFAULT, "CGDisplayShowCursor"));
    return visible ? show : hide;
}

bool SetQuartzPointerCapture(bool enabled, Point anchor = {}) {
    const auto associate = QuartzAssociation();
    const auto hide = QuartzCursorVisibility(false);
    const auto show = QuartzCursorVisibility(true);
    if (!associate || !hide || !show) return false;

    if (!enabled) {
        associate(true);
        show(kCGNullDirectDisplay);
        return false;
    }
    const auto warp = QuartzWarp();
    if (!warp || associate(false) != kCGErrorSuccess) return false;
    if (hide(kCGNullDirectDisplay) == kCGErrorSuccess) {
        if (warp(CGPointMake(anchor.x, anchor.y)) == kCGErrorSuccess) return true;
        show(kCGNullDirectDisplay);
    }
    associate(true);
    return false;
}

using SetCursor = void (*)(id, SEL);
SetCursor originalSetCursor;
bool ownsVisibleArrow;
id customCursor;
UIImage *customCursorArtwork;
constexpr double CursorSize = 32;
constexpr CGPoint CursorHotSpot{8, 3};

id Arrow() {
    return Send(NSClassFromString(@"NSCursor"), "arrowCursor");
}

void SetCursorInGame(id cursor, SEL selector) {
    if (NSThread.isMainThread && ownsVisibleArrow) cursor = customCursor;
    originalSetCursor(cursor, selector);
}

constexpr NSUInteger MaxCursorBytes = 1024 * 1024;

id CursorFromPNG(NSData *png) {
    if (!png.length || png.length > MaxCursorBytes) return nil;
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)png, nullptr);
    if (!imageSource) return nil;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nullptr);
    NSDictionary *metadata = CFBridgingRelease(properties);
    bool valid = CGImageSourceGetCount(imageSource) == 1 &&
                 [(__bridge NSString *)CGImageSourceGetType(imageSource) isEqualToString:@"public.png"] &&
                 [metadata[(__bridge NSString *)kCGImagePropertyPixelWidth] intValue] == 64 &&
                 [metadata[(__bridge NSString *)kCGImagePropertyPixelHeight] intValue] == 64;
    CGImageRef raster = valid ? CGImageSourceCreateImageAtIndex(imageSource, 0, nullptr) : nullptr;
    CFRelease(imageSource);
    if (!raster) return nil;

    id image = Send(Send(NSClassFromString(@"NSImage"), "alloc"), "initWithCGImage:size:", raster,
                    CGSizeMake(CursorSize, CursorSize));
    if (image) customCursorArtwork = [UIImage imageWithCGImage:raster scale:2 orientation:UIImageOrientationUp];
    CGImageRelease(raster);
    if (!image) return nil;
    // The reference arrow tip is at (16, 6) in the 2× raster.
    return Send(Send(NSClassFromString(@"NSCursor"), "alloc"), "initWithImage:hotSpot:", image, CursorHotSpot);
}

id LoadCursor() {
    NSURL *resource = [SRDMApplicationSupport() URLByAppendingPathComponent:@"cursor.png"];
    NSNumber *size = nil;
    if ([resource getResourceValue:&size forKey:NSURLFileSizeKey error:nil] && size.unsignedIntegerValue <= MaxCursorBytes) {
        if (id cursor = CursorFromPNG([NSData dataWithContentsOfURL:resource])) {
            NSLog(@"[StarRailDesktopMode] cursor source=file");
            return cursor;
        }
    }
#ifdef SRDM_EMBED_CURSOR
    if (id cursor = CursorFromPNG([NSData dataWithBytes:EmbeddedCursorPNG length:sizeof(EmbeddedCursorPNG)])) {
        NSLog(@"[StarRailDesktopMode] cursor source=embedded");
        return cursor;
    }
#endif
    return nil;
}

void RefreshCursor(bool owns, bool reapply = false) {
    if (!customCursor || !originalSetCursor) return;
    ownsVisibleArrow = owns;
    id currentCursor = Send(NSClassFromString(@"NSCursor"), "currentCursor");
    if (owns && (reapply || currentCursor != customCursor)) {
        originalSetCursor(customCursor, sel_registerName("set"));
    } else if (!owns && currentCursor == customCursor) {
        originalSetCursor(Arrow(), sel_registerName("set"));
    }
}

struct UnityImage {
    const mach_header_64 *header = nullptr;
    intptr_t slide = 0;
    const starrail::ClientProfile *client = nullptr;
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
                if (const auto *profile = starrail::FindClient(bundle.bundleIdentifier.UTF8String ?: "",
                    [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "",
                    [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "", uuid)) {
                    return {header, _dyld_get_image_vmaddr_slide(i), profile};
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

CGSize SRDMGameDrawableSize() {
    if (!NSThread.isMainThread) return CGSizeZero;
    return ((CAMetalLayer *)ForegroundMetalView().layer).drawableSize;
}

bool SRDMGameAcceptsKeyboard() {
    id window = GameInputWindow();
    return Send<BOOL>(window, "isKeyWindow") && !Send<BOOL>(window, "isSheet") &&
           !IsEditing(window) && ForegroundMetalView();
}

@interface SRDMPlayCoverHost : NSObject
- (void)startWithImage:(const mach_header_64 *)header slide:(intptr_t)slide client:(const starrail::ClientProfile *)client;
- (void)frame:(CADisplayLink *)displayLink;
@end

@implementation SRDMPlayCoverHost {
    starrail::PointerTransition _pointer;
    __weak UIView *_lastView;
    __weak UIViewController *_lockController;
    __weak id _mouseTrackingWindow;
    __weak id _cursorRectWindow;
    UIImageView *_cursorOverlay;
    bool _useCursorOverlay;
    bool _cursorHiddenForOverlay;
    bool _loggedCursorOverlay;
    id _cursorEventMonitor;
    starrail::Point _visibleArrowLocation;
    bool _visibleArrowMoved;
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
    bool _radialPositionInstalled;
    bool _radialHeld;
    double _radialReleaseUntil;
}

- (void)startWithImage:(const mach_header_64 *)header slide:(intptr_t)slide client:(const starrail::ClientProfile *)client {
    _useCursorOverlay = NSProcessInfo.processInfo.environment[@"POMPOMIA_MODE"] != nil;
    NSURL *support = SRDMApplicationSupport();
    auto hasMarker = ^bool(NSString *name) {
        NSString *path = [support URLByAppendingPathComponent:name].path;
        return path && [NSFileManager.defaultManager fileExistsAtPath:path];
    };
    _diagnosticsOnly = hasMarker(@"diagnostics-only");
    _diagnosticsEnabled = _diagnosticsOnly || hasMarker(@"diagnostics");
    if (_diagnosticsEnabled) SRDMStartDiagnostics();

    if (!_diagnosticsOnly) {
        if (_useCursorOverlay) {
            NSLog(@"[StarRailDesktopMode] login version label=%d", SRDMInstallLoginVersionLabel(*header, slide, *client));
        }
        NSURL *research = [[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"UserPlugins"]
                           URLByAppendingPathComponent:@"libSRDMCaptureResearch.dylib"];
        if (!hasMarker(@"graphics-disabled") && ![NSFileManager.defaultManager fileExistsAtPath:research.path]) {
            NSLog(@"[StarRailDesktopMode] graphics settings=%d", SRDMInstallGraphicsSettings(*header, slide, *client));
        }
        NSURL *legacy = [[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"UserPlugins"]
                         URLByAppendingPathComponent:@"libUnityDesktopMode.dylib"];
        if (legacy && [NSFileManager.defaultManager fileExistsAtPath:legacy.path]) {
            NSLog(@"[StarRailDesktopMode] remove the legacy desktop-mode plugin before enabling input");
            return;
        }
        _desktopLayout = SRDMEnableDesktopLayout(*header, slide, *client);
    }
    if (_desktopLayout) {
        // Unity fills its native delegate table during player initialization.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            const bool enabled = SRDMEnableDesktopCursor(*header, slide, *client);
            NSLog(@"[StarRailDesktopMode] game cursor lifecycle=%d", enabled);
            NSLog(@"[StarRailDesktopMode] native keyboard=%d", SRDMInstallKeyboard(*header, slide, *client));
            const bool mouse = SRDMInstallMouse(*header, slide, *client, _radialPositionInstalled);
            NSLog(@"[StarRailDesktopMode] native mouse axes=%d radial position=%d", mouse, _radialPositionInstalled);
        });
        _gain = CameraGain();
        customCursor = LoadCursor();
        if (customCursor) {
            [self installCursorTracking];
        }
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:UIPointerLockStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:@"SRDMUnityCursorChanged" object:nil];
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:@"NSWindowDidBecomeKeyNotification" object:nil];
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:@"NSApplicationDidBecomeActiveNotification" object:nil];
        [center addObserver:self selector:@selector(regionSwitchDialogChanged:)
                      name:@"com.iven.pompomia.regionSwitchDialogChanged" object:nil];
        [center addObserver:self selector:@selector(menuDidBeginTracking:)
                      name:@"NSMenuDidBeginTrackingNotification" object:nil];
        [center addObserver:self selector:@selector(menuDidEndTracking:)
                      name:@"NSMenuDidEndTrackingNotification" object:nil];
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
    NSLog(@"[StarRailDesktopMode] host ready client=%s %s diagnostic_only=%d desktop_layout=%d custom_arrow=%d",
          client->bundleID.data(), client->version.data(), _diagnosticsOnly, _desktopLayout, customCursor != nil);
}

- (void)lostFocus:(NSNotification *)notification {
    (void)notification;
    _radialHeld = false;
    _radialReleaseUntil = 0;
    SRDMSetRadialPosition(false, CGPointZero);
    _pointer.update(false, true);
    SetGamePointerLock(_lockController, false);
    _lockController = nil;
    SRDMSetCameraMouseCapture(false, _gain);
    [self updateQuartzCapture:false anchor:starrail::Point{}];
    [self setMouseTrackingWindow:nil];
    SRDMReleaseKeyboard();
    RefreshCursor(false);
    [self hideCursorOverlay];
    [self setGameCursorRectWindow:nil];
}

- (bool)updateQuartzCapture:(bool)requested anchor:(starrail::Point)anchor {
    if (!requested) {
        if (_quartzPointerCaptured) _quartzPointerCaptured = SetQuartzPointerCapture(false);
        _attemptedQuartzCapture = false;
    } else if (!_attemptedQuartzCapture) {
        _attemptedQuartzCapture = true;
        _quartzPointerCaptured = SetQuartzPointerCapture(true, anchor);
        if (_diagnosticsEnabled) NSLog(@"[StarRailDesktopMode] Quartz pointer capture=%d", _quartzPointerCaptured);
        return _quartzPointerCaptured;
    }
    return false;
}

- (void)installCursorTracking {
    Method setter = class_getInstanceMethod(NSClassFromString(@"NSCursor"), sel_registerName("set"));
    if (!setter) return;
    originalSetCursor = reinterpret_cast<SetCursor>(method_setImplementation(setter, (IMP)SetCursorInGame));
    __weak SRDMPlayCoverHost *host = self;
    Class events = NSClassFromString(@"NSEvent");
    const SEL addMonitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (![events respondsToSelector:addMonitor]) return;
    constexpr uint64_t CursorUpdateEvents = 1ULL << 17; // NSEventMaskCursorUpdate
    id (^handle)(id) = ^id(id event) {
        SRDMPlayCoverHost *owner = host;
        if (!owner) return event;
        [owner updatePointer];
        return ownsVisibleArrow ? nil : event;
    };
    _cursorEventMonitor = reinterpret_cast<id (*)(Class, SEL, uint64_t, id)>(objc_msgSend)(
        events, addMonitor, CursorUpdateEvents, handle);
}

- (void)hideCursorOverlay {
    _cursorOverlay.hidden = YES;
    if (_cursorHiddenForOverlay && QuartzCursorVisibility(true)(kCGNullDirectDisplay) == kCGErrorSuccess) {
        _cursorHiddenForOverlay = false;
    }
}

- (bool)showCursorOverlayInView:(UIView *)view viewport:(starrail::Rect)viewport location:(starrail::Point)mouse {
    UIWindow *window = view.window;
    if (!window || !customCursorArtwork) return false;
    const CGRect bounds = view.bounds;
    const double scaleX = bounds.size.width / viewport.width;
    const double scaleY = bounds.size.height / viewport.height;
    const CGRect local = CGRectMake(bounds.origin.x + (mouse.x - viewport.x - CursorHotSpot.x) * scaleX,
                                    bounds.origin.y + (mouse.y - viewport.y - CursorHotSpot.y) * scaleY,
                                    CursorSize * scaleX, CursorSize * scaleY);
    const CGRect frame = [view convertRect:local toView:window];
    if (!_cursorHiddenForOverlay) {
        const auto hide = QuartzCursorVisibility(false);
        if (!hide || !QuartzCursorVisibility(true) || hide(kCGNullDirectDisplay) != kCGErrorSuccess) return false;
        _cursorHiddenForOverlay = true;
    }
    if (!_cursorOverlay) {
        _cursorOverlay = [[UIImageView alloc] initWithImage:customCursorArtwork];
        _cursorOverlay.userInteractionEnabled = NO;
        _cursorOverlay.isAccessibilityElement = NO;
    }
    if (!CGRectEqualToRect(_cursorOverlay.frame, frame)) _cursorOverlay.frame = frame;
    if (_cursorOverlay.superview != window) [window addSubview:_cursorOverlay];
    if (window.subviews.lastObject != _cursorOverlay) [window bringSubviewToFront:_cursorOverlay];
    _cursorOverlay.hidden = NO;
    if (!_loggedCursorOverlay) {
        NSLog(@"[StarRailDesktopMode] cursor presentation=overlay");
        _loggedCursorOverlay = true;
    }
    return true;
}

- (void)setGameCursorRectWindow:(id)window {
    if (window != _cursorRectWindow) {
        Send<void>(_cursorRectWindow, "enableCursorRects");
        _cursorRectWindow = nil;
    }
    if (Send<BOOL>(window, "areCursorRectsEnabled")) {
        Send<void>(window, "disableCursorRects");
        _cursorRectWindow = window;
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

- (void)regionSwitchDialogChanged:(NSNotification *)notification {
    regionSwitchDialogOpen = [notification.object boolValue];
    [self updatePointer];
}

- (void)menuDidBeginTracking:(NSNotification *)notification {
    (void)notification;
    ++menuTrackingDepth;
    [self updatePointer];
}

- (void)menuDidEndTracking:(NSNotification *)notification {
    (void)notification;
    // Let the selected menu action run before the next frame can capture the mouse again.
    if (menuTrackingDepth) --menuTrackingDepth;
}

- (void)updatePointer {
    id window = GameInputWindow();
    UIView *view = window ? ForegroundMetalView() : nil;
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
    const auto warp = QuartzWarp();
    UIViewController *controller = gameOwns ? view.window.rootViewController : nil;
    if (_lockController != controller) {
        SetGamePointerLock(_lockController, false);
        _lockController = controller;
    }
    const auto requested = SRDMRequestedCursor();
    const bool needsGameLock = gameOwns && requested.known && !requested.visible &&
                               requested.locked && !_playToolsCursorHidden;
    using KeyState = bool (*)(uint32_t, uint16_t);
    static const auto keyDown = reinterpret_cast<KeyState>(dlsym(RTLD_DEFAULT, "CGEventSourceKeyState"));
    const double now = NSProcessInfo.processInfo.systemUptime;
    const bool tabHeld = _radialPositionInstalled && gameOwns && keyDown && keyDown(0, 48);
    const bool radialHeld = tabHeld && (_radialHeld || needsGameLock);
    if (_radialHeld != radialHeld) {
        // Keep the selection coordinate available when Unity processes Tab up.
        if (_diagnosticsEnabled) {
            NSLog(@"[StarRailDesktopMode] radial held=%d, unity visible=%d, locked=%d",
                  radialHeld, requested.visible, requested.locked);
        }
        _radialReleaseUntil = gameOwns && !radialHeld ? now + 0.05 : 0;
    }
    _radialHeld = radialHeld;
    if (!gameOwns) _radialReleaseUntil = 0;
    const bool needsLock = needsGameLock && !radialHeld;
    if (!gameOwns || needsLock || _playToolsCursorHidden || (requested.known && !requested.visible)) {
        [self hideCursorOverlay];
    }
    const CGPoint before = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
    const starrail::Point from{before.x, primaryTop - before.y};
    const auto center = viewport.center();
    const bool warped = [self updateQuartzCapture:needsLock anchor:center];
    SetGamePointerLock(_lockController, needsLock && !_quartzPointerCaptured);
    const bool locked = _quartzPointerCaptured || view.window.windowScene.pointerLockState.isLocked;
    const bool systemVisible = _cursorHiddenForOverlay || !cursorVisible || cursorVisible() != 0;
    const bool visible = !locked && !_playToolsCursorHidden &&
                         (radialHeld || (systemVisible && (!requested.known || requested.visible)));
    starrail::Point mouse = warped ? center : from;

    if (_lastView != view) {
        _pointer.update(false, true);
        SRDMSetCameraMouseCapture(false, _gain);
        _lastView = view;
    }
    const bool pointerInside = gameOwns && GameReceivesPointerAt(view, viewport, mouse);
    const bool shouldCenter = _pointer.update(gameOwns && (visible || needsLock || locked || _playToolsCursorHidden || pointerInside), visible);
    const bool cameraCapture = needsLock && locked;
    const bool canShowArrow = gameOwns && visible && customCursor;
    [self setMouseTrackingWindow:cameraCapture ? window : nil];
    const CGPoint warpDelta = warped ? CGPointMake(center.x - from.x, from.y - center.y) : CGPointZero;
    SRDMSetCameraMouseCapture(cameraCapture, _gain, warpDelta);
    if (shouldCenter && warp) {
        const auto spot = viewport.center();
        const bool alreadyCentered = std::hypot(mouse.x - spot.x, mouse.y - spot.y) <= 2;
        if (!alreadyCentered && warp(CGPointMake(spot.x, spot.y)) == kCGErrorSuccess) {
            // Reassociate after a visible warp to resume hardware motion
            // immediately, as in SDL's Cocoa warp implementation.
            if (const auto associate = QuartzAssociation()) associate(true);
            mouse = spot;
        }
        if (_diagnosticsEnabled) {
            const CGPoint actual = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
            NSLog(@"[StarRailDesktopMode] pointer centered error=(%.2f,%.2f) pt",
                  actual.x - spot.x, primaryTop - actual.y - spot.y);
        }
    }
    const bool radialPosition = gameOwns && (radialHeld || now < _radialReleaseUntil);
    // Unity expects drawable pixels with an origin at the bottom left.
    const CGSize pixels = radialPosition ? ((CAMetalLayer *)view.layer).drawableSize : CGSizeZero;
    if (radialPosition && pixels.width > 0 && pixels.height > 0) {
        SRDMSetRadialPosition(true, CGPointMake(
            (mouse.x - viewport.x) / viewport.width * pixels.width,
            (viewport.y + viewport.height - mouse.y) / viewport.height * pixels.height));
    } else {
        SRDMSetRadialPosition(false, CGPointZero);
    }
    const bool gameCursor = canShowArrow && viewport.contains(mouse);
    // Use the same pointer location for clicks and the overlay's arrow tip.
    // The system shape can still change underneath the overlay.
    const bool overlay = _useCursorOverlay && gameCursor &&
                         [self showCursorOverlayInView:view viewport:viewport location:mouse];
    if (!overlay) [self hideCursorOverlay];
    const bool hardwareArrow = gameCursor && !overlay && originalSetCursor;
    [self setGameCursorRectWindow:hardwareArrow ? window : nil];
    // AppKit can reset the visible shape during motion without changing
    // NSCursor.currentCursor. Reapply it through the first stationary frame.
    const bool arrowMoved = hardwareArrow && ownsVisibleArrow &&
                            (mouse.x != _visibleArrowLocation.x || mouse.y != _visibleArrowLocation.y);
    RefreshCursor(hardwareArrow, !ownsVisibleArrow || arrowMoved || _visibleArrowMoved);
    _visibleArrowLocation = mouse;
    _visibleArrowMoved = arrowMoved;

    if (_diagnosticsEnabled && gameOwns && !_loggedViewport) {
        _loggedViewport = true;
        NSLog(@"[StarRailDesktopMode] viewport %.0fx%.0f", viewport.width, viewport.height);
    }
}

- (void)frame:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (_desktopLayout) [self updatePointer];
    SRDMUpdateGraphicsSettings();
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
        NSLog(@"[StarRailDesktopMode] Unity build does not match a supported client profile");
        return;
    }
    attempted = true;
    [[[SRDMPlayCoverHost alloc] init] startWithImage:image.header slide:image.slide client:image.client];
}

void ImageAdded(const mach_header *header, intptr_t) {
    Dl_info info{};
    if (!dladdr(header, &info) || !info.dli_fname ||
        !std::string_view(info.dli_fname).ends_with("/UnityFramework.framework/UnityFramework")) return;
    dispatch_async(dispatch_get_main_queue(), ^{ Activate(); });
}

__attribute__((constructor)) void Initialize() {
    @autoreleasepool {
        const std::string_view bundleID = NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "";
        for (const auto *profile : starrail::SupportedClients) {
            if (bundleID != profile->bundleID) continue;
            _dyld_register_func_for_add_image(ImageAdded);
            return;
        }
    }
}
} // namespace
