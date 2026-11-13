import AppKit
import SwiftUI

/// Device endpoints belong to a concrete host; never copy them with the global
/// streaming profile. Save explicitly so half-entered endpoints cannot activate.
struct ESP32SettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var language = LanguageManager.shared
  @AppStorage("esp32.showStatusBar") private var showStatusBar = true
  @SwiftUI.State private var enabled = false
  @SwiftUI.State private var keyboard = true
  @SwiftUI.State private var mouse = true
  @SwiftUI.State private var buttons = 31
  @SwiftUI.State private var address = ""
  @SwiftUI.State private var port = "80"
  @SwiftUI.State private var accessKey = ""
  @SwiftUI.State private var excluded = ""
  @SwiftUI.State private var message = ""
  @SwiftUI.State private var macroShortcut = 0
  @SwiftUI.State private var macroRepeats = 3
  @SwiftUI.State private var macroHold = 2
  @SwiftUI.State private var macroInterval = 2

  private var hostID: String { settingsModel.selectedHost?.id ?? SettingsModel.globalHostId }
  private var hasHost: Bool { hostID != SettingsModel.globalHostId && !hostID.isEmpty }
  private func tr(_ key: String) -> String { language.localize(key) }

  private var values: [String: Any] {
    ["enabled": enabled, "keyboard_enabled": keyboard, "mouse_enabled": mouse,
     "mouse_buttons": buttons, "address": address, "port": Int(port) ?? 0,
     "access_key": accessKey, "excluded_keys": excluded,
     "shortcut_macro": macroShortcut, "macro_repeats": macroRepeats,
     "macro_hold_ms": macroHold, "macro_interval_ms": macroInterval]
  }

  var body: some View {
    FormSection(title: "ESP32 USB Input") {
      if !hasHost {
        Text(tr("ESP32 choose host")).foregroundStyle(.secondary)
      } else {
        ToggleCell(title: "ESP32 Enable", boolBinding: $enabled)
        ToggleCell(title: "ESP32 Show Status Bar", boolBinding: $showStatusBar)
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
          Group {
            SettingsRow(title: "ESP32 F Macro Shortcut") {
              Picker("", selection: $macroShortcut) {
                Text(tr("ESP32 Macro Off")).tag(0)
                ForEach([1, 2, 3, 4, 5, 6, 7, 8, 12], id: \.self) { function in
                  Text("F\(function)").tag(function)
                }
              }.labelsHidden().frame(width: 120)
            }
            SettingsRow(title: "ESP32 F Macro Repeats") {
              Picker("", selection: $macroRepeats) {
                ForEach(3...5, id: \.self) { count in Text("\(count)").tag(count) }
              }.labelsHidden().frame(width: 120)
            }
            SettingsRow(title: "ESP32 F Hold ms") {
              Stepper(value: $macroHold, in: 1...2000) { Text("\(macroHold)") }.frame(width: 160)
            }
            SettingsRow(title: "ESP32 F Release ms") {
              Stepper(value: $macroInterval, in: 1...60000) { Text("\(macroInterval)") }.frame(width: 160)
            }
            Text(tr("ESP32 macro detail")).font(.caption).foregroundStyle(.secondary)
          }.disabled(!keyboard)
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
    macroShortcut = saved["shortcut_macro"] as? Int ?? 0
    macroRepeats = saved["macro_repeats"] as? Int ?? 3
    macroHold = saved["macro_hold_ms"] as? Int ?? 2
    macroInterval = saved["macro_interval_ms"] as? Int ?? 2
    message = ""
  }
}
