#import "Runtime.hpp"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "KeyboardState.hpp"
#include <array>
#include <cstring>

namespace {

template<class Result, class... Args>
Result Send(id object, const char *selector, Args... args) {
    return reinterpret_cast<Result (*)(id, SEL, Args...)>(objc_msgSend)(
        object, sel_registerName(selector), args...);
}

// UnityView.handleCommand: and processKeyboard
// use this native input function for both key-down and key-up. The original
// command path infers releases from a timeout because UIKeyCommand is not
// an edge-based keyboard API.
constexpr uintptr_t MainlandKeyEvent = 0x10ba2a98;
constexpr uintptr_t InternationalKeyEvent = 0x10ba2f80;
constexpr uintptr_t KeyCommandsOffset = 0x6c28;
constexpr std::array<uint32_t, 4> KeyEventPrologue{0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0103f4};
using KeyEvent = void (*)(int, int);
using KeyCommands = id (*)(id, SEL);
KeyEvent sendUnityKey;
KeyCommands originalKeyCommands;
id eventMonitor;
starrail::KeyState held;

void SendKey(uint16_t key, bool down) {
    sendUnityKey(key, down);
}

id GameKeyCommands(id view, SEL selector) {
    return SRDMGameAcceptsKeyboard() ? nil : originalKeyCommands(view, selector);
}

bool ModifierDown(uint16_t macKey, NSUInteger flags) {
    // NSEvent carries side-specific device masks in addition to the shared
    // Shift/Option/Control masks. Keep the two sides independent.
    switch (macKey) {
        case 56: return flags & 0x0002; // left Shift
        case 60: return flags & 0x0004; // right Shift
        case 58: return flags & 0x0020; // left Option
        case 61: return flags & 0x0040; // right Option
        case 59: return flags & 0x0001; // left Control
        case 62: return flags & 0x2000; // right Control
        case 57: return flags & (1UL << 16); // Caps Lock
        default: return false;
    }
}

id ReceiveEvent(id event) {
    constexpr NSUInteger KeyDown = 10;
    constexpr NSUInteger KeyUp = 11;
    constexpr NSUInteger FlagsChanged = 12;
    constexpr NSUInteger CommandMask = 1UL << 20;
    const auto type = Send<NSUInteger>(event, "type");
    if (type != KeyDown && type != KeyUp && type != FlagsChanged) return event;
    const auto macKey = Send<uint16_t>(event, "keyCode");
    const auto key = starrail::UnityKey(macKey);
    const auto flags = Send<NSUInteger>(event, "modifierFlags");

    if (!SRDMGameAcceptsKeyboard()) {
        held.releaseAll(SendKey);
        return event;
    }
    if (!key || key == 309 || key == 310) return event;
    if (type == FlagsChanged) {
        held.update(key, ModifierDown(macKey, flags), SendKey);
        return event;
    }
    if (type == KeyUp && held.pressed(key)) {
        held.update(key, false, SendKey);
        return nil;
    }
    if (flags & CommandMask) return event;
    if (type == KeyDown && !Send<BOOL>(event, "isARepeat")) held.update(key, true, SendKey);
    return nil;
}

} // namespace

bool SRDMInstallKeyboard(const mach_header_64 &image, intptr_t slide, const starrail::ClientProfile &client) {
    const uintptr_t keyEvent = client.region == starrail::ClientRegion::international ? InternationalKeyEvent : MainlandKeyEvent;
    const auto *text = SRDMFindSection(image, "__TEXT", "__text");
    if (!text || text->size < sizeof(KeyEventPrologue) || keyEvent < text->addr ||
        keyEvent - text->addr > text->size - sizeof(KeyEventPrologue)) return false;
    const auto *code = reinterpret_cast<const uint32_t *>(slide + keyEvent);
    if (std::memcmp(code, KeyEventPrologue.data(), sizeof(KeyEventPrologue)) != 0) return false;

    Method keyCommands = class_getInstanceMethod(NSClassFromString(@"UnityView"), sel_registerName("keyCommands"));
    Class events = NSClassFromString(@"NSEvent");
    const SEL addMonitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (!keyCommands || reinterpret_cast<uintptr_t>(method_getImplementation(keyCommands)) != slide + KeyCommandsOffset ||
        ![events respondsToSelector:addMonitor]) return false;

    constexpr uint64_t KeyboardEvents = (1ULL << 10) | (1ULL << 11) | (1ULL << 12);
    sendUnityKey = reinterpret_cast<KeyEvent>(slide + keyEvent);
    originalKeyCommands = reinterpret_cast<KeyCommands>(method_getImplementation(keyCommands));
    id (^handle)(id) = ^id(id event) { return ReceiveEvent(event); };
    eventMonitor = reinterpret_cast<id (*)(Class, SEL, uint64_t, id)>(objc_msgSend)(
        events, addMonitor, KeyboardEvents, handle);
    if (!eventMonitor) return false;
    method_setImplementation(keyCommands, reinterpret_cast<IMP>(GameKeyCommands));
    return true;
}

void SRDMReleaseKeyboard() {
    if (eventMonitor) held.releaseAll(SendKey);
}

bool SRDMSendMouseButton(unsigned button, bool down) {
    if (!eventMonitor || button >= 7) return false;
    sendUnityKey(static_cast<int>(323 + button), down); // Unity KeyCode.Mouse0 through Mouse6
    return true;
}
