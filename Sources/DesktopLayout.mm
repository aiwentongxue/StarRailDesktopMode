#import "Runtime.hpp"

#include <array>
#include <atomic>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace {

struct LayoutCheck {
    uint32_t address;
    uint32_t call;
    uint32_t branch;
};

// CN 4.7.0 build 1. The first two checks select the desktop presentation.
// The last enables the desktop input path for that presentation. All three
// originally call the same predicate. The game's platform value is unchanged.
constexpr std::array LayoutChecks{
    LayoutCheck{0x01d355a8, 0x97cf61d9, 0x37000160},
    LayoutCheck{0x01d3576c, 0x97cf6168, 0x37000160},
    LayoutCheck{0x0253eb60, 0x97af3c6b, 0x360000a0},
};
constexpr uint32_t TrueInResultRegister = 0x52800020; // mov w0, #1
constexpr uint32_t FalseInResultRegister = 0x52800000; // mov w0, #0

// These call sites skip the game cursor lifecycle on mobile. Keep the
// keyboard/mouse and controller checks after each predicate intact.
constexpr std::array CursorChecks{
    LayoutCheck{0x01d91ec4, 0x97cdef6a, 0x37000180},
    LayoutCheck{0x01d91fc4, 0x97cdef2a, 0x37000240},
    LayoutCheck{0x01d92164, 0x97cdeec2, 0x37000160},
    LayoutCheck{0x01d92204, 0x97cdee9a, 0x370004e0},
    LayoutCheck{0x01d924c0, 0x97cdedeb, 0x36000060},
};

// The managed Cursor methods dispatch through Unity's writable delegate table.
constexpr uintptr_t UnityCursorTable = 0x1656f118;
constexpr uintptr_t CursorVisibilityDelegate = 0x107c02e4;
constexpr uintptr_t CursorLockDelegate = 0x107c032c;
using CursorSetter = void (*)(int);
CursorSetter originalCursorVisibility;
CursorSetter originalCursorLock;
std::atomic<int> cursorVisibility{-1};
std::atomic<int> cursorLockMode{0};

void ObserveCursorVisibility(int value) {
    originalCursorVisibility(value);
    if (cursorVisibility.exchange(value != 0) != (value != 0)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"SRDMUnityCursorChanged" object:nil];
        });
    }
}

void ObserveCursorLock(int mode) {
    originalCursorLock(mode);
    if (cursorLockMode.exchange(mode) != mode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"SRDMUnityCursorChanged" object:nil];
        });
    }
}

} // namespace

const section_64 *SRDMFindSection(const mach_header_64 &header, const char *segmentName, const char *sectionName) {
    const auto *cursor = reinterpret_cast<const uint8_t *>(&header + 1);
    uint32_t remaining = header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds; ++i) {
        if (remaining < sizeof(load_command)) return nullptr;
        const auto *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize < sizeof(load_command) || command->cmdsize > remaining) return nullptr;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(segment_command_64)) {
            const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
            if (std::strncmp(segment->segname, segmentName, sizeof(segment->segname)) == 0) {
                const auto *sections = reinterpret_cast<const section_64 *>(segment + 1);
                const auto count = (command->cmdsize - sizeof(*segment)) / sizeof(*sections);
                if (segment->nsects > count) return nullptr;
                for (uint32_t section = 0; section < segment->nsects; ++section) {
                    if (std::strncmp(sections[section].sectname, sectionName, sizeof(sections[section].sectname)) == 0) {
                        return &sections[section];
                    }
                }
            }
        }
        cursor += command->cmdsize;
        remaining -= command->cmdsize;
    }
    return nullptr;
}

namespace {

kern_return_t ReplaceCall(uint32_t *word, uint32_t expected, uint32_t replacement) {
    if (*word != expected) return KERN_INVALID_ARGUMENT;
    const auto task = mach_task_self();
    const auto address = reinterpret_cast<mach_vm_address_t>(word);
    const auto page = address & ~(static_cast<mach_vm_address_t>(vm_page_size) - 1);
    const auto executable = VM_PROT_READ | VM_PROT_EXECUTE;
    auto status = mach_vm_protect(task, page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (status != KERN_SUCCESS) return status;

    __atomic_store_n(word, replacement, __ATOMIC_RELAXED);
    sys_icache_invalidate(word, sizeof(*word));
    status = mach_vm_protect(task, page, vm_page_size, false, executable);
    if (status != KERN_SUCCESS) {
        __atomic_store_n(word, expected, __ATOMIC_RELAXED);
        sys_icache_invalidate(word, sizeof(*word));
        if (mach_vm_protect(task, page, vm_page_size, false, executable) != KERN_SUCCESS) {
            NSLog(@"[StarRailDesktopMode] could not restore Unity code page permissions");
        }
    }
    return status;
}

template<size_t Count>
bool ApplyChecks(const mach_header_64 &verifiedImage, intptr_t slide,
                 const std::array<LayoutCheck, Count> &checks, uint32_t replacement) {
    const auto *code = SRDMFindSection(verifiedImage, "__TEXT", "__text");
    if (!code || code->size < 2 * sizeof(uint32_t)) return false;
    std::array<uint32_t *, Count> words{};
    for (size_t i = 0; i < Count; ++i) {
        const auto &check = checks[i];
        if (check.address < code->addr || check.address - code->addr > code->size - 2 * sizeof(uint32_t)) return false;
        auto *word = reinterpret_cast<uint32_t *>(slide + check.address);
        if (word[0] != check.call || word[1] != check.branch) {
            NSLog(@"[StarRailDesktopMode] Unity input check did not match at 0x%x", check.address);
            return false;
        }
        words[i] = word;
    }

    for (size_t i = 0; i < words.size(); ++i) {
        const auto status = ReplaceCall(words[i], checks[i].call, replacement);
        if (status == KERN_SUCCESS) continue;
        NSLog(@"[StarRailDesktopMode] Unity input change failed at 0x%x, status=%d",
              checks[i].address, status);
        for (size_t previous = i; previous > 0; --previous) {
            const auto index = previous - 1;
            if (ReplaceCall(words[index], replacement, checks[index].call) != KERN_SUCCESS) {
                NSLog(@"[StarRailDesktopMode] could not restore Unity input call at 0x%x", checks[index].address);
            }
        }
        return false;
    }
    return true;
}

} // namespace

bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide) {
    return ApplyChecks(verifiedImage, slide, LayoutChecks, TrueInResultRegister);
}

bool SRDMEnableDesktopCursor(const mach_header_64 &verifiedImage, intptr_t slide) {
    const auto *data = SRDMFindSection(verifiedImage, "__DATA", "__common");
    constexpr size_t tableSize = 4 * sizeof(uintptr_t);
    if (!data || data->size < tableSize || UnityCursorTable < data->addr ||
        UnityCursorTable - data->addr > data->size - tableSize) return false;
    auto *slots = reinterpret_cast<uintptr_t *>(slide + UnityCursorTable);
    if (slots[1] != slide + CursorVisibilityDelegate || slots[3] != slide + CursorLockDelegate) return false;
    if (!ApplyChecks(verifiedImage, slide, CursorChecks, FalseInResultRegister)) return false;
    originalCursorVisibility = reinterpret_cast<CursorSetter>(slots[1]);
    originalCursorLock = reinterpret_cast<CursorSetter>(slots[3]);
    __atomic_store_n(slots + 1, reinterpret_cast<uintptr_t>(ObserveCursorVisibility), __ATOMIC_RELEASE);
    __atomic_store_n(slots + 3, reinterpret_cast<uintptr_t>(ObserveCursorLock), __ATOMIC_RELEASE);
    return true;
}

SRDMUnityCursorState SRDMRequestedCursor() {
    const int visible = cursorVisibility.load();
    return {visible >= 0, visible != 0, cursorLockMode.load() == 1};
}
