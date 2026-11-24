#import "Runtime.hpp"
#import <objc/message.h>

#include "DesktopState.hpp"
#include "UnityCodeHooks.hpp"
#include <array>
#include <bitset>
#include <cstring>
#include <mutex>
#include <string_view>

namespace {

struct InputDelegates {
    uintptr_t axisTable;
    uintptr_t axis;
    uintptr_t rawAxis;
    uintptr_t presenceSlot;
    uintptr_t presence;
    uintptr_t positionSlot;
    uintptr_t position;
    uintptr_t scrollSlot;
    uintptr_t scroll;
    uintptr_t frameCountWrapper;
    uintptr_t frameCountSlot;
    uintptr_t frameCount;
    std::array<uint32_t, 4> frameCountWords;
};

constexpr InputDelegates MainlandInput{
    0x1656e038, 0x100c6724, 0x100c68a4, 0x1656e0e0, 0x100c7900,
    0x1656e178, 0x100c75fc, 0x1656e180, 0x100c76bc,
    0x0f145a20, 0x165729f0, 0x107d5750, {0x9003a148, 0x910ac108, 0xf96ba100, 0xd61f0000}
};

constexpr InputDelegates InternationalInput{
    0x1664cca0, 0x100c6b54, 0x100c6cd4, 0x1664cd48, 0x100c7d30,
    0x1664cde0, 0x100c7a2c, 0x1664cde8, 0x100c7aec,
    0x0f144a78, 0x166526a8, 0x107d5b80, {0xf003a828, 0x913c6108, 0xf973c900, 0xd61f0000}
};

struct UnityString {
    uintptr_t type;
    uintptr_t monitor;
    int32_t length;
    char16_t characters[1];
};

using AxisGetter = float (*)(const UnityString *);
using FrameGetter = uint32_t (*)();
using VectorGetter = void (*)(float *);
AxisGetter originalAxis;
AxisGetter originalRawAxis;
FrameGetter frameCount;
VectorGetter originalScroll;
VectorGetter originalPosition;
bool radialPositionEnabled;
CGPoint radialPosition;
id mouseMonitor;

std::mutex motionLock;
starrail::FrameMotion motion;
starrail::FrameMotion scroll;
bool captured;
double gain;
double captureStarted;
std::bitset<7> mouseButtons;

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

void GetMousePosition(float *output) {
    {
        std::lock_guard lock(motionLock);
        if (radialPositionEnabled) {
            output[0] = static_cast<float>(radialPosition.x);
            output[1] = static_cast<float>(radialPosition.y);
            output[2] = 0;
            return;
        }
    }
    originalPosition(output);
}

void GetScrollDelta(float *output) {
    {
        std::lock_guard lock(motionLock);
        if (captured && !SRDMRequestedCursor().visible) {
            const auto delta = scroll.sample(frameCount(), 1);
            output[0] = static_cast<float>(delta.x);
            output[1] = static_cast<float>(delta.y);
            return;
        }
    }
    originalScroll(output);
}

id ReceiveScroll(id event) {
    if (!SRDMGameAcceptsKeyboard()) return event;
    std::lock_guard lock(motionLock);
    if (!captured || SRDMRequestedCursor().visible) return event;
    const bool precise = ReadEvent<BOOL>(event, "hasPreciseScrollingDeltas");
    const double multiplier = precise ? 1.0 / 16.0 : 1.0;
    scroll.add(ReadEvent<CGFloat>(event, "scrollingDeltaX") * multiplier,
               ReadEvent<CGFloat>(event, "scrollingDeltaY") * multiplier);
    return nil;
}

void Accumulate(id event) {
    std::lock_guard lock(motionLock);
    if (!captured || ReadEvent<double>(event, "timestamp") < captureStarted) return;
    const auto dx = ReadEvent<CGFloat>(event, "deltaX");
    const auto dy = ReadEvent<CGFloat>(event, "deltaY");
    motion.add(dx, -dy);
}

id ReceiveEvent(id event) {
    const auto type = ReadEvent<NSUInteger>(event, "type");
    if (type == 22) return ReceiveScroll(event);
    const bool down = type == 1 || type == 3 || type == 25;
    const bool up = type == 2 || type == 4 || type == 26;
    if (!down && !up) {
        Accumulate(event);
        return event;
    }
    // The monitor and capture changes both run on the main thread.
    if (!captured || SRDMRequestedCursor().visible) return event;
    const auto button = ReadEvent<NSUInteger>(event, "buttonNumber");
    if (button >= mouseButtons.size()) return event;
    if (mouseButtons[button] != down) {
        if (!SRDMSendMouseButton(static_cast<unsigned>(button), down)) return event;
        mouseButtons[button] = down;
    }
    return nil;
}

} // namespace

bool SRDMInstallMouse(const mach_header_64 &image, intptr_t slide, const starrail::ClientProfile &client,
                     bool &radialPositionInstalled) {
    using starrail::SectionContains;
    radialPositionInstalled = false;
    const auto &delegates = client.region == starrail::ClientRegion::international ? InternationalInput : MainlandInput;
    const auto *text = SRDMFindSection(image, "__TEXT", "__text");
    const auto *data = SRDMFindSection(image, "__DATA", "__common");
    if (!SectionContains(text, delegates.frameCountWrapper, sizeof(delegates.frameCountWords)) ||
        !SectionContains(data, delegates.axisTable, 2 * sizeof(uintptr_t)) ||
        !SectionContains(data, delegates.presenceSlot, sizeof(uintptr_t)) ||
        !SectionContains(data, delegates.scrollSlot, sizeof(uintptr_t)) ||
        !SectionContains(data, delegates.frameCountSlot, sizeof(uintptr_t)) ||
        std::memcmp(reinterpret_cast<const void *>(slide + delegates.frameCountWrapper),
                    delegates.frameCountWords.data(), sizeof(delegates.frameCountWords)) != 0) return false;
    auto *axes = reinterpret_cast<uintptr_t *>(slide + delegates.axisTable);
    auto *presence = reinterpret_cast<uintptr_t *>(slide + delegates.presenceSlot);
    auto *wheel = reinterpret_cast<uintptr_t *>(slide + delegates.scrollSlot);
    const auto frameTarget = *reinterpret_cast<const uintptr_t *>(slide + delegates.frameCountSlot);
    if (axes[0] != slide + delegates.axis || axes[1] != slide + delegates.rawAxis ||
        *presence != slide + delegates.presence || *wheel != slide + delegates.scroll ||
        frameTarget != slide + delegates.frameCount) return false;

    Class events = NSClassFromString(@"NSEvent");
    const SEL addMonitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (![events respondsToSelector:addMonitor]) return false;
    constexpr uint64_t MotionEvents = (1ULL << 5) | (1ULL << 6) | (1ULL << 7) | (1ULL << 27);
    constexpr uint64_t ButtonEvents = (1ULL << 1) | (1ULL << 2) | (1ULL << 3) |
                                      (1ULL << 4) | (1ULL << 25) | (1ULL << 26);
    constexpr uint64_t ScrollEvent = 1ULL << 22;
    id (^handle)(id) = ^id(id event) { return ReceiveEvent(event); };
    mouseMonitor = reinterpret_cast<id (*)(Class, SEL, uint64_t, id)>(objc_msgSend)(
        events, addMonitor, MotionEvents | ButtonEvents | ScrollEvent, handle);
    if (!mouseMonitor) return false;

    originalAxis = reinterpret_cast<AxisGetter>(axes[0]);
    originalRawAxis = reinterpret_cast<AxisGetter>(axes[1]);
    frameCount = reinterpret_cast<FrameGetter>(frameTarget);
    originalScroll = reinterpret_cast<VectorGetter>(*wheel);
    __atomic_store_n(axes, reinterpret_cast<uintptr_t>(GetAxis), __ATOMIC_RELEASE);
    __atomic_store_n(axes + 1, reinterpret_cast<uintptr_t>(GetAxisRaw), __ATOMIC_RELEASE);
    __atomic_store_n(presence, reinterpret_cast<uintptr_t>(GetMousePresent), __ATOMIC_RELEASE);
    __atomic_store_n(wheel, reinterpret_cast<uintptr_t>(GetScrollDelta), __ATOMIC_RELEASE);
    if (SectionContains(data, delegates.positionSlot, sizeof(uintptr_t)) &&
        SectionContains(text, delegates.position, sizeof(uint32_t))) {
        auto *position = reinterpret_cast<uintptr_t *>(slide + delegates.positionSlot);
        if (*position == slide + delegates.position) {
            originalPosition = reinterpret_cast<VectorGetter>(*position);
            __atomic_store_n(position, reinterpret_cast<uintptr_t>(GetMousePosition), __ATOMIC_RELEASE);
            radialPositionInstalled = true;
        }
    }
    return true;
}

void SRDMSetCameraMouseCapture(bool enabled, double sensitivity, CGPoint warp) {
    if (!mouseMonitor) return;
    {
        std::lock_guard lock(motionLock);
        gain = sensitivity * PointsToAxis;
        if (enabled == captured) return;
        captured = enabled;
        captureStarted = NSProcessInfo.processInfo.systemUptime;
        motion.reset({warp.x, warp.y});
        scroll.reset();
    }
    if (!enabled && mouseButtons.any()) {
        for (unsigned button = 0; button < mouseButtons.size(); ++button) {
            if (mouseButtons[button]) SRDMSendMouseButton(button, false);
        }
        mouseButtons.reset();
    }
}

void SRDMSetRadialPosition(bool enabled, CGPoint pixels) {
    if (!originalPosition) return;
    std::lock_guard lock(motionLock);
    radialPositionEnabled = enabled;
    radialPosition = pixels;
}
