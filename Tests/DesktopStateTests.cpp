#include "DesktopState.hpp"

#include <cassert>
#include <iostream>
#include <limits>

int main() {
    using namespace starrail;

    const auto &profile = China470;
    assert(Matches(profile, profile.bundleID, "4.7.0", "1", profile.unityUUID));
    assert(!Matches(profile, "com.HoYoverse.hkrpgoversea", "4.7.0", "1", profile.unityUUID));
    assert(!Matches(profile, profile.bundleID, "4.7.1", "1", profile.unityUUID));
    assert(!Matches(profile, profile.bundleID, "4.7.0", "2", profile.unityUUID));
    auto uuid = profile.unityUUID;
    ++uuid.back();
    assert(!Matches(profile, profile.bundleID, "4.7.0", "1", uuid));

    const auto desktop = QuartzRect({-1920, 1200, 1600, 900}, 1080);
    assert(desktop.x == -1920 && desktop.y == -1020);
    const auto viewport = GameViewport(desktop, {0, 0, 800, 450}, {50, 0, 700, 450});
    assert(viewport.x == -1820 && viewport.y == -1020 && viewport.width == 1400);
    assert(viewport.center().x == -1120 && viewport.center().y == -570);
    assert(viewport.contains(viewport.center()));
    assert(!viewport.contains({-1919, -1019}));
    assert(!GameViewport(desktop, {}, {}).valid());

    PointerTransition pointer;
    assert(!pointer.update(true, true));
    assert(!pointer.update(true, false));
    assert(!pointer.update(true, false));
    assert(pointer.update(true, true));
    assert(!pointer.update(true, true));
    assert(!pointer.update(true, false));
    assert(!pointer.update(false, true));
    assert(!pointer.update(true, true));

    RelativeMotion mouse;
    for (int i = 0; i < 10; ++i) mouse.add(1.5, -0.75);
    mouse.add(std::numeric_limits<double>::infinity(), 0);
    const auto delta = mouse.take(SensitivityGain(40));
    assert(delta.x == 12 && delta.y == -6);
    assert(mouse.take(1).x == 0);
    assert(SensitivityGain(50) == 1);
    assert(SensitivityGain(-10) == 0);
    assert(SensitivityGain(200) == 2);
    std::cout << "DesktopState tests passed\n";
}
