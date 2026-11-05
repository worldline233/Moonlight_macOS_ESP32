#pragma once

#include <array>
#include <cstdint>

// Pure state machine, used only by the bridge routing lock. Buttons use HID bit order:
// left, right, middle, back, forward. A connection epoch changes on every reconnect.
class Esp32MouseRouter
{
public:
    struct Decision {
        bool consume = true;
        bool sendUsb = false;
        std::uint8_t usbButtons = 0;
    };

    Decision handle(unsigned button, bool down, std::uint64_t epoch,
                    std::uint8_t selected = 0x1f, bool suppressOffline = false)
    {
        if (button >= m_Owners.size()) {
            return {false, false, m_UsbButtons};
        }
        if (epoch != m_Epoch) {
            for (auto& owner : m_Owners) {
                if (owner == Owner::Usb) owner = Owner::Suppressed;
            }
            m_UsbButtons = 0;
            m_Epoch = epoch;
        }
        auto& owner = m_Owners[button];
        const auto bit = static_cast<std::uint8_t>(1u << button);
        if (down) {
            // Repeated downs never select a second route, even after reconnect.
            if (owner != Owner::None) return {true, false, m_UsbButtons};
            if (epoch != 0 && (selected & bit)) {
                owner = Owner::Usb;
                m_UsbButtons |= bit;
                return {true, true, m_UsbButtons};
            }
            if (suppressOffline && (selected & bit)) {
                owner = Owner::Suppressed;
                return {true, false, m_UsbButtons};
            }
            owner = Owner::Native;
            return {false, false, m_UsbButtons};
        }
        const auto previous = owner;
        owner = Owner::None;
        if (previous == Owner::Usb) {
            m_UsbButtons &= static_cast<std::uint8_t>(~bit);
            return {true, true, m_UsbButtons};
        }
        return {previous != Owner::Native, false, m_UsbButtons};
    }

    // Caller sends native releases for this mask and releases the USB session.
    // Suppress held inputs until their physical up arrives; no held-state replay.
    std::uint8_t cancel()
    {
        std::uint8_t native = 0;
        for (unsigned i = 0; i < m_Owners.size(); ++i) {
            if (m_Owners[i] == Owner::Native) native |= 1u << i;
            if (m_Owners[i] != Owner::None) m_Owners[i] = Owner::Suppressed;
        }
        m_UsbButtons = 0;
        return native;
    }

private:
    enum class Owner { None, Native, Usb, Suppressed };
    std::array<Owner, 5> m_Owners{};
    std::uint8_t m_UsbButtons = 0;
    std::uint64_t m_Epoch = 0;
};
