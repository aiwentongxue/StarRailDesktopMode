#import "Runtime.hpp"

#include <array>
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

const section_64 *FindCodeSection(const mach_header_64 &header) {
    const auto *cursor = reinterpret_cast<const uint8_t *>(&header + 1);
    uint32_t remaining = header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds; ++i) {
        if (remaining < sizeof(load_command)) return nullptr;
        const auto *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize < sizeof(load_command) || command->cmdsize > remaining) return nullptr;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(segment_command_64)) {
            const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
            if (std::strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                const auto *sections = reinterpret_cast<const section_64 *>(segment + 1);
                const auto count = (command->cmdsize - sizeof(*segment)) / sizeof(*sections);
                if (segment->nsects > count) return nullptr;
                for (uint32_t section = 0; section < segment->nsects; ++section) {
                    if (std::strncmp(sections[section].sectname, "__text", sizeof(sections[section].sectname)) == 0) {
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

} // namespace

bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide) {
    const auto *code = FindCodeSection(verifiedImage);
    if (!code || code->size < 2 * sizeof(uint32_t)) return false;
    std::array<uint32_t *, LayoutChecks.size()> words{};
    for (size_t i = 0; i < LayoutChecks.size(); ++i) {
        const auto &check = LayoutChecks[i];
        if (check.address < code->addr || check.address - code->addr > code->size - 2 * sizeof(uint32_t)) return false;
        auto *word = reinterpret_cast<uint32_t *>(slide + check.address);
        if (word[0] != check.call || word[1] != check.branch) {
            NSLog(@"[StarRailDesktopMode] desktop layout check did not match at 0x%x", check.address);
            return false;
        }
        words[i] = word;
    }

    for (size_t i = 0; i < words.size(); ++i) {
        const auto status = ReplaceCall(words[i], LayoutChecks[i].call, TrueInResultRegister);
        if (status == KERN_SUCCESS) continue;
        NSLog(@"[StarRailDesktopMode] desktop layout change failed at 0x%x, status=%d",
              LayoutChecks[i].address, status);
        for (size_t previous = i; previous > 0; --previous) {
            const auto index = previous - 1;
            if (ReplaceCall(words[index], TrueInResultRegister, LayoutChecks[index].call) != KERN_SUCCESS) {
                NSLog(@"[StarRailDesktopMode] could not restore desktop layout call at 0x%x", LayoutChecks[index].address);
            }
        }
        return false;
    }
    return true;
}
