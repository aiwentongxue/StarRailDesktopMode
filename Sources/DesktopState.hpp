#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string_view>

namespace starrail {

struct ClientProfile {
    std::string_view bundleID;
    std::string_view version;
    std::string_view build;
    std::array<uint8_t, 16> unityUUID;
};

inline constexpr ClientProfile China470{
    "com.miHoYo.hkrpg", "4.7.0", "1",
    {0x26, 0x4C, 0x6E, 0x79, 0x85, 0xC7, 0x30, 0x8E,
     0xB9, 0xF9, 0xCC, 0x36, 0xEF, 0x18, 0xAC, 0xBB}
};

inline bool Matches(const ClientProfile &profile, std::string_view bundleID,
                    std::string_view version, std::string_view build,
                    const std::array<uint8_t, 16> &uuid) {
    return bundleID == profile.bundleID && version == profile.version &&
           build == profile.build && uuid == profile.unityUUID;
}

struct Point {
    double x = 0;
    double y = 0;
};

struct Rect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    bool valid() const {
        return std::isfinite(x) && std::isfinite(y) &&
               std::isfinite(width) && std::isfinite(height) && width > 0 && height > 0;
    }

    bool contains(Point point) const {
        return point.x >= x && point.y >= y && point.x < x + width && point.y < y + height;
    }

    Point center() const { return {x + width / 2, y + height / 2}; }
};

inline Rect QuartzRect(Rect appKitRect, double primaryTop) {
    return {appKitRect.x, primaryTop - appKitRect.y - appKitRect.height,
            appKitRect.width, appKitRect.height};
}

// AppKit describes the usable window and UIKit locates the Metal view within
// it. Keep coordinates in screen points when backing scale differs per display.
inline Rect GameViewport(Rect content, Rect scene, Rect metalView) {
    if (!content.valid() || !scene.valid() || !metalView.valid()) return {};
    const double xScale = content.width / scene.width;
    const double yScale = content.height / scene.height;
    const double left = std::max(content.x, content.x + (metalView.x - scene.x) * xScale);
    const double top = std::max(content.y, content.y + (metalView.y - scene.y) * yScale);
    const double right = std::min(content.x + content.width,
                                  content.x + (metalView.x + metalView.width - scene.x) * xScale);
    const double bottom = std::min(content.y + content.height,
                                   content.y + (metalView.y + metalView.height - scene.y) * yScale);
    return {left, top, right - left, bottom - top};
}

class PointerTransition {
public:
    bool update(bool ownsPointer, bool visible) {
        const bool recenter = ownsPointer && visible && hiddenInGame_;
        hiddenInGame_ = ownsPointer && !visible;
        return recenter;
    }

private:
    bool hiddenInGame_ = false;
};

class RelativeMotion {
public:
    void add(double x, double y) {
        if (std::isfinite(x) && std::isfinite(y)) {
            pending_.x += x;
            pending_.y += y;
        }
    }

    Point take(double gain) {
        const Point result{pending_.x * gain, pending_.y * gain};
        pending_ = {};
        return result;
    }

private:
    Point pending_;
};

class FrameMotion {
public:
    void add(double x, double y) {
        if (!std::isfinite(x) || !std::isfinite(y)) return;
        // AppKit can include a programmatic warp in its next motion packet.
        pending_.add(x - warp_.x, y - warp_.y);
        warp_ = {};
    }

    Point sample(uint32_t frame, double gain) {
        if (!sampled_ || frame != frame_) {
            frame_ = frame;
            value_ = pending_.take(gain);
            sampled_ = true;
        }
        return value_;
    }

    void reset(Point warp = {}) {
        pending_ = {};
        value_ = {};
        sampled_ = false;
        warp_ = warp;
    }

private:
    RelativeMotion pending_;
    Point value_;
    Point warp_;
    uint32_t frame_ = 0;
    bool sampled_ = false;
};

inline double SensitivityGain(double setting) {
    if (!std::isfinite(setting)) return 1;
    return std::clamp(setting, 0.0, 100.0) / 50.0;
}

} // namespace starrail
