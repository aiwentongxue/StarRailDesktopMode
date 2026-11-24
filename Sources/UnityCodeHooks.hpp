// ARM64 entry hooks for the versioned Unity methods used by the graphics menu.
#pragma once

#include "ClientProfile.hpp"
#include <array>
#include <cstring>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>

namespace starrail {

inline bool SectionContains(const section_64 *section, uintptr_t address, size_t size) {
    return section && section->size >= size && address >= section->addr &&
           address - section->addr <= section->size - size;
}

inline bool CheckStringAllocator(const section_64 *text, intptr_t slide, const ClientProfile &client) {
    return SectionContains(text, client.stringNew, sizeof(uint32_t)) &&
           *reinterpret_cast<const uint32_t *>(slide + client.stringNew) == client.stringNewInstruction;
}

class UnityCodeHook {
public:
    using Instructions = std::array<uint32_t, 4>;

    UnityCodeHook(uintptr_t vmAddress, Instructions expected, uintptr_t replacement)
        : vmAddress_(vmAddress), expected_(expected), replacement_(Jump(replacement)) {}

    bool prepare(const section_64 &text, intptr_t slide) {
        if (!SectionContains(&text, vmAddress_, sizeof(expected_))) return false;
        const uintptr_t address = slide + vmAddress_;
        if ((address % vm_page_size) > vm_page_size - sizeof(expected_)) return false;
        entry_ = reinterpret_cast<void *>(address);
        if (std::memcmp(entry_, expected_.data(), sizeof(expected_)) != 0) return false;

        // These four signature-checked instructions do not use PC-relative addressing.
        const auto resume = Jump(address + sizeof(expected_));
        void *page = mmap(nullptr, vm_page_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (page == MAP_FAILED) return false;
        std::memcpy(page, expected_.data(), sizeof(expected_));
        std::memcpy(static_cast<char *>(page) + sizeof(expected_), resume.data(), sizeof(resume));
        sys_icache_invalidate(page, sizeof(expected_) + sizeof(resume));
        if (mprotect(page, vm_page_size, PROT_READ | PROT_EXEC) != 0) {
            munmap(page, vm_page_size);
            return false;
        }
        original_ = page;
        return true;
    }

    template <typename Function> Function original() const {
        return reinterpret_cast<Function>(original_);
    }

    bool install() { return write(replacement_, expected_); }
    bool restore() { return write(expected_, replacement_); }

    void release() {
        if (original_) munmap(original_, vm_page_size);
        original_ = nullptr;
    }

private:
    static Instructions Jump(uintptr_t address) {
        return {0x58000050, 0xd61f0200, static_cast<uint32_t>(address),
                static_cast<uint32_t>(address >> 32)};
    }

    bool write(const Instructions &instructions, const Instructions &rollback) {
        const auto task = mach_task_self();
        const auto page = reinterpret_cast<mach_vm_address_t>(entry_) & ~(vm_page_size - 1);
        const auto executable = VM_PROT_READ | VM_PROT_EXECUTE;
        if (mach_vm_protect(task, page, vm_page_size, false,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return false;
        std::memcpy(entry_, instructions.data(), sizeof(instructions));
        sys_icache_invalidate(entry_, sizeof(instructions));
        if (mach_vm_protect(task, page, vm_page_size, false, executable) == KERN_SUCCESS) return true;
        std::memcpy(entry_, rollback.data(), sizeof(rollback));
        sys_icache_invalidate(entry_, sizeof(rollback));
        mach_vm_protect(task, page, vm_page_size, false, executable);
        return false;
    }

    uintptr_t vmAddress_;
    Instructions expected_;
    Instructions replacement_;
    void *entry_ = nullptr;
    void *original_ = nullptr;
};

} // namespace starrail
