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
    if ([responder isKindOfClass:NSClassFromString(@"NSTextView")]) return true;
    return false;
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

bool HasVerifiedUnityImage() {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !std::string_view(name).ends_with("/UnityFramework.framework/UnityFramework")) continue;
        const auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return false;
        const auto *cursor = reinterpret_cast<const uint8_t *>(header + 1);
        uint32_t remaining = header->sizeofcmds;
        for (uint32_t command = 0; command < header->ncmds; ++command) {
            if (remaining < sizeof(load_command)) return false;
            const auto *item = reinterpret_cast<const load_command *>(cursor);
            if (item->cmdsize < sizeof(load_command) || item->cmdsize > remaining) return false;
            if (item->cmd == LC_UUID && item->cmdsize == sizeof(uuid_command)) {
                std::array<uint8_t, 16> uuid{};
                std::memcpy(uuid.data(), reinterpret_cast<const uuid_command *>(item)->uuid, uuid.size());
                NSBundle *bundle = NSBundle.mainBundle;
                return starrail::Matches(starrail::China470, bundle.bundleIdentifier.UTF8String,
                    [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "",
                    [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "", uuid);
            }
            cursor += item->cmdsize;
            remaining -= item->cmdsize;
        }
        return false;
    }
    return false;
}

} // namespace

NSURL *SRDMApplicationSupport(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"StarRailDesktopMode" isDirectory:YES];
}

@interface SRDMPlayCoverHost : NSObject
- (void)start;
- (void)frame;
@end

@implementation SRDMPlayCoverHost {
    starrail::PointerTransition _pointer;
    __weak UIView *_lastView;
    double _gain;
    bool _diagnosticsOnly;
    bool _diagnosticsEnabled;
    bool _loggedViewport;
    bool _loggedMouseRoute;
    bool _loggedHostContext;
    bool _playToolsCursorHidden;
}

- (void)start {
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
        _gain = CameraGain();
        SRDMInstallMouseSampling();
        customCursor = LoadCursor();
        if (customCursor) {
            Method setter = class_getInstanceMethod(NSClassFromString(@"NSCursor"), sel_registerName("set"));
            if (setter) originalSetCursor = reinterpret_cast<SetCursor>(method_setImplementation(setter, (IMP)SetCursorInGame));
        }
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(pointerLockChanged:)
                      name:UIPointerLockStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(playToolsCursorWillHide:)
                      name:@"playtools.cursorWillHide" object:nil];
        [center addObserver:self selector:@selector(playToolsCursorWillShow:)
                      name:@"playtools.cursorWillShow" object:nil];
        [center addObserver:self selector:@selector(lostFocus:)
                      name:UIApplicationWillResignActiveNotification object:nil];
    }
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];
    displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSLog(@"[StarRailDesktopMode] host ready client=CN-4.7.0 diagnostic_only=%d custom_arrow=%d",
          _diagnosticsOnly, customCursor != nil);
}

- (void)lostFocus:(NSNotification *)notification {
    (void)notification;
    _pointer.update(false, true);
    SRDMFlushMouse(false, _gain, nil);
    RefreshCursor(false);
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
    UIView *view = Send<BOOL>(app, "isActive") ? ForegroundMetalView() : nil;
    NSArray *screens = Send(NSClassFromString(@"NSScreen"), "screens");
    const CGRect primaryScreen = Send<CGRect>(screens.firstObject, "frame");
    const double primaryTop = CGRectGetMaxY(primaryScreen);
    const starrail::Rect viewport = screens.count ? ScreenViewport(window, view, primaryTop) : starrail::Rect{};
    const bool gameOwns = viewport.valid() && !IsEditing(window);
    if (_diagnosticsEnabled && view && !_loggedHostContext) {
        _loggedHostContext = true;
        NSLog(@"[StarRailDesktopMode] window key=%d scene_view=%.0fx%.0f valid_viewport=%d editing=%d",
              Send<BOOL>(window, "isKeyWindow"), view.bounds.size.width, view.bounds.size.height,
              viewport.valid(), IsEditing(window));
    }

    static auto cursorVisible = reinterpret_cast<boolean_t (*)()>(dlsym(RTLD_DEFAULT, "CGCursorIsVisible"));
    static auto warp = reinterpret_cast<CGError (*)(CGPoint)>(dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition"));
    const bool locked = view.window.windowScene.pointerLockState.isLocked;
    const bool visible = !locked && !_playToolsCursorHidden && (!cursorVisible || cursorVisible() != 0);
    const CGPoint mousePosition = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
    starrail::Point mouse{mousePosition.x, primaryTop - mousePosition.y};

    if (_lastView != view) {
        _pointer.update(false, true);
        _lastView = view;
    }
    const bool pointerInside = gameOwns && GameReceivesPointerAt(view, viewport, mouse);
    const bool shouldCenter = _pointer.update(gameOwns && (visible || locked || _playToolsCursorHidden || pointerInside), visible);
    if (shouldCenter && warp) {
        const auto spot = viewport.center();
        if (warp(CGPointMake(spot.x, spot.y)) == kCGErrorSuccess) {
            mouse = spot;
            if (_diagnosticsEnabled) NSLog(@"[StarRailDesktopMode] pointer centered");
        }
    }
    SRDMFlushMouse(gameOwns && !_playToolsCursorHidden && (locked || (!visible && pointerInside)),
                   _gain, (CAMetalLayer *)view.layer);
    RefreshCursor(gameOwns && visible && GameReceivesPointerAt(view, viewport, mouse));

    if (_diagnosticsEnabled && gameOwns && !_loggedViewport) {
        _loggedViewport = true;
        NSLog(@"[StarRailDesktopMode] viewport %.0fx%.0f", viewport.width, viewport.height);
    }
}

- (void)frame {
    if (!_diagnosticsOnly) [self updatePointer];
    if (!_diagnosticsEnabled) return;
    SRDMSampleGraphics((CAMetalLayer *)ForegroundMetalView().layer);
    if (!_loggedMouseRoute && SRDMHasGameMouseHandler()) {
        _loggedMouseRoute = true;
        NSLog(@"[StarRailDesktopMode] Unity installed a native mouse handler");
    }
}
@end

namespace {
void Activate() {
    static bool attempted = false;
    if (attempted) return;
    if (!HasVerifiedUnityImage()) {
        NSLog(@"[StarRailDesktopMode] Unity build does not match the CN-4.7.0 profile");
        return;
    }
    attempted = true;
    [[[SRDMPlayCoverHost alloc] init] start];
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
