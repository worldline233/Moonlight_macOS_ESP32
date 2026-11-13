import Foundation
import IOKit.hid

// This helper touches only the dedicated vendor Feature interface, never the
// keyboard or mouse collections. No driver replacement or device seizure.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func status(_ device: IOHIDDevice) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: 32)
    var length = data.count
    let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &data, &length)
    guard result == kIOReturnSuccess, length == 32,
          Array(data[0..<8]) == Array("MLUPD001".utf8), data[8] == 1, data[9] == 0 else { return nil }
    return data
}
func mac(_ data: [UInt8]) -> String {
    data[10..<16].map { String(format: "%02x", $0) }.joined(separator: ":")
}
let arguments = CommandLine.arguments
let list = arguments.count == 2 && arguments[1] == "--list"
let enter = arguments.count == 3 && arguments[1] == "--enter"
guard list || enter else { fail("Usage: esp32-usb-helper --list | --enter MAC") }
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [kIOHIDVendorIDKey: 0x303a, kIOHIDProductIDKey: 0x400c,
                              kIOHIDDeviceUsagePageKey: 0xff00, kIOHIDDeviceUsageKey: 1]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard opened == kIOReturnSuccess else { fail("Cannot open USB upgrade interface: \(opened)") }
defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
var found = [(IOHIDDevice, [UInt8])]()
for device in devices {
    if let report = status(device) { found.append((device, report)) }
}
if list {
    let records = found.map { ["mac": mac($0.1)] }
    let output = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    print(String(data: output, encoding: .utf8)!)
} else {
    let target = arguments[2].lowercased()
    let selected = found.filter { mac($0.1) == target }
    guard selected.count == 1 else { fail("Expected one USB upgrade interface for the selected MAC") }
    var request = selected[0].1
    request[9] = 1
    let sent = IOHIDDeviceSetReport(selected[0].0, kIOHIDReportTypeFeature, 0, request, request.count)
    guard sent == kIOReturnSuccess else { fail("USB download request failed: \(sent)") }
    print("Download request acknowledged")
}
