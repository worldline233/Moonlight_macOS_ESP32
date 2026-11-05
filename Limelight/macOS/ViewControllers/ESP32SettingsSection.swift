import AppKit
import SwiftUI

/// Device endpoints belong to a concrete host; never copy them with the global
/// streaming profile. Save explicitly so half-entered endpoints cannot activate.
struct ESP32SettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var language = LanguageManager.shared
  @State private var enabled = false
  @State private var keyboard = true
  @State private var mouse = true
  @State private var buttons = 31
  @State private var address = ""
  @State private var port = "80"
  @State private var accessKey = ""
  @State private var excluded = ""
  @State private var message = ""

  private var hostID: String { settingsModel.selectedHost?.id ?? SettingsModel.globalHostId }
  private var hasHost: Bool { hostID != SettingsModel.globalHostId && !hostID.isEmpty }
  private func tr(_ key: String) -> String { language.localize(key) }

  private var values: [String: Any] {
    ["enabled": enabled, "keyboard_enabled": keyboard, "mouse_enabled": mouse,
     "mouse_buttons": buttons, "address": address, "port": Int(port) ?? 0,
     "access_key": accessKey, "excluded_keys": excluded]
  }

  var body: some View {
    FormSection(title: "ESP32 USB Input") {
      if !hasHost {
        Text(tr("ESP32 choose host")).foregroundStyle(.secondary)
      } else {
        ToggleCell(title: "ESP32 Enable", boolBinding: $enabled)
        Group {
          SettingsRow(title: "ESP32 Address") {
            TextField("192.168.1.100", text: $address).frame(width: 230)
          }
          SettingsRow(title: "ESP32 Port") {
            TextField("80", text: $port).frame(width: 100)
          }
          SettingsRow(title: "ESP32 Control Key") {
            SecureField(tr("ESP32 six digits"), text: $accessKey).frame(width: 160)
          }
          ToggleCell(title: "ESP32 Keyboard", boolBinding: $keyboard)
          ToggleCell(title: "ESP32 Mouse Buttons", boolBinding: $mouse)
          if mouse {
            ForEach(Array(["left", "right", "middle", "back", "forward"].enumerated()), id: \.offset) { index, name in
              Toggle(tr("ESP32 button " + name), isOn: Binding(
                get: { buttons & (1 << index) != 0 },
                set: { if $0 { buttons |= 1 << index } else { buttons &= ~(1 << index) } }
              ))
            }
          }
          SettingsRow(title: "ESP32 Excluded Keys") {
            TextField("MetaLeft,MetaRight", text: $excluded).frame(width: 230)
          }
        }.disabled(!enabled)
        Text(tr("ESP32 routing detail")).font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(tr("ESP32 Save")) {
            if let error = ESP32InputBridge.validationError(for: values) {
              message = error
            } else if ESP32InputBridge.save(values, for: hostID) {
              message = "ESP32 saved"
            }
          }
          if !message.isEmpty { Text(tr(message)).font(.caption).foregroundStyle(.secondary) }
        }
        Text(tr("ESP32 controls detail")).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear(perform: load)
    .onChange(of: hostID) { _ in load() }
  }

  private func load() {
    let saved = ESP32InputBridge.settings(for: hasHost ? hostID : "")
    enabled = saved["enabled"] as? Bool ?? false
    keyboard = saved["keyboard_enabled"] as? Bool ?? true
    mouse = saved["mouse_enabled"] as? Bool ?? true
    buttons = saved["mouse_buttons"] as? Int ?? 31
    address = saved["address"] as? String ?? ""
    port = String(saved["port"] as? Int ?? 80)
    accessKey = saved["access_key"] as? String ?? ""
    excluded = saved["excluded_keys"] as? String ?? ""
    message = ""
  }
}
