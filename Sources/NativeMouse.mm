#import "Runtime.hpp"
#import <objc/message.h>

#include "DesktopState.hpp"
#include <array>
#include <cstring>
#include <mutex>
#include <string_view>

namespace {

// CN 4.7.0 build 1 dispatches Input.GetAxis and Input.GetAxisRaw here.
constexpr uintptr_t AxisTable = 0x1656e038;
constexpr uintptr_t GetAxisTarget = 0x100c6724;
constexpr uintptr_t GetAxisRawTarget = 0x100c68a4;
constexpr uintptr_t MousePresentSlot = 0x1656e0e0;
constexpr uintptr_t MousePresentTarget = 0x100c7900;
constexpr uintptr_t FrameCountWrapper = 0x0f145a20;
constexpr uintptr_t FrameCountSlot = 0x165729f0;
constexpr uintptr_t FrameCountTarget = 0x107d5750;
constexpr std::array<uint32_t, 4> FrameCountWords{0x9003a148, 0x910ac108, 0xf96ba100, 0xd61f0000};

struct UnityString {
    uintptr_t type;
    uintptr_t monitor;
    int32_t length;
    char16_t characters[1];
};

using AxisGetter = float (*)(const UnityString *);
using FrameGetter = uint32_t (*)();
AxisGetter originalAxis;
AxisGetter originalRawAxis;
FrameGetter frameCount;
id mouseMonitor;

std::mutex motionLock;
starrail::FrameMotion motion;
bool captured;
double gain;

// The client applies its in-game camera sensitivity after this conversion.
constexpr double PointsToAxis = 0.25;

template<class Result>
Result ReadEvent(id event, const char *selector) {
    return reinterpret_cast<Result (*)(id, SEL)>(objc_msgSend)(event, sel_registerName(selector));
}

enum class Axis { other, x, y };

Axis MouseAxis(const UnityString *name) {
    if (!name || name->length != 7) return Axis::other;
    // The runtime allocates inline UTF-16 storage after the length field.
    const auto *characters = reinterpret_cast<const char16_t *>(
        reinterpret_cast<const uint8_t *>(name) + offsetof(UnityString, characters));
    const std::u16string_view text(characters, name->length);
    if (text == u"mouse x" || text == u"Mouse X") return Axis::x;
    if (text == u"mouse y" || text == u"Mouse Y") return Axis::y;
    return Axis::other;
}

float ReadAxis(const UnityString *name, AxisGetter original) {
    const auto axis = MouseAxis(name);
    if (axis != Axis::other) {
        std::lock_guard lock(motionLock);
        if (captured) {
            const auto cursor = SRDMRequestedCursor();
            if (cursor.known && cursor.visible) return 0;
            const auto frame = frameCount();
            const auto value = motion.sample(frame, gain);
            return static_cast<float>(axis == Axis::x ? value.x : value.y);
        }
    }
    return original(name);
}

float GetAxis(const UnityString *name) { return ReadAxis(name, originalAxis); }
float GetAxisRaw(const UnityString *name) { return ReadAxis(name, originalRawAxis); }

bool GetMousePresent() {
    return true;
}

void Accumulate(id event) {
    std::lock_guard lock(motionLock);
    if (!captured) return;
    const auto dx = ReadEvent<CGFloat>(event, "deltaX");
    const auto dy = ReadEvent<CGFloat>(event, "deltaY");
    motion.add(dx, -dy);
}

bool Contains(const section_64 *section, uintptr_t offset, size_t size) {
    return section && section->size >= size && offset >= section->addr &&
           offset - section->addr <= section->size - size;
}

} // namespace

bool SRDMInstallMouse(const mach_header_64 &image, intptr_t slide) {
    const auto *text = SRDMFindSection(image, "__TEXT", "__text");
    const auto *data = SRDMFindSection(image, "__DATA", "__common");
    if (!Contains(text, FrameCountWrapper, sizeof(FrameCountWords)) ||
        !Contains(data, AxisTable, 2 * sizeof(uintptr_t)) ||
        !Contains(data, MousePresentSlot, sizeof(uintptr_t)) ||
        !Contains(data, FrameCountSlot, sizeof(uintptr_t)) ||
        std::memcmp(reinterpret_cast<const void *>(slide + FrameCountWrapper),
                    FrameCountWords.data(), sizeof(FrameCountWords)) != 0) return false;
    auto *axes = reinterpret_cast<uintptr_t *>(slide + AxisTable);
    auto *presence = reinterpret_cast<uintptr_t *>(slide + MousePresentSlot);
    const auto frameTarget = *reinterpret_cast<const uintptr_t *>(slide + FrameCountSlot);
    if (axes[0] != slide + GetAxisTarget || axes[1] != slide + GetAxisRawTarget ||
        *presence != slide + MousePresentTarget ||
        frameTarget != slide + FrameCountTarget) return false;

    Class events = NSClassFromString(@"NSEvent");
    const SEL addMonitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (![events respondsToSelector:addMonitor]) return false;
    constexpr uint64_t MotionEvents = (1ULL << 5) | (1ULL << 6) | (1ULL << 7) | (1ULL << 27);
    id (^handle)(id) = ^id(id event) {
        Accumulate(event);
        return event;
    };
    mouseMonitor = reinterpret_cast<id (*)(Class, SEL, uint64_t, id)>(objc_msgSend)(
        events, addMonitor, MotionEvents, handle);
    if (!mouseMonitor) return false;

    originalAxis = reinterpret_cast<AxisGetter>(axes[0]);
    originalRawAxis = reinterpret_cast<AxisGetter>(axes[1]);
    frameCount = reinterpret_cast<FrameGetter>(frameTarget);
    __atomic_store_n(axes, reinterpret_cast<uintptr_t>(GetAxis), __ATOMIC_RELEASE);
    __atomic_store_n(axes + 1, reinterpret_cast<uintptr_t>(GetAxisRaw), __ATOMIC_RELEASE);
    __atomic_store_n(presence, reinterpret_cast<uintptr_t>(GetMousePresent), __ATOMIC_RELEASE);
    return true;
}

void SRDMSetCameraMouseCapture(bool enabled, double sensitivity) {
    if (!mouseMonitor) return;
    std::lock_guard lock(motionLock);
    gain = sensitivity * PointsToAxis;
    if (enabled == captured) return;
    captured = enabled;
    motion.reset();
}
