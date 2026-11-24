#import "Runtime.hpp"

#include "UnityCodeHooks.hpp"
#include <string_view>

namespace {

constexpr std::u16string_view Platform = u"iOS";
constexpr size_t StringLengthOffset = 0x10;
constexpr size_t StringCharactersOffset = 0x14;
struct TextGenerationSettings;
struct MethodInfo;
using Populate = bool (*)(void *, void *, const TextGenerationSettings *, uint32_t *, const MethodInfo *);
using StringFactory = void *(*)(const char *);
Populate originalPopulate;
StringFactory createString;
std::u16string_view badgePrefix;
size_t platformIndex;

void *macOSLabel(const void *value) {
    if (!value) return nullptr;
    const auto *data = static_cast<const char *>(value);
    const auto length = *reinterpret_cast<const int32_t *>(data + StringLengthOffset);
    if (length < static_cast<int32_t>(badgePrefix.size()) || length > 256) return nullptr;
    const auto *characters = reinterpret_cast<const char16_t *>(data + StringCharactersOffset);
    const size_t offset = std::u16string_view(characters, length).find(badgePrefix);
    if (offset == std::u16string_view::npos) return nullptr;

    NSString *label = [NSString stringWithCharacters:reinterpret_cast<const unichar *>(characters) length:length];
    NSString *updated = [label stringByReplacingCharactersInRange:NSMakeRange(offset + platformIndex, Platform.size())
                                                       withString:@"macOS"];
    const char *utf8 = updated.UTF8String;
    return utf8 ? createString(utf8) : nullptr;
}

// TextGenerator.Populate_Internal receives the final display string, including any UID.
bool populate(void *generator, void *value, const TextGenerationSettings *settings,
              uint32_t *error, const MethodInfo *method) {
    void *replacement = macOSLabel(value);
    return originalPopulate(generator, replacement ?: value, settings, error, method);
}

} // namespace

bool SRDMInstallLoginVersionLabel(const mach_header_64 &header, intptr_t slide, const starrail::ClientProfile &client) {
    const auto *text = SRDMFindSection(header, "__TEXT", "__text");
    const size_t index = client.loginVersionPrefix.find(Platform);
    if (index == std::u16string_view::npos || !starrail::CheckStringAllocator(text, slide, client)) return false;

    starrail::UnityCodeHook hook(client.populateText, {0xd10643ff, 0x6d0f3bef, 0x6d1033ed, 0x6d112beb},
                                reinterpret_cast<uintptr_t>(populate));
    if (!hook.prepare(*text, slide)) return false;
    badgePrefix = client.loginVersionPrefix;
    platformIndex = index;
    originalPopulate = hook.original<Populate>();
    createString = reinterpret_cast<StringFactory>(slide + client.stringNew);
    if (hook.install()) return true;
    hook.release();
    return false;
}
