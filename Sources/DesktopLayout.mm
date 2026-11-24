#import "Runtime.hpp"

#include <array>
#include <atomic>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace {

struct InstructionChange {
    uint32_t address;
    uint32_t original;
    uint32_t following;
    uint32_t replacement;
};

constexpr uint32_t TrueInResultRegister = 0x52800020; // mov w0, #1
constexpr uint32_t FalseInResultRegister = 0x52800000; // mov w0, #0
constexpr uint32_t NoOperation = 0xd503201f; // nop

// Enable the desktop input path and presentation at
// their call sites, preserving the game's platform value.
constexpr std::array MainlandLayout{
    InstructionChange{0x01d355a8, 0x97cf61d9, 0x37000160, TrueInResultRegister},
    InstructionChange{0x01d3576c, 0x97cf6168, 0x37000160, TrueInResultRegister},
    InstructionChange{0x0253eb60, 0x97af3c6b, 0x360000a0, TrueInResultRegister},
    // Keep the EventSystem navigation defaults during mobile initialization.
    // Subsequent game updates can still change navigation for individual menus.
    InstructionChange{0x019e13b4, 0x3900c01f, 0x958ce4ae, NoOperation},
    InstructionChange{0x019e13c0, 0x3900c41f, 0xa9427bfd, NoOperation},
};

constexpr std::array InternationalLayout{
    InstructionChange{0x01d39b50, 0x97cf5ca5, 0x37000160, TrueInResultRegister},
    InstructionChange{0x01d39d14, 0x97cf5c34, 0x37000160, TrueInResultRegister},
    InstructionChange{0x02543b38, 0x97af34ab, 0x360000a0, TrueInResultRegister},
    InstructionChange{0x019e56a4, 0x3900c01f, 0x958cd44f, NoOperation},
    InstructionChange{0x019e56b0, 0x3900c41f, 0xa9427bfd, NoOperation},
};

// These call sites skip the game cursor lifecycle on mobile. Keep the
// keyboard/mouse and controller checks after each predicate intact.
constexpr std::array MainlandCursor{
    InstructionChange{0x01d91ec4, 0x97cdef6a, 0x37000180, FalseInResultRegister},
    InstructionChange{0x01d91fc4, 0x97cdef2a, 0x37000240, FalseInResultRegister},
    InstructionChange{0x01d92164, 0x97cdeec2, 0x37000160, FalseInResultRegister},
    InstructionChange{0x01d92204, 0x97cdee9a, 0x370004e0, FalseInResultRegister},
    InstructionChange{0x01d924c0, 0x97cdedeb, 0x36000060, FalseInResultRegister},
};

constexpr std::array InternationalCursor{
    InstructionChange{0x01d9646c, 0x97cdea36, 0x37000180, FalseInResultRegister},
    InstructionChange{0x01d9656c, 0x97cde9f6, 0x37000240, FalseInResultRegister},
    InstructionChange{0x01d9670c, 0x97cde98e, 0x37000160, FalseInResultRegister},
    InstructionChange{0x01d967ac, 0x97cde966, 0x370004e0, FalseInResultRegister},
    InstructionChange{0x01d96a68, 0x97cde8b7, 0x36000060, FalseInResultRegister},
};

// The managed Cursor methods dispatch through Unity's writable delegate table.
struct CursorDelegates {
    uintptr_t table;
    uintptr_t visibility;
    uintptr_t lock;
};
constexpr CursorDelegates MainlandDelegates{0x1656f118, 0x107c02e4, 0x107c032c};
constexpr CursorDelegates InternationalDelegates{0x1664dd80, 0x107c0714, 0x107c075c};
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

kern_return_t ReplaceInstruction(uint32_t *word, uint32_t expected, uint32_t replacement) {
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
bool ApplyChanges(const mach_header_64 &verifiedImage, intptr_t slide,
                  const std::array<InstructionChange, Count> &changes) {
    const auto *code = SRDMFindSection(verifiedImage, "__TEXT", "__text");
    if (!code || code->size < 2 * sizeof(uint32_t)) return false;
    std::array<uint32_t *, Count> words{};
    for (size_t i = 0; i < Count; ++i) {
        const auto &check = changes[i];
        if (check.address < code->addr || check.address - code->addr > code->size - 2 * sizeof(uint32_t)) return false;
        auto *word = reinterpret_cast<uint32_t *>(slide + check.address);
        if (word[0] != check.original || word[1] != check.following) {
            NSLog(@"[StarRailDesktopMode] Unity input check did not match at 0x%x", check.address);
            return false;
        }
        words[i] = word;
    }

    for (size_t i = 0; i < words.size(); ++i) {
        const auto status = ReplaceInstruction(words[i], changes[i].original, changes[i].replacement);
        if (status == KERN_SUCCESS) continue;
        NSLog(@"[StarRailDesktopMode] Unity input change failed at 0x%x, status=%d",
              changes[i].address, status);
        for (size_t previous = i; previous > 0; --previous) {
            const auto index = previous - 1;
            if (ReplaceInstruction(words[index], changes[index].replacement, changes[index].original) != KERN_SUCCESS) {
                NSLog(@"[StarRailDesktopMode] could not restore Unity input instruction at 0x%x", changes[index].address);
            }
        }
        return false;
    }
    return true;
}

} // namespace

bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client) {
    const auto &changes = client.region == starrail::ClientRegion::international ? InternationalLayout : MainlandLayout;
    return ApplyChanges(verifiedImage, slide, changes);
}

bool SRDMEnableDesktopCursor(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client) {
    const bool international = client.region == starrail::ClientRegion::international;
    const auto &delegates = international ? InternationalDelegates : MainlandDelegates;
    const auto *data = SRDMFindSection(verifiedImage, "__DATA", "__common");
    constexpr size_t tableSize = 4 * sizeof(uintptr_t);
    if (!data || data->size < tableSize || delegates.table < data->addr ||
        delegates.table - data->addr > data->size - tableSize) return false;
    auto *slots = reinterpret_cast<uintptr_t *>(slide + delegates.table);
    if (slots[1] != slide + delegates.visibility || slots[3] != slide + delegates.lock) return false;
    if (!ApplyChanges(verifiedImage, slide, international ? InternationalCursor : MainlandCursor)) return false;
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
