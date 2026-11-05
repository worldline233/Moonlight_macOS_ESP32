#include "ESP32KeyboardRouter.h"
#include "ESP32MouseRouter.h"
#include "ESP32MacKeyMap.h"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
    Esp32KeyboardRouter keyboard;
    assert(!keyboard.handle(4, true, 0).send); // offline press stays suppressed
    assert(!keyboard.handle(4, true, 1).send);
    assert(!keyboard.handle(4, false, 1).send);
    auto report = keyboard.handle(4, true, 1);
    assert(report.send && report.keys[0] == 4);
    assert(!keyboard.handle(4, true, 1).send); // OS repeat does not spam reports
    report = keyboard.handle(228, true, 1);
    assert(report.send && report.modifiers == 16 && report.keys[0] == 4);
    report = keyboard.handle(224, true, 1);
    assert(report.send && report.modifiers == 17); // both control keys
    keyboard.cancel();
    assert(!keyboard.handle(4, true, 1).send);
    assert(!keyboard.handle(4, false, 1).send);
    report = keyboard.handle(4, true, 1);
    assert(report.send && report.modifiers == 0); // no replay of held modifiers
    assert(!keyboard.handle(4, true, 2).send); // new connection requires release
    assert(!keyboard.handle(4, false, 2).send);
    assert(keyboard.handle(4, true, 2).send);
    assert(!keyboard.handle(104, true, 2).send); // unsupported F13
    assert(!keyboard.handle(10000, true, 2).send);

    Esp32KeyboardRouter capacity;
    for (unsigned usage = 4; usage < 20; ++usage) assert(capacity.handle(usage, true, 1).send);
    assert(!capacity.handle(20, true, 1).send);
    assert(capacity.handle(231, true, 1).send); // modifiers don't use NKRO slots
    assert(capacity.handle(4, false, 1).send);
    assert(!capacity.handle(20, true, 1).send); // over-capacity key needs physical up
    assert(!capacity.handle(20, false, 1).send);
    assert(capacity.handle(20, true, 1).send);

    Esp32MouseRouter mouse;
    auto decision = mouse.handle(0, true, 1, 1);
    assert(decision.consume && decision.sendUsb && decision.usbButtons == 1);
    decision = mouse.handle(1, true, 1, 1);
    assert(!decision.consume && !decision.sendUsb); // unselected stays native
    assert(mouse.cancel() == 2); // only native right needs a Sunshine release
    assert(!mouse.handle(0, true, 1, 1).sendUsb);
    assert(mouse.handle(0, false, 1, 1).consume);
    assert(mouse.handle(0, true, 2, 1).sendUsb);
    assert(!mouse.handle(0, true, 3, 1).sendUsb);
    assert(mouse.handle(0, false, 3, 1).consume);

    Esp32MouseRouter fallback;
    assert(!fallback.handle(0, true, 0, 1).consume);
    assert(!fallback.handle(0, true, 1, 1).sendUsb); // native press keeps its owner
    assert(!fallback.handle(0, false, 1, 1).consume);
    assert(fallback.handle(0, true, 1, 1).sendUsb);
    fallback.cancel();
    fallback.handle(0, false, 0, 1, true);
    assert(fallback.handle(0, true, 0, 1, true).consume); // paused selected button
    assert(!fallback.handle(0, true, 1, 1).sendUsb); // resume doesn't replay it
    assert(!fallback.handle(99, true, 1).consume);

    // Independent position examples, including distinct keypad Enter and all
    // eight side-specific modifiers. Catch table shifts at the AppKit boundary.
    assert(esp32MacKeyUsage(0) == 4); // A
    assert(esp32MacKeyUsage(12) == 20); // Q
    assert(esp32MacKeyUsage(18) == 30); // 1
    assert(esp32MacKeyUsage(36) == 40); // Return
    assert(esp32MacKeyUsage(76) == 88); // keypad Enter
    assert(esp32MacKeyUsage(59) == 224 && esp32MacKeyUsage(62) == 228);
    assert(esp32MacKeyUsage(56) == 225 && esp32MacKeyUsage(60) == 229);
    assert(esp32MacKeyUsage(58) == 226 && esp32MacKeyUsage(61) == 230);
    assert(esp32MacKeyUsage(55) == 227 && esp32MacKeyUsage(54) == 231);
    assert(esp32MacKeyUsage(101) == 66); // F9
    assert(esp32MacKeyUsage(103) == 68); // F11
    assert(esp32MacKeyUsage(109) == 67); // F10
    assert(esp32MacKeyUsage(122) == 58); // F1
    assert(esp32MacKeyUsage(126) == 82); // Up
    assert(esp32MacKeyUsage(200) == 0);
    assert(std::strcmp(esp32KeyboardCode(esp32MacKeyUsage(55)), "MetaLeft") == 0);
    std::cout << "ESP32 routing: passed (offline, reconnect, release, capacity, fallback, key positions)\n";
}
