#import "Runtime.hpp"
#import <GameController/GameController.h>
#import <objc/runtime.h>

#include "DesktopState.hpp"
#include <atomic>
#include <dlfcn.h>
#include <mutex>

@interface SRDMMouseBinding : NSObject {
@public
    __weak GCMouseInput *input;
    GCMouseMoved forward;
    starrail::RelativeMotion pending;
    bool valid;
    bool scheduled;
}
@end
@implementation SRDMMouseBinding
@end

namespace {

using Setter = void (*)(GCMouseInput *, SEL, GCMouseMoved);
Setter originalSetter;
std::mutex stateLock;
NSHashTable<SRDMMouseBinding *> *bindings;
bool cameraActive;
uint64_t cameraRevision;
char associationKey;
using NextDrawable = id<CAMetalDrawable> (*)(CAMetalLayer *, SEL);
NextDrawable originalNextDrawable;
std::atomic<const void *> cameraLayer;
std::atomic<uint64_t> renderedFrame;
uint64_t lastFlushedFrame;

id<CAMetalDrawable> ObserveFrame(CAMetalLayer *layer, SEL selector) {
    auto drawable = originalNextDrawable(layer, selector);
    if (drawable && cameraLayer.load(std::memory_order_relaxed) == (__bridge const void *)layer) {
        renderedFrame.fetch_add(1, std::memory_order_relaxed);
    }
    return drawable;
}

__attribute__((noinline)) void SetMouseHandler(GCMouseInput *input, SEL selector, GCMouseMoved handler) {
    Dl_info caller{};
    const void *returnAddress = __builtin_extract_return_addr(__builtin_return_address(0));
    const bool fromGame = dladdr(returnAddress, &caller) && caller.dli_fname &&
        std::string_view(caller.dli_fname).ends_with("/UnityFramework.framework/UnityFramework");

    {
        std::lock_guard lock(stateLock);
        SRDMMouseBinding *previous = objc_getAssociatedObject(input, &associationKey);
        if (previous) previous->valid = false;
    }

    if (!handler || !fromGame) {
        originalSetter(input, selector, handler);
        objc_setAssociatedObject(input, &associationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    SRDMMouseBinding *binding = [SRDMMouseBinding new];
    binding->input = input;
    binding->forward = [handler copy];
    binding->valid = true;
    objc_setAssociatedObject(input, &associationKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    {
        std::lock_guard lock(stateLock);
        [bindings addObject:binding];
    }
    originalSetter(input, selector, ^(GCMouseInput *source, float dx, float dy) {
        {
            std::lock_guard lock(stateLock);
            if (!binding->valid) return;
            if (cameraActive) {
                binding->pending.add(dx, dy);
                return;
            }
        }
        binding->forward(source, dx, dy);
    });
}

} // namespace

bool SRDMInstallMouseSampling(void) {
    Method method = class_getInstanceMethod(GCMouseInput.class, @selector(setMouseMovedHandler:));
    Method nextDrawable = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (!method || !nextDrawable) return false;
    bindings = NSHashTable.weakObjectsHashTable;
    originalSetter = reinterpret_cast<Setter>(method_getImplementation(method));
    method_setImplementation(method, (IMP)SetMouseHandler);
    originalNextDrawable = reinterpret_cast<NextDrawable>(method_getImplementation(nextDrawable));
    method_setImplementation(nextDrawable, (IMP)ObserveFrame);
    return true;
}

bool SRDMHasGameMouseHandler(void) {
    std::lock_guard lock(stateLock);
    for (SRDMMouseBinding *binding in bindings) {
        if (binding->valid && binding->input) return true;
    }
    return false;
}

void SRDMFlushMouse(bool active, double gain, CAMetalLayer *layer) {
    if (!bindings) return;
    cameraLayer.store(active ? (__bridge const void *)layer : nullptr, std::memory_order_relaxed);
    std::lock_guard lock(stateLock);
    if (active != cameraActive) {
        cameraActive = active;
        ++cameraRevision;
        lastFlushedFrame = renderedFrame.load(std::memory_order_relaxed);
    }
    const auto frame = renderedFrame.load(std::memory_order_relaxed);
    if (active && frame == lastFlushedFrame) return;
    lastFlushedFrame = frame;
    NSArray<GCMouse *> *mice = active && bindings.count ? GCMouse.mice : nil;
    for (SRDMMouseBinding *binding in bindings) {
        if (!active) {
            binding->pending.take(0);
            continue;
        }
        GCMouseInput *input = binding->input;
        if (!binding->valid || !input || binding->scheduled) continue;
        const auto delta = binding->pending.take(gain);
        if (delta.x == 0 && delta.y == 0) continue;

        dispatch_queue_t queue = dispatch_get_main_queue();
        for (GCMouse *mouse in mice) {
            if (mouse.mouseInput == input) {
                queue = mouse.handlerQueue ?: queue;
                break;
            }
        }
        const auto revision = cameraRevision;
        binding->scheduled = true;
        dispatch_async(queue, ^{
            {
                std::lock_guard innerLock(stateLock);
                binding->scheduled = false;
                if (!binding->valid || !cameraActive || revision != cameraRevision) return;
            }
            binding->forward(input, static_cast<float>(delta.x), static_cast<float>(delta.y));
        });
    }
}
