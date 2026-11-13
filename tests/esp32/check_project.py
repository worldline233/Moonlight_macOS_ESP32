#!/usr/bin/env python3
"""Validate the actual OpenStep project graph, app identity, and native inputs."""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]

def parse(text):
    pattern = r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^{}()=;,\s]+'
    tokens = [m.group() for m in re.finditer(pattern, text, re.S) if not m.group().startswith(('/*', '//'))]
    index = 0
    def read():
        nonlocal index
        token = tokens[index]
        index += 1
        if token == '{':
            result = {}
            while tokens[index] != '}':
                key = read()
                assert tokens[index] == '=', (key, tokens[index])
                index += 1
                assert key not in result, ('duplicate project key', key)
                result[key] = read()
                assert tokens[index] == ';', (key, tokens[index])
                index += 1
            index += 1
            return result
        if token == '(':
            result = []
            while tokens[index] != ')':
                result.append(read())
                if tokens[index] == ',':
                    index += 1
                else:
                    assert tokens[index] == ')'
            index += 1
            return result
        return json.loads(token) if token.startswith('"') else token
    result = read()
    assert index == len(tokens)
    return result

def main():
    project = parse((ROOT/'Moonlight.xcodeproj/project.pbxproj').read_text())
    objects = project['objects']
    assert not any(obj.get('isa', '').startswith('PBXFileSystemSynchronized') for obj in objects.values()), 'Explicit target must not also generate automatic synchronized-folder tasks'
    target = objects['4C7E0A791FECBFFD00684411']
    sources, resources = [], []
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        if phase['isa'] not in ('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase'):
            continue
        result = sources if phase['isa'] == 'PBXSourcesBuildPhase' else resources
        for build_id in phase['files']:
            ref = objects[objects[build_id]['fileRef']]
            if ref['isa'] == 'PBXVariantGroup':
                result += [objects[child].get('path', '') for child in ref['children']]
            else:
                result.append(ref['path'])
    assert len(sources) == len(set(sources)), 'Duplicate source compilation'
    assert len(resources) == len(set(resources)), 'Duplicate resource compilation'
    for path in sources + resources:
        assert (ROOT/path).exists(), path
    for path in ('Limelight/Input/HIDSupport.m', 'Limelight/Input/HIDSupport+Pointer.m',
                 'Limelight/Input/CoreHIDMouseDriver.swift', 'Limelight/Stream/VideoDecoderRenderer.m',
                 'Limelight/Input/ESP32/ESP32InputBridge.mm',
                 'Limelight/macOS/ViewControllers/ESP32SettingsSection.swift'):
        assert path in sources, path
    assert 'Limelight/macOS/Base.lproj/Main.storyboard' in resources
    assert 'Limelight/Limelight.xcdatamodeld' in sources, 'Core Data code generation must compile its classes'
    assert 'Limelight/Limelight.xcdatamodeld' not in resources
    assert 'Limelight/macOS/Helpers/AwdlPrivilegedHelperMain.m' not in sources
    assert 'Limelight/Input/StreamView.m' not in sources
    for config in objects.values():
        settings = config.get('buildSettings', {})
        if settings.get('PRODUCT_NAME') == 'MoonlightESP32':
            assert settings['PRODUCT_BUNDLE_IDENTIFIER'] == 'org.worldline233.MoonlightMacESP32'
            assert settings['PRODUCT_MODULE_NAME'] == 'MoonlightEnhanced'
            assert not settings['SPARKLE_FEED_URL'] and not settings['SPARKLE_ED_PUBLIC_KEY']
    for relative in ('Moonlight.entitlements', 'FileProviderExtension/FileProvider.entitlements'):
        entitlements = plistlib.loads((ROOT/relative).read_bytes())
        assert entitlements['com.apple.security.application-groups'] == ['group.org.worldline233.MoonlightMacESP32']
    info = plistlib.loads((ROOT/'Limelight/macOS/Supporting Files/Info.plist').read_bytes())
    assert info['ESP32DevelopmentBuild'] and not info['SUEnableAutomaticChecks']
    ET.parse(ROOT/'Moonlight.xcodeproj/xcshareddata/xcschemes/Moonlight for macOS.xcscheme')
    for path in ('Limelight/Input/CoreHIDMouseDriver.swift', 'Limelight/Stream/VideoDecoderRenderer.m'):
        upstream = subprocess.check_output(['git', 'show', 'c4dd84daa6440468f4e9a2e48f8c482f24bec965:' + path], cwd=ROOT).decode().replace('\r\n', '\n')
        actual = (ROOT/path).read_text()
        if path.endswith('VideoDecoderRenderer.m'):
            observer = ('    void (^observer)(CVPixelBufferRef) = self.decodedFrameObserver;\n'
                        '    if (observer) observer(imageBuffer);\n')
            assert actual.count(observer) == 1, 'Only one observer hook is permitted'
            actual = actual.replace(observer, '')
            actual = actual.replace('    BOOL _esp32VisionLinearFrames;\n', '')
            actual = actual.replace('    _esp32VisionLinearFrames = streamConfig.esp32VisionLinearFrames;\n', '')
            actual = actual.replace('if (_activeRendererMode == MLActiveVideoRendererModeEnhanced || _esp32VisionLinearFrames)', 'if (_activeRendererMode == MLActiveVideoRendererModeEnhanced)')
            actual = actual.replace('        if (_esp32VisionLinearFrames) LogTag(LOG_I,@"ESP32",@"[pixel-output] requested_linear=0x%08x renderer=%@",(unsigned)requestedFormat,[self activeRendererModeName:_activeRendererMode]);\n', '')
        assert actual == upstream, ('upstream implementation changed beyond observer', path)
    print(f'Project graph: passed ({len(sources)} sources, {len(resources)} resources; separate identity; upstream CoreHID/video retained)')

if __name__ == '__main__':
    main()
