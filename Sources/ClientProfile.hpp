#pragma once

#include <array>
#include <cstdint>
#include <string_view>

namespace starrail {

enum class ClientRegion { mainland, international };

struct ClientProfile {
    ClientRegion region;
    std::string_view bundleID;
    std::string_view version;
    std::string_view build;
    std::array<uint8_t, 16> unityUUID;
    uintptr_t stringNew;
    uint32_t stringNewInstruction;
    uintptr_t populateText;
    std::u16string_view loginVersionPrefix;
};

inline constexpr ClientProfile China470{
    ClientRegion::mainland, "com.miHoYo.hkrpg", "4.7.0", "1",
    {0x26, 0x4C, 0x6E, 0x79, 0x85, 0xC7, 0x30, 0x8E,
     0xB9, 0xF9, 0xCC, 0x36, 0xEF, 0x18, 0xAC, 0xBB},
    0xf2c7104, 0x14015d37, 0xf19c76c, u"CNPRODiOS4.7.0_D"
};

inline constexpr ClientProfile International470{
    ClientRegion::international, "com.HoYoverse.hkrpgoversea", "4.7.0", "1",
    {0xA5, 0x86, 0xE7, 0xD6, 0xDE, 0x70, 0x38, 0x24,
     0x90, 0x3E, 0x93, 0x6F, 0xFE, 0x2A, 0x79, 0x22},
    0xf2c60d4, 0x14015c89, 0xf19b7a0, u"OSPRODiOS4.7.0_D"
};

inline constexpr std::array SupportedClients{&China470, &International470};

inline const ClientProfile *FindClient(std::string_view bundleID, std::string_view version, std::string_view build,
                                       const std::array<uint8_t, 16> &uuid) {
    for (const auto *profile : SupportedClients) {
        if (bundleID == profile->bundleID && version == profile->version &&
            build == profile->build && uuid == profile->unityUUID) return profile;
    }
    return nullptr;
}

} // namespace starrail
