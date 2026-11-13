#!/usr/bin/env python3
"""macOS: exercise the actual NSURLSession bridge against a local fake ESP32.

No hardware or third-party Python packages. Verifies wire ordering, handshake,
full keyboard/button reports, exclusions, pause, reconnect, and final release.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]

def exact(stream, size):
    result = b''
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            raise EOFError
        result += chunk
    return result

def send_frame(stream, opcode, payload):
    assert len(payload) < 65536
    header = bytes([0x80 | opcode, len(payload)]) if len(payload) < 126 else bytes([0x80 | opcode, 126]) + struct.pack('!H', len(payload))
    stream.write(header + payload)
    stream.flush()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def __init__(self, bad=False, exclusive=True):
        self.bad = bad
        self.exclusive = exclusive
        self.connections = []
        self.errors = []
        self.lock = threading.Lock()
        self.owner = None
        self.rejected = 0
        super().__init__(('127.0.0.1', 0), Handler)

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self.handle_control()
        finally:
            with self.server.lock:
                if self.server.owner is self:
                    self.server.owner = None

    def handle_control(self):
        self.request.settimeout(10)
        records = []
        try:
            request = self.rfile.readline().decode().strip()
            assert request == 'GET /ws?key=123456 HTTP/1.1'
            headers = {}
            while True:
                line = self.rfile.readline().decode().strip()
                if not line:
                    break
                key, value = line.split(':', 1)
                headers[key.lower()] = value.strip()
            # Match firmware websocket_pre_handshake: one active controller.
            with self.server.lock:
                rejected = self.server.owner is not None
                if rejected:
                    self.server.rejected += 1
                else:
                    self.server.owner = self
                    self.server.connections.append(records)
            if rejected:
                self.wfile.write(b'HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                self.wfile.flush()
                return
            accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.wfile.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
            self.wfile.flush()
            last_seq = 0
            while True:
                first, second = exact(self.rfile, 2)
                assert first & 0x80 and second & 0x80
                length = second & 127
                if length == 126:
                    length, = struct.unpack('!H', exact(self.rfile, 2))
                elif length == 127:
                    length, = struct.unpack('!Q', exact(self.rfile, 8))
                assert length < 4096
                mask = exact(self.rfile, 4)
                payload = bytes(value ^ mask[i % 4] for i, value in enumerate(exact(self.rfile, length)))
                opcode = first & 15
                if opcode == 8:
                    send_frame(self.wfile, 8, payload)
                    break
                if opcode == 9:
                    send_frame(self.wfile, 10, payload)
                    continue
                assert opcode == 1
                message = json.loads(payload)
                assert isinstance(message['seq'], int) and message['seq'] > last_seq
                last_seq = message['seq']
                records.append(message)
                if message['type'] == 'hello':
                    assert message['protocol'] == 2
                    reply = {'type': 'macro_status', 'running': False, 'protocol': 2,
                             'keyboard_nkro': True, 'keyboard_max_keys': 6 if self.server.bad else 16,
                             'exclusive_latest_state': True, 'exclusive_configurable_key': self.server.exclusive}
                    encoded = json.dumps(reply, separators=(',', ':')).encode()
                    send_frame(self.wfile, 1, encoded)
        except (EOFError, BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            with self.server.lock:
                self.server.errors.append(repr(error))

def check(binary, bad=False, lifecycle=False, macro=False, legacy=False, vision=False):
    server = Server(bad, exclusive=not legacy)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        mode = ('legacy_macro' if legacy else 'macro') if macro else ('lifecycle' if lifecycle else ('bad' if bad else 'good'))
        if vision: mode='vision'
        completed = subprocess.run([str(binary), str(server.server_address[1]), mode], capture_output=True, text=True, timeout=20)
        if completed.returncode: print(completed.stdout, completed.stderr)
        completed.check_returncode()
        log = completed.stdout + completed.stderr
        assert '[config]' in log and '[connection]' in log
        if macro:
            assert '[handshake]' in log and '[macro] requested' in log
            if legacy: assert 'firmware_missing_configurable_key' in log
            else: assert '[macro] queued' in log and '[macro] transport_sent' in log
        if vision:
            for marker in ['[video-path]', '[frame]', 'reason=icon_absent', 'unsupported_pixel_format', 'unsupported_resolution_or_aspect', 'reason=paused', 'reason=input_not_captured', '[snapshot]']:
                assert marker in log, (marker, log)
        assert 'ws://' not in log and 'key=123456' not in log

    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)
    assert not server.errors, server.errors
    connections = [records for records in server.connections if records]
    if vision:
        commands=[m for c in connections for m in c if m['type']=='exclusive_macro']
        assert len(commands)==1, connections
        assert all(m['key']=='KeyG' for m in commands), commands
        assert 'COMPRESSED_FIXTURE_' in log and 'LINEAR_DECODE_FIXTURE_PASSED' in log and 'THREE_SLOT_FIXTURE_PASSED' in log, log
        result=next(line for line in log.splitlines() if 'COMPRESSED_FIXTURE_' in line)
        print(result)
        output=ROOT/'build';output.mkdir(exist_ok=True)
        (output/'esp32-pixel-format-validation.json').write_text(json.dumps({'compressed_fixture_exercised':'COMPRESSED_FIXTURE_PASSED' in result,'result':result,'macro_commands':len(commands),'native_conversion_and_recognition_passed':True,'real_linear_video_decode_recognition_and_macro_passed':True,'three_slot_state_sequences_passed':True},indent=2)+'\n')
        print('Native vision diagnostics: passed (frames, scores, unsupported formats, dimensions, pause, focus, no false macro)')
        return
    if macro:
        assert len(connections) == 1, connections
        records = connections[0]
        commands = [m for m in records if m['type'] == 'exclusive_macro']
        assert len(commands) == (0 if legacy else 1), records
        if commands:
            command = commands[0]
            assert command['key'] == 'KeyG'
            assert command['repeats'] == 5 and command['hold_ms'] == 2 and command['interval_ms'] == 2
            trigger = records.index(command)
            assert any(m.get('keys') == ['KeyW'] for m in records[:trigger])
            latest = next(i for i,m in enumerate(records) if m.get('keys') == ['KeyA'])
            assert trigger < latest
            assert not any(m['type'] == 'release_all' for m in records[trigger:latest])
        assert any(m.get('keys') == ['KeyA'] for m in records)
        assert any(m.get('buttons') == ['left'] for m in records)
        assert any(m.get('buttons') == [] for m in records)
        assert sum(m['type'] == 'release_all' for m in records) >= 3
        print('Exclusive macro: passed (' + ('legacy firmware blocked' if legacy else '5 presses, 2/2 ms, live states and cancellation') + ')')
        return
    if lifecycle:
        assert len(connections) == 3, (len(connections), server.rejected)
        for connection in connections:
            assert connection[0]['type'] == 'hello'
            assert connection[1]['type'] == 'release_all'
            assert any(m.get('keys') == ['KeyA'] for m in connection)
            assert any(m.get('buttons') == ['left'] for m in connection)
            assert connection[-1]['type'] == 'release_all', connection
        print('Retained old sessions: 3 stream starts/stops passed against exclusive-control server')
        return
    if bad:
        assert connections and all(m['type'] not in ('state', 'mouse_state') for c in connections for m in c)
        return
    assert len(connections) == 2, len(connections)
    first, second = connections
    for connection in connections:
        assert connection[0]['type'] == 'hello'
        assert connection[1]['type'] == 'release_all'
        assert all(m['type'] in ('hello', 'release_all', 'state', 'mouse_state', 'ping') for m in connection)
    states = [m for m in first if m['type'] == 'state']
    assert any(m['keys'] == ['KeyA'] for m in states)
    assert any(set(m['modifiers']) == {'ControlLeft', 'ControlRight'} for m in states)
    assert sum('KeyB' in m['keys'] for m in states) == 1, states
    assert all('KeyQ' not in m['keys'] for m in states)
    assert any(m.get('buttons') == ['left'] for m in first)
    assert any(m['type'] == 'release_all' for m in first)
    assert all('KeyA' not in m.get('keys', []) for m in second)
    assert any(m.get('keys') == ['KeyC'] for m in second)
    assert second[-1]['type'] == 'release_all'

def check_lifecycle_wiring():
    from button_ordering import method
    source = (ROOT/'Limelight/macOS/ViewControllers/StreamViewController.m').read_text()
    # Ignore the generation proxy's similarly named delegate methods.
    source = source.split('@implementation StreamViewController\n', 1)[1]
    close = (ROOT/'Limelight/macOS/ViewControllers/StreamViewController+WindowModes.m').read_text()
    stop = '[self.hidSupport.esp32Input stop];'
    for signature in ('- (void)beginStopStreamIfNeededWithReason:(NSString *)reason completion:',
                      '- (void)connectionTerminated:(int)errorCode'):
        assert stop in method(source, signature), signature
    prepare = method(source, '- (void)prepareForStreaming')
    assert prepare.index(stop) < prepare.index('self.hidSupport = [[HIDSupport alloc]')
    failure = method(close, '- (void)closeWindowFromMainQueueWithMessage:')
    assert failure.index(stop) < failure.index('dispatch_async(')
    print('ESP32 stream lifecycle wiring: passed (close, termination, retry and failed launch)')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='Check stream lifecycle wiring without macOS')
    args = parser.parse_args()
    check_lifecycle_wiring()
    if args.check:
        return
    if platform.system() != 'Darwin':
        raise SystemExit('This test requires macOS Foundation / NSURLSession.')
    with tempfile.TemporaryDirectory(prefix='esp32-native-') as directory:
        output = Path(directory)
        # Use the production Logger.h and a C/Objective-C implementation, so the
        # test catches Objective-C++ name-mangling regressions before Xcode link.
        logger_source=output/'logger.m'
        logger_source.write_text('#import "Logger.h"\nvoid LogTag(LogLevel level, NSString *tag, NSString *fmt, ...) {\n va_list args; va_start(args,fmt); NSString *line=[[NSString alloc] initWithFormat:fmt arguments:args]; va_end(args); NSLog(@"(%@) %@",tag,line); (void)level;\n}\n')
        logger_object=output/'logger.o'
        subprocess.run(['xcrun','clang','-fobjc-arc','-I',str(ROOT/'Limelight/Utility'),'-c',str(logger_source),'-o',str(logger_object)],check=True)
        for name in ('native', 'transport'):
            binary = output/name
            subprocess.run(['xcrun', 'clang++', '-std=c++14', '-include', str(ROOT/'Limelight/Utility/Logger.h'), '-fobjc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'CoreVideo', '-framework', 'VideoToolbox', '-framework', 'CoreMedia',
                            '-I', str(ROOT/'Limelight/Input/ESP32'), str(ROOT/f'tests/esp32/{name}.mm'),
                            str(ROOT/'Limelight/Input/ESP32/ESP32InputBridge.mm'), str(logger_object), '-o', str(binary)], check=True)
            if name == 'native':
                subprocess.run([str(binary)], check=True, timeout=10)
            else:
                check(binary, False)
                check(binary, True)
                check(binary, lifecycle=True)
                check(binary, macro=True)
                check(binary, macro=True, legacy=True)
                check(binary, vision=True)
    print('ESP32 native configuration and loopback WebSocket tests: passed')

if __name__ == '__main__':
    main()
