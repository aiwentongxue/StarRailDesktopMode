#pragma once

#include <array>
#include <bitset>
#include <cstdint>

namespace starrail {

// AppKit virtual key codes to Unity KeyCode. Keep these physical mappings
// independent of Shift, the current keyboard layout, and IME composition.
inline constexpr std::array<uint16_t, 128> MacKeys{
    'a', 's', 'd', 'f', 'h', 'g', 'z', 'x', 'c', 'v', 0, 'b', 'q', 'w', 'e', 'r',
    'y', 't', '1', '2', '3', '4', '6', '5', '=', '9', '7', '-', '8', '0', ']', 'o',
    'u', '[', 'i', 'p', 13, 'l', 'j', '\'', 'k', ';', '\\', ',', '/', 'n', 'm', '.',
    9, ' ', '`', 8, 0, 27, 309, 310, 304, 301, 308, 306, 303, 307, 305, 0,
    671, 266, 0, 268, 0, 270, 0, 300, 0, 0, 0, 267, 271, 0, 269, 672,
    673, 272, 256, 257, 258, 259, 260, 261, 262, 263, 674, 264, 265, 0, 0, 0,
    286, 287, 288, 284, 289, 290, 0, 292, 0, 294, 670, 295, 0, 291, 0, 293,
    0, 296, 315, 278, 280, 127, 285, 279, 283, 281, 282, 276, 275, 274, 273, 0,
};

inline constexpr uint16_t UnityKey(uint16_t macKey) {
    return macKey < MacKeys.size() ? MacKeys[macKey] : 0;
}

class KeyState {
public:
    bool pressed(uint16_t key) const { return key < held_.size() && held_[key]; }

    template<class Sink>
    void update(uint16_t key, bool down, const Sink &send) {
        if (!key || key >= held_.size() || held_[key] == down) return;
        held_[key] = down;
        send(key, down);
    }

    template<class Sink>
    void releaseAll(const Sink &send) {
        if (held_.none()) return;
        for (uint16_t key = 1; key < held_.size(); ++key) {
            if (pressed(key)) update(key, false, send);
        }
    }

private:
    std::bitset<675> held_;
};

} // namespace starrail
