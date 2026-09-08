#!/usr/bin/env python3
"""Strictly merge two matching verified CI bundles; never build, sign or install.

Inputs are directories emitted by package-ci-artifact.py (ZIP + BUILD-INFO.json).
The output is a new directory containing a universal bundle and merge provenance.
It is deliberately NOT signed/ready to publish; sign and verify it separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

IDENTITY_FIELDS = ('schema', 'kind', 'name', 'source_repository', 'source_sha', 'configuration',
                   'bundle_identifier', 'bundle_version', 'bundle_short_version', 'xcode',
                   'generated_tracked_files_sha256')
# These describe the machine/tool build, not runtime compatibility. Never
# discard deployment targets, versions, entitlements or other app behavior.
BUILD_ONLY_KEYS = frozenset(('BuildMachineOSBuild', 'DTPlatformBuild', 'DTSDKBuild', 'DTXcode', 'DTXcodeBuild'))


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def artifact(directory, architecture, source_sha, repository):
    directory = Path(directory).resolve(strict=True)
    metadata = json.loads((directory / 'BUILD-INFO.json').read_text())
    if (metadata.get('schema') != 1 or metadata.get('architecture') != architecture
            or metadata.get('configuration') != 'Release' or metadata.get('source_sha') != source_sha
            or metadata.get('source_repository') != repository):
        raise ValueError(f'{architecture} artifact source, architecture or schema does not match')
    if metadata.get('kind') not in ('host', 'core') or not re.fullmatch(r'[A-Za-z0-9]+', metadata.get('name', '')):
        raise ValueError('Invalid artifact kind/name')
    extension = '.app' if metadata['kind'] == 'host' else '.oecoreplugin'
    name = metadata['name'] + extension
    if metadata['kind'] == 'host' and metadata['name'] != 'OpenEmu':
        raise ValueError('Unexpected host artifact')
    archive_name = metadata.get('archive', '')
    if archive_name != f'{metadata["name"]}-{architecture}{extension}.zip':
        raise ValueError('Unexpected archive filename')
    archive = directory / archive_name
    if archive.is_symlink() or archive.stat().st_size != metadata.get('archive_size') or digest(archive) != metadata.get('archive_sha256'):
        raise ValueError('Artifact ZIP does not match its recorded size/SHA-256')
    if not {'bundle-architecture', 'codesign-deep-strict', 'zip-crc', 'archived-info-plist'}.issubset(metadata.get('checks', [])):
        raise ValueError('Artifact lacks required build verification metadata')
    return metadata, archive, name


def extract_archive(archive_path, destination, bundle_name):
    """Extract only this bundle, rejecting traversal, special files and escapes."""
    destination.mkdir()
    seen = set()
    links = []
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            path = PurePosixPath(member.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in member.filename
                    or not path.parts or path.parts[0] != bundle_name or str(path) in seen):
                raise ValueError('Unsafe/duplicate path in CI archive')
            seen.add(str(path))
            mode = member.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK):
                raise ValueError('Special file in CI archive')
            target = destination.joinpath(*path.parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif kind == stat.S_IFLNK:
                link = archive.read(member).decode('utf-8')
                if not link or os.path.isabs(link):
                    raise ValueError('Absolute/empty symlink in CI archive')
                links.append((target, link))
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as stream, archive.open(member) as source:
                    shutil.copyfileobj(source, stream)
                target.chmod(stat.S_IMODE(mode) or 0o644)
    # Create links last: archive entries can never write through a symlink.
    bundle = destination / bundle_name
    for target, link in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link)
    for target, _ in links:
        resolved = target.resolve(strict=True)
        if resolved != bundle and bundle not in resolved.parents:
            raise ValueError('Symlink escapes the extracted bundle')
    return bundle


def inventory(bundle):
    paths = {}
    for root, directories, files in os.walk(bundle, followlinks=False):
        directories[:] = [name for name in directories if name != '_CodeSignature']
        for name in directories + files:
            path = Path(root) / name
            relative = path.relative_to(bundle)
            if '_CodeSignature' in relative.parts:
                continue
            paths[relative] = ('symlink' if path.is_symlink() else 'directory' if path.is_dir() else 'file')
    return paths


def architectures(path):
    process = subprocess.run(['lipo', '-archs', str(path)], text=True, capture_output=True)
    return set(process.stdout.split()) if process.returncode == 0 else set()


def is_swift_arch_resource(relative, architecture):
    return (any(part.endswith('.swiftmodule') for part in relative.parts[:-1])
            and relative.name.startswith((architecture + '-', architecture + '.'))
            and relative.suffix in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.swiftinterface', '.json'))


def merge_bundle(arm, intel, destination, scratch):
    inventories = {'arm64': inventory(arm), 'x86_64': inventory(intel)}
    roots = {'arm64': arm, 'x86_64': intel}
    destination.mkdir()
    report = {'merged_binaries': [], 'normalized_info_plists': [], 'swift_resources': []}
    all_paths = sorted(set(inventories['arm64']) | set(inventories['x86_64']), key=lambda value: (len(value.parts), str(value)))
    for relative in all_paths:
        types = {architecture: paths.get(relative) for architecture, paths in inventories.items()}
        present = [architecture for architecture, kind in types.items() if kind is not None]
        output = destination / relative
        if len(present) == 1:
            architecture = present[0]
            if types[architecture] != 'file' or not is_swift_arch_resource(relative, architecture):
                raise ValueError(f'Unexpected one-architecture resource: {relative}')
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(roots[architecture] / relative, output)
            report['swift_resources'].append(str(relative))
            continue
        if types['arm64'] != types['x86_64']:
            raise ValueError(f'Bundle path types differ: {relative}')
        arm_file, intel_file = arm / relative, intel / relative
        if types['arm64'] == 'directory':
            output.mkdir(exist_ok=True)
            continue
        if types['arm64'] == 'symlink':
            if os.readlink(arm_file) != os.readlink(intel_file):
                raise ValueError(f'Symlink targets differ: {relative}')
            output.symlink_to(os.readlink(arm_file))
            continue
        if stat.S_IMODE(arm_file.stat().st_mode) != stat.S_IMODE(intel_file.stat().st_mode):
            raise ValueError(f'File permissions differ: {relative}')
        arm_arches, intel_arches = architectures(arm_file), architectures(intel_file)
        if arm_arches or intel_arches:
            if 'arm64' not in arm_arches or 'x86_64' not in intel_arches:
                raise ValueError(f'Missing expected Mach-O/static archive slice: {relative}')
            slices = []
            for architecture, binary, available in [('arm64', arm_file, arm_arches), ('x86_64', intel_file, intel_arches)]:
                thin = scratch / ('.thin-' + architecture)
                if len(available) == 1:
                    shutil.copyfile(binary, thin)
                else:
                    subprocess.run(['lipo', str(binary), '-thin', architecture, '-output', str(thin)], check=True)
                slices.append(str(thin))
            subprocess.run(['lipo', '-create', *slices, '-output', str(output)], check=True)
            output.chmod(stat.S_IMODE(arm_file.stat().st_mode))
            subprocess.run(['lipo', str(output), '-verify_arch', 'arm64', 'x86_64'], check=True)
            report['merged_binaries'].append(str(relative))
        elif digest(arm_file) == digest(intel_file):
            shutil.copy2(arm_file, output)
        elif relative.name == 'Info.plist' and relative.parent.name in ('Contents', 'Resources'):
            arm_info, intel_info = plistlib.loads(arm_file.read_bytes()), plistlib.loads(intel_file.read_bytes())
            arm_normalized = {key: value for key, value in arm_info.items() if key not in BUILD_ONLY_KEYS}
            intel_normalized = {key: value for key, value in intel_info.items() if key not in BUILD_ONLY_KEYS}
            if arm_normalized != intel_normalized:
                raise ValueError(f'Runtime Info.plist values differ: {relative}')
            output.write_bytes(plistlib.dumps(arm_normalized))
            report['normalized_info_plists'].append(str(relative))
        else:
            raise ValueError(f'Non-code resources differ; rebuild universally instead of choosing one: {relative}')
    if not report['merged_binaries']:
        raise ValueError('No matching Mach-O/static archives found to merge')
    return report


def assemble(args):
    if not re.fullmatch(r'[0-9a-f]{40}', args.source_sha):
        raise ValueError('An exact 40-hex source SHA is required')
    arm_meta, arm_zip, name = artifact(args.arm64_artifact, 'arm64', args.source_sha, args.repository)
    intel_meta, intel_zip, intel_name = artifact(args.x86_64_artifact, 'x86_64', args.source_sha, args.repository)
    for field in IDENTITY_FIELDS + ('mame_upstream_revision', 'mame_patch_sha256'):
        if arm_meta.get(field) != intel_meta.get(field):
            raise ValueError(f'Artifact provenance differs: {field}')
    if name != intel_name:
        raise ValueError('Bundle names differ')
    destination = args.output.resolve()
    if args.output.is_symlink() or destination.exists():
        raise ValueError('Output must be a new directory; existing builds are never replaced')
    for source in (args.arm64_artifact.resolve(), args.x86_64_artifact.resolve()):
        if destination == source or source in destination.parents:
            raise ValueError('Output must be outside both input artifact directories')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.reborn-merge-', dir=destination.parent) as directory:
        temporary = Path(directory)
        arm = extract_archive(arm_zip, temporary / 'arm64', name)
        intel = extract_archive(intel_zip, temporary / 'x86_64', name)
        for bundle, metadata in [(arm, arm_meta), (intel, intel_meta)]:
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            for key, field in [('CFBundleIdentifier', 'bundle_identifier'), ('CFBundleVersion', 'bundle_version'),
                               ('CFBundleShortVersionString', 'bundle_short_version')]:
                if info.get(key, '') != metadata[field]:
                    raise ValueError('Extracted bundle metadata differs from BUILD-INFO.json')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        staged = temporary / 'output'
        staged.mkdir()
        report = merge_bundle(arm, intel, staged / name, temporary)
        result = {field: arm_meta[field] for field in IDENTITY_FIELDS}
        result.update({'architecture': 'universal', 'bundle_signed': False, 'ready_to_publish': False,
                       'input_archives_sha256': {'arm64': arm_meta['archive_sha256'], 'x86_64': intel_meta['archive_sha256']},
                       'merge': report})
        (staged / 'BUILD-INFO.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        # All validation/merging succeeds before exposing any output. mkdir
        # reserves the destination without replacing a path created by others.
        destination.mkdir(exist_ok=False)
        for item in staged.iterdir():
            item.rename(destination / item.name)
    print(f'Merged {name} from {args.source_sha}: {destination}')
    print('NOT signed or ready to publish. Sign inside-out and verify separately before packaging.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arm64-artifact', type=Path, required=True)
    parser.add_argument('--x86_64-artifact', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--repository', default='communism420/OpenEmu-Reborn')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        assemble(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
