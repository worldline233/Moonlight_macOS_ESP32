#pragma once

#include <array>
#include <cstdint>

// A local shortcut's final key must stay local until its matching physical up.
// This also consumes a stale fresh down if focus loss swallowed the old up,
// preventing a native down followed by an accidentally consumed native up.
class Esp32LocalShortcutLatch
{
public:
    void latch(unsigned usage) { if (usage < m_Down.size()) m_Down[usage] = true; }
    bool consume(unsigned usage, bool down)
    {
        if (usage >= m_Down.size() || !m_Down[usage]) return false;
        if (!down) m_Down[usage] = false;
        return true;
    }
private:
    std::array<bool, 512> m_Down{};
};

// USB keyboard scancodes use USB HID usages for these keys. Names are the
// existing firmware's protocol codes, not layout-dependent characters.
inline const char* esp32KeyboardCode(unsigned usage)
{
    static const char* const letters[] = {
        "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI",
        "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR",
        "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ"};
    static const char* const numbers[] = {
        "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Digit0"};
    static const char* const punctuation[] = {
        "Enter", "Escape", "Backspace", "Tab", "Space", "Minus", "Equal", "BracketLeft",
        "BracketRight", "Backslash", nullptr, "Semicolon", "Quote", "Backquote", "Comma",
        "Period", "Slash", "CapsLock"};
    static const char* const functions[] = {
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"};
    static const char* const navigation[] = {
        "PrintScreen", "ScrollLock", "Pause", "Insert", "Home", "PageUp", "Delete", "End",
        "PageDown", "ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp", "NumLock",
        "NumpadDivide", "NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadEnter",
        "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7",
        "Numpad8", "Numpad9", "Numpad0", "NumpadDecimal"};
    static const char* const modifiers[] = {
        "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft",
        "ControlRight", "ShiftRight", "AltRight", "MetaRight"};
    if (usage >= 4 && usage <= 29) return letters[usage - 4];
    if (usage >= 30 && usage <= 39) return numbers[usage - 30];
    if (usage >= 40 && usage <= 57) return punctuation[usage - 40];
    if (usage >= 58 && usage <= 69) return functions[usage - 58];
    if (usage >= 70 && usage <= 99) return navigation[usage - 70];
    if (usage >= 224 && usage <= 231) return modifiers[usage - 224];
    return nullptr;
}

class Esp32KeyboardRouter
{
public:
    static constexpr unsigned MaxKeys = 16;

    struct Report {
        bool send = false;
        std::uint8_t modifiers = 0;
        std::array<unsigned, MaxKeys> keys{};
    };

    Report handle(unsigned usage, bool down, std::uint64_t epoch)
    {
        if (m_Epoch != epoch) {
            cancel();
            m_Epoch = epoch;
        }
        if (usage >= m_Owners.size() || !esp32KeyboardCode(usage)) return {};
        auto& owner = m_Owners[usage];
        if (down) {
            if (owner != Released) return {};
            // Offline or over-capacity presses need physical up before reuse.
            if (epoch == 0 || (usage < 224 && keyCount() >= MaxKeys)) {
                owner = Suppressed;
                return {};
            }
            owner = Usb;
            return report();
        }
        const bool send = owner == Usb && epoch != 0;
        owner = Released;
        return send ? report() : Report{};
    }

    void cancel()
    {
        for (auto& owner : m_Owners) if (owner == Usb) owner = Suppressed;
    }

private:
    enum Owner : std::uint8_t { Released, Usb, Suppressed };
    unsigned keyCount() const
    {
        unsigned count = 0;
        for (unsigned i = 4; i < 224; ++i) if (m_Owners[i] == Usb) ++count;
        return count;
    }
    Report report() const
    {
        Report result;
        result.send = true;
        unsigned slot = 0;
        for (unsigned i = 4; i < 224; ++i) {
            if (m_Owners[i] == Usb) result.keys[slot++] = i;
        }
        for (unsigned i = 224; i < 232; ++i) {
            if (m_Owners[i] == Usb) result.modifiers |= 1u << (i - 224);
        }
        return result;
    }
    std::array<Owner, 232> m_Owners{};
    std::uint64_t m_Epoch = 0;
};
