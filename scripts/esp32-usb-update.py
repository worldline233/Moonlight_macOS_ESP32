"""Upgrade this ESP32-S3 through its native USB port on macOS or Windows.

Uses native IOKit / Windows HID APIs. Requires esptool 5.6+.
Only the existing application partition is written; NVS is left untouched.
"""
import argparse
import ctypes as ct
from ctypes import wintypes as wt
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

MAGIC = b'MLUPD001'
REPORT_BYTES = 32
# ESP TinyUSB's default PID encodes CFG_TUD_HID (three interfaces => 0x400c).
VID, HID_PID, ROM_PID = 0x303A, 0x400C, 0x1001
APP_OFFSET, APP_SIZE = 0x20000, 0x400000


def normalize_mac(value):
    value = value.lower().replace(':', '').replace('-', '')
    if not re.fullmatch('[0-9a-f]{12}', value):
        raise ValueError('MAC must contain 12 hexadecimal digits')
    return ':'.join(value[i:i+2] for i in range(0, 12, 2))


def parse_status(payload):
    if len(payload) != REPORT_BYTES or payload[:8] != MAGIC or payload[8:10] != b'\x01\x00':
        raise ValueError('Unsupported USB update protocol')
    return normalize_mac(payload[10:16].hex())


def validate_firmware(path, expected=None):
    data = path.read_bytes()
    if len(data) < 256 or len(data) > APP_SIZE or data[0] != 0xE9 or struct.unpack_from('<H', data, 12)[0] != 9:
        raise ValueError('Expected an ESP32-S3 application binary (not merged flash image)')
    manifest = path.parent/'sha256.json'
    if expected is None and manifest.is_file():
        entry = json.loads(manifest.read_text(encoding='utf-8-sig')).get(path.name, {})
        expected = entry.get('sha256')
    digest = hashlib.sha256(data).hexdigest()
    if not expected or not re.fullmatch('[0-9a-fA-F]{64}', expected) or digest != expected.lower():
        raise ValueError('Firmware hash mismatch or missing sha256.json; supply --sha256 for a custom build')
    return digest


class WindowsHid:
    """Read/write one vendor HID Feature report using Windows system libraries."""
    def __init__(self):
        if sys.platform != 'win32':
            raise RuntimeError('Run this tool on the Windows PC connected to the board native USB port')
        self.kernel = ct.WinDLL('kernel32', use_last_error=True)
        self.setup = ct.WinDLL('setupapi', use_last_error=True)
        self.hid = ct.WinDLL('hid', use_last_error=True)
        self.kernel.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ct.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
        self.kernel.CreateFileW.restype = wt.HANDLE
        self.kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.setup.SetupDiGetClassDevsW.argtypes = [ct.c_void_p, wt.LPCWSTR, wt.HWND, wt.DWORD]
        self.setup.SetupDiGetClassDevsW.restype = wt.HANDLE
        self.setup.SetupDiEnumDeviceInterfaces.argtypes = [wt.HANDLE, ct.c_void_p, ct.c_void_p, wt.DWORD, ct.c_void_p]
        self.setup.SetupDiGetDeviceInterfaceDetailW.argtypes = [wt.HANDLE, ct.c_void_p, ct.c_void_p, wt.DWORD, ct.c_void_p, ct.c_void_p]
        self.setup.SetupDiDestroyDeviceInfoList.argtypes = [wt.HANDLE]
        self.hid.HidD_GetHidGuid.argtypes = [ct.c_void_p]
        for name in ['HidD_GetFeature', 'HidD_SetFeature']:
            fn = getattr(self.hid, name)
            fn.argtypes = [wt.HANDLE, ct.c_void_p, wt.ULONG]
            fn.restype = wt.BOOLEAN
        self.invalid = ct.c_void_p(-1).value

    def paths(self):
        class Interface(ct.Structure):
            _fields_ = [('size', wt.DWORD), ('guid', ct.c_byte*16), ('flags', wt.DWORD), ('reserved', ct.c_size_t)]
        guid = ct.create_string_buffer(16)
        self.hid.HidD_GetHidGuid(guid)
        devices = self.setup.SetupDiGetClassDevsW(guid, None, None, 0x12)
        if devices == self.invalid:
            raise ct.WinError(ct.get_last_error())
        try:
            index = 0
            while True:
                interface = Interface()
                interface.size = ct.sizeof(interface)
                if not self.setup.SetupDiEnumDeviceInterfaces(devices, None, guid, index, ct.byref(interface)):
                    if ct.get_last_error() == 259:
                        break
                    raise ct.WinError(ct.get_last_error())
                index += 1
                required = wt.DWORD()
                self.setup.SetupDiGetDeviceInterfaceDetailW(devices, ct.byref(interface), None, 0, ct.byref(required), None)
                detail = ct.create_string_buffer(required.value)
                ct.cast(detail, ct.POINTER(wt.DWORD))[0] = 8 if ct.sizeof(ct.c_void_p) == 8 else 6
                if not self.setup.SetupDiGetDeviceInterfaceDetailW(devices, ct.byref(interface), detail, required.value, None, None):
                    raise ct.WinError(ct.get_last_error())
                path = ct.wstring_at(ct.addressof(detail)+4)
                if f'vid_{VID:04x}&pid_{HID_PID:04x}&mi_02' in path.lower():
                    yield path
        finally:
            self.setup.SetupDiDestroyDeviceInfoList(devices)

    def open(self, path):
        handle = self.kernel.CreateFileW(path, 0xC0000000, 3, None, 3, 0, None)
        if handle == self.invalid:
            raise ct.WinError(ct.get_last_error())
        return handle

    def status(self, handle):
        buffer = ct.create_string_buffer(REPORT_BYTES+1)  # leading report ID 0
        if not self.hid.HidD_GetFeature(handle, buffer, len(buffer)):
            raise ct.WinError(ct.get_last_error())
        payload = buffer.raw[1:]
        parse_status(payload)
        return payload

    def boards(self):
        result = []
        for path in self.paths():
            handle = self.open(path)
            try:
                payload = self.status(handle)
                result.append((path, parse_status(payload)))
            finally:
                self.kernel.CloseHandle(handle)
        return result

    def enter_rom(self, path, expected_mac):
        handle = self.open(path)
        try:
            payload = bytearray(self.status(handle))
            if parse_status(payload) != expected_mac:
                raise RuntimeError('USB device identity changed; refusing update')
            payload[9] = 1
            buffer = ct.create_string_buffer(b'\0'+bytes(payload), REPORT_BYTES+1)
            if not self.hid.HidD_SetFeature(handle, buffer, len(buffer)):
                raise ct.WinError(ct.get_last_error())
        finally:
            self.kernel.CloseHandle(handle)


class MacHid:
    """Use the packaged IOKit helper; source checkouts can use Xcode Swift."""
    def __init__(self):
        helper = Path(__file__).with_name('esp32-usb-helper')
        if helper.is_file():
            self.command = [str(helper)]
        else:
            source = Path(__file__).with_name('esp32-usb-helper.swift')
            if not source.is_file():
                raise RuntimeError('Missing macOS USB helper; download the complete upgrade tool')
            self.command = ['xcrun', 'swift', str(source)]

    def run(self, *arguments):
        result = subprocess.run([*self.command, *arguments], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or 'macOS USB helper failed')
        return result.stdout

    def boards(self):
        return [(normalize_mac(board['mac']), normalize_mac(board['mac']))
                for board in json.loads(self.run('--list'))]

    def enter_rom(self, path, expected_mac):
        if path != expected_mac:
            raise RuntimeError('Selected USB device identity changed')
        self.run('--enter', expected_mac)


def run_esptool(port, *args, timeout=60):
    command = [sys.executable, '-B', '-m', 'esptool', '--chip', 'esp32s3', '--port', port, *args]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stdout+result.stderr).strip())
    return result.stdout+result.stderr


def verify_rom_identity(port, expected_mac):
    output = run_esptool(port, '--before', 'no-reset', '--after', 'no-reset', '--no-stub', 'read-mac', timeout=30)
    if expected_mac not in output.lower():
        raise RuntimeError('ROM chip MAC does not match selected HID device; refusing write')


def verify_partition(port):
    import tempfile
    with tempfile.TemporaryDirectory(prefix='esp32-usb-update-') as directory:
        target = Path(directory)/'partitions.bin'
        run_esptool(port, '--before', 'no-reset', '--after', 'no-reset', '--no-stub', 'read-flash', '0x8000', '0x1000', str(target))
        entries = []
        data = target.read_bytes()
        for i in range(0, len(data), 32):
            magic, kind, sub, offset, size, label, flags = struct.unpack_from('<HBBII16sI', data, i)
            if magic != 0x50AA:
                break
            entries.append((kind, sub, offset, size))
        if (0, 0, APP_OFFSET, APP_SIZE) not in entries:
            raise RuntimeError('Existing application partition layout does not match; refusing write')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('firmware', type=Path, nargs='?', default=Path(__file__).with_name('lan_usb_keyboard.bin'))
    parser.add_argument('--list', action='store_true', help='List compatible HID devices without switching modes')
    parser.add_argument('--mac', help='Select a board by MAC (required with --port)')
    parser.add_argument('--sha256', help='Expected firmware SHA256 for a custom application binary')
    parser.add_argument('--port', help='Resume after interruption on a ROM USB serial port; requires --mac')
    args = parser.parse_args()
    if sys.platform not in ('win32', 'darwin'):
        parser.error('This USB updater runs on macOS or Windows')
    try:
        selected = normalize_mac(args.mac) if args.mac else None
        hid = MacHid() if sys.platform == 'darwin' else WindowsHid()
        if args.list:
            print(json.dumps([{'mac':mac, 'path':path} for path, mac in hid.boards()], ensure_ascii=False, indent=2))
            return 0
        digest = validate_firmware(args.firmware, args.sha256)
        import esptool
        from serial.tools import list_ports
        version = tuple(int(x) for x in esptool.__version__.split('.')[:2])
        if version < (5, 6):
            raise RuntimeError('esptool 5.6+ required')
        if args.port:
            if selected is None:
                parser.error('--port requires --mac to verify the target before writing')
            matches = [p for p in list_ports.comports() if p.device.lower()==args.port.lower() and p.vid==VID and p.pid==ROM_PID]
            if len(matches)!=1:
                raise RuntimeError('Specified port is not a connected Espressif ROM USB port')
            port=matches[0].device
        else:
            boards = [(path, mac) for path, mac in hid.boards() if selected is None or mac==selected]
            if len(boards)!=1:
                raise RuntimeError('Expected one compatible HID device; connect native USB and use --list / --mac if needed')
            path, selected = boards[0]
            previous = {p.device for p in list_ports.comports()}
            print(f'Selected ESP32-S3 {selected}; firmware SHA256 {digest}',flush=True)
            hid.enter_rom(path,selected)
            print('Download mode requested through USB; waiting for ROM port...',flush=True)
            deadline=time.monotonic()+20
            port=None
            while time.monotonic()<deadline:
                candidates=[p for p in list_ports.comports() if p.vid==VID and p.pid==ROM_PID and p.device not in previous]
                if len(candidates)==1:
                    port=candidates[0].device
                    break
                time.sleep(0.25)
            if not port:
                raise RuntimeError(f'ROM port did not appear. Keep the cable connected; use --port COMx --mac {selected} to resume if Windows assigned a port.')
        verify_rom_identity(port,selected)
        verify_partition(port)
        print(f'Target and partition verified on {port}; writing application only...',flush=True)
        output=run_esptool(port,'--baud','921600','--before','no-reset','--after','watchdog-reset',
                           'write-flash','--flash-mode','keep','--flash-freq','keep','--flash-size','keep',hex(APP_OFFSET),str(args.firmware.resolve()),timeout=90)
        if 'Hash of data verified.' not in output:
            raise RuntimeError('Flash verification marker missing; inspect device before use')
        print('Firmware written and verified. Waiting for keyboard/mouse mode...',flush=True)
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if any(mac==selected for _,mac in hid.boards()):
                print('USB update complete; the same board is back in HID mode. Wi-Fi configuration preserved.',flush=True)
                return 0
            time.sleep(0.5)
        raise RuntimeError('Flash verified, but return to HID mode is not confirmed; no repeat write was attempted')
    except (OSError,ValueError,RuntimeError,ImportError,subprocess.SubprocessError) as error:
        print('USB update stopped: '+str(error),file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
