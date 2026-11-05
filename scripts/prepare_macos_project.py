#!/usr/bin/env python3
"""Make the RC7 macOS target's source/resource membership explicit.

The imported project encodes native membership with synchronized folders.
Use an entirely explicit source/resource graph and ordinary groups, so Xcode
does not generate duplicate Core Data or resource tasks from mixed membership.
No input, codec, or renderer implementation is changed.
"""
from pathlib import Path
import hashlib
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT/'Moonlight.xcodeproj/project.pbxproj'

def object_id(label):
    return hashlib.sha1(('moonlight-esp32:' + label).encode()).hexdigest()[:24].upper()

def ordinary_groups(text):
    """Remove automatic folder membership after sources are materialized."""
    if 'PBXFileSystemSynchronizedRootGroup' not in text:
        return text
    root_id = 'A40F5A3F2D432ABE006DA227'
    version_ref = object_id('version-config')
    for section in ('PBXFileSystemSynchronizedBuildFileExceptionSet', 'PBXFileSystemSynchronizedRootGroup'):
        pattern = rf'/\* Begin {section} section \*/.*?/\* End {section} section \*/\n*'
        text, count = re.subn(pattern, '', text, flags=re.S)
        assert count == 1, section
    group = f'\t\t{root_id} /* Limelight */ = {{isa = PBXGroup; children = ({version_ref} /* Version.xcconfig */, ); path = Limelight; sourceTree = "<group>"; }};'
    text = text.replace('/* End PBXGroup section */', group + '\n/* End PBXGroup section */')
    version = f'\t\t{version_ref} /* Version.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Limelight/Version.xcconfig"; sourceTree = SOURCE_ROOT; }};'
    text = text.replace('/* End PBXFileReference section */', version + '\n/* End PBXFileReference section */')
    text, count = re.subn(
        rf'baseConfigurationReferenceAnchor = {root_id} /\* Limelight \*/;\s*baseConfigurationReferenceRelativePath = Version.xcconfig;',
        f'baseConfigurationReference = {version_ref} /* Version.xcconfig */;', text)
    assert count == 2, 'App version configuration references'
    return text

def core_data_sources(text):
    """Model code generation must compile its classes in the Sources phase."""
    model = object_id('build:Limelight/Limelight.xcdatamodeld')
    old = 'Limelight.xcdatamodeld in Resources'
    if old not in text:
        return text
    entry = f'\t\t\t\t{model} /* {old} */,\n'
    assert text.count(entry) == 1, 'Core Data resource membership'
    text = text.replace(entry, '')
    anchor = 'D30000020000000000000002 /* SettingsSearchIndex.generated.swift in Sources */,'
    assert text.count(anchor) == 1, 'App Sources phase'
    text = text.replace(anchor, anchor + '\n' + entry.rstrip('\n'))
    return text.replace(old, 'Limelight.xcdatamodeld in Sources')

def prepare():
    text = PROJECT.read_text()
    if '/* Native macOS explicit membership */' in text:
        converted = core_data_sources(ordinary_groups(text))
        if converted != text:
            PROJECT.write_text(converted, newline='\n')
            print('Updated explicit native Xcode target membership.')
        else:
            print('Native macOS target membership already materialized.')
        return
    match = re.search(r'membershipExceptions = \((.*?)\);', text, re.S)
    assert match
    paths = [line.strip().rstrip(',').strip('"').lstrip('/') for line in match[1].splitlines() if line.strip()]
    objects = []
    file_refs = []
    build_refs = []
    resources = []
    group_refs = []
    extra_sections = []
    source_types = {'.m': 'sourcecode.c.objc', '.c': 'sourcecode.c.c', '.swift': 'sourcecode.swift'}
    resource_types = {'.xib': 'file.xib', '.xcassets': 'folder.assetcatalog', '.txt': 'text', '.tsv': 'text'}
    for relative in paths:
        if relative == 'Localized/macOS/Main.storyboard':
            relative = 'macOS/Base.lproj/Main.storyboard'
        path = Path('Limelight')/relative
        if path.suffix == '.sh':
            continue
        assert (ROOT/path).exists(), path
        ref = object_id(str(path))
        build = object_id('build:' + str(path))
        label = path.name
        group_refs.append(f'\t\t\t\t{ref} /* {label} */,')
        if path.suffix == '.xcdatamodeld':
            current = plistlib.loads((ROOT/path/'.xccurrentversion').read_bytes())['_XCCurrentVersionName']
            children = []
            for model in sorted((ROOT/path).glob('*.xcdatamodel')):
                child = object_id(str(path/model.name))
                file_refs.append(f'\t\t{child} /* {model.name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcdatamodel; path = "{model.name}"; sourceTree = "<group>"; }};')
                children.append(f'\t\t\t\t{child} /* {model.name} */,')
            extra_sections.append(f'\t\t{ref} /* {label} */ = {{\n\t\t\tisa = XCVersionGroup;\n\t\t\tchildren = (\n' + '\n'.join(children) + f'\n\t\t\t);\n\t\t\tcurrentVersion = {object_id(str(path/current))};\n\t\t\tpath = "{path.as_posix()}";\n\t\t\tsourceTree = SOURCE_ROOT;\n\t\t\tversionGroupType = wrapper.xcdatamodel;\n\t\t}};')
        elif path.suffix == '.storyboard':
            child = object_id(str(path) + ':base')
            file_refs.append(f'\t\t{child} /* Base */ = {{isa = PBXFileReference; lastKnownFileType = file.storyboard; name = Base; path = "{path.as_posix()}"; sourceTree = SOURCE_ROOT; }};')
            extra_sections.append(f'\t\t{ref} /* {label} */ = {{isa = PBXVariantGroup; children = ({child} /* Base */, ); name = Main.storyboard; sourceTree = "<group>"; }};')
        else:
            kind = source_types.get(path.suffix) or resource_types.get(path.suffix)
            assert kind, path
            file_refs.append(f'\t\t{ref} /* {label} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path.as_posix()}"; sourceTree = SOURCE_ROOT; }};')
        phase = 'Sources' if path.suffix in source_types or path.suffix == '.xcdatamodeld' else 'Resources'
        objects.append(f'\t\t{build} /* {label} in {phase} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {label} */; }};')
        (build_refs if phase == 'Sources' else resources).append(f'\t\t\t\t{build} /* {label} in {phase} */,')
    group = object_id('native-group')
    group_object = f'\t\t{group} /* Native macOS explicit membership */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + '\n'.join(group_refs) + '\n\t\t\t);\n\t\t\tname = "Native macOS explicit membership";\n\t\t\tsourceTree = "<group>";\n\t\t};'
    text = text.replace('/* End PBXBuildFile section */', '\n'.join(objects) + '\n/* End PBXBuildFile section */')
    text = text.replace('/* End PBXFileReference section */', '\n'.join(file_refs) + '\n/* End PBXFileReference section */')
    text = text.replace('/* End PBXGroup section */', group_object + '\n/* End PBXGroup section */')
    text = text.replace('/* Begin XCBuildConfiguration section */', '/* Begin Native macOS membership model groups */\n' + '\n'.join(extra_sections) + '\n/* End Native macOS membership model groups */\n\n/* Begin XCBuildConfiguration section */')
    text = text.replace('4CD17E9B2733C0FC004D438C /* README.md */,', f'4CD17E9B2733C0FC004D438C /* README.md */,\n\t\t\t\t{group} /* Native macOS explicit membership */,')
    text = text.replace('D30000020000000000000002 /* SettingsSearchIndex.generated.swift in Sources */,', 'D30000020000000000000002 /* SettingsSearchIndex.generated.swift in Sources */,\n' + '\n'.join(build_refs))
    text = text.replace('A4B1C1002D9F0A1B00C0FF10 /* InfoPlist.strings in Resources */,', 'A4B1C1002D9F0A1B00C0FF10 /* InfoPlist.strings in Resources */,\n' + '\n'.join(resources))
    text = re.sub(r'^\s*[A-F0-9]{24} /\* \(null\) in Sources \*/[^\n]*\n', '', text, flags=re.M)
    text = text.replace('HEADER_SEARCH_PATHS = (', 'USER_HEADER_SEARCH_PATHS = "$(PROJECT_DIR)/Limelight/**";\n\t\t\t\tHEADER_SEARCH_PATHS = (')
    PROJECT.write_text(ordinary_groups(text), newline='\n')
    print(f'Materialized {len(build_refs)} native source files and {len(resources)} resources.')

if __name__ == '__main__':
    prepare()
