#include "ClientProfile.hpp"
#include "DesktopState.hpp"
#include "KeyboardState.hpp"

#include <cassert>
#include <iostream>
#include <limits>
#include <utility>
#include <vector>

int main() {
    using namespace starrail;

    for (const auto *profile : SupportedClients) {
        assert(FindClient(profile->bundleID, "4.7.0", "1", profile->unityUUID) == profile);
        assert(!FindClient(profile->bundleID, "4.7.1", "1", profile->unityUUID));
        assert(!FindClient(profile->bundleID, "4.7.0", "2", profile->unityUUID));
        auto uuid = profile->unityUUID;
        ++uuid.back();
        assert(!FindClient(profile->bundleID, "4.7.0", "1", uuid));
    }
    assert(!FindClient(International470.bundleID, "4.7.0", "1", China470.unityUUID));
    assert(!FindClient(China470.bundleID, "4.7.0", "1", International470.unityUUID));

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

    FrameMotion camera;
    camera.add(2, -3);
    camera.add(1, 2);
    assert(camera.sample(10, 2).x == 6);
    camera.add(4, 5);
    assert(camera.sample(10, 2).y == -2);
    assert(camera.sample(11, 2).x == 8);
    assert(camera.sample(11, 2).y == 10);
    assert(camera.sample(12, 2).x == 0);
    camera.add(10, 10);
    camera.reset();
    assert(camera.sample(12, 2).y == 0);
    camera.reset({-420, 180});
    camera.add(-416, 177);
    assert(camera.sample(13, 1).x == 4 && camera.sample(13, 1).y == -3);
    camera.add(2, 1);
    assert(camera.sample(14, 1).x == 2 && camera.sample(14, 1).y == 1);

    const auto w = UnityKey(13);
    const auto a = UnityKey(0);
    const auto shift = UnityKey(56);
    assert(w == 'w' && a == 'a' && shift == 304 && UnityKey(60) == 303);
    assert(UnityKey(123) == 276 && UnityKey(999) == 0);
    KeyState keys;
    std::vector<std::pair<uint16_t, bool>> changes;
    const auto send = [&](uint16_t key, bool down) { changes.emplace_back(key, down); };
    keys.update(w, true, send);
    keys.update(w, true, send);
    keys.update(shift, true, send);
    keys.update(a, true, send);
    keys.update(shift, false, send);
    keys.update(a, false, send);
    assert(keys.pressed(w));
    keys.update(w, false, send);
    keys.update(w, true, send);
    keys.update(a, true, send);
    keys.releaseAll(send);
    keys.releaseAll(send);
    assert((changes == decltype(changes){
        {w, true}, {shift, true}, {a, true}, {shift, false}, {a, false}, {w, false},
        {w, true}, {a, true}, {a, false}, {w, false},
    }));
    std::cout << "DesktopState tests passed\n";
}
