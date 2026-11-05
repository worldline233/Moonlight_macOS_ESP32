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
    assert len(payload) < 126
    stream.write(bytes([0x80 | opcode, len(payload)]) + payload)
    stream.flush()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def __init__(self, bad=False):
        self.bad = bad
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
                             'keyboard_nkro': True, 'keyboard_max_keys': 6 if self.server.bad else 16}
                    encoded = json.dumps(reply, separators=(',', ':')).encode()
                    send_frame(self.wfile, 1, encoded)
        except (EOFError, BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            with self.server.lock:
                self.server.errors.append(repr(error))

def check(binary, bad=False, lifecycle=False):
    server = Server(bad)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        mode = 'lifecycle' if lifecycle else ('bad' if bad else 'good')
        subprocess.run([str(binary), str(server.server_address[1]), mode], check=True, timeout=20)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)
    assert not server.errors, server.errors
    connections = [records for records in server.connections if records]
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
    assert any(m.get('buttons') == [] for m in first)
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
        for name in ('native', 'transport'):
            binary = output/name
            subprocess.run(['xcrun', 'clang++', '-std=c++14', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                            '-I', str(ROOT/'Limelight/Input/ESP32'), str(ROOT/f'tests/esp32/{name}.mm'),
                            str(ROOT/'Limelight/Input/ESP32/ESP32InputBridge.mm'), '-o', str(binary)], check=True)
            if name == 'native':
                subprocess.run([str(binary)], check=True, timeout=10)
            else:
                check(binary, False)
                check(binary, True)
                check(binary, lifecycle=True)
    print('ESP32 native configuration and loopback WebSocket tests: passed')

if __name__ == '__main__':
    main()
