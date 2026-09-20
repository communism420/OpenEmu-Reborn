#!/usr/bin/env python3
"""Stage and certificate-sign a verified universal host + 28 premerged cores.

No building, installation, registration, network, Git, key creation or trust
changes. Inputs are never modified. CI/source verification belongs to the
caller; --source-sha is recorded as caller-provided provenance, not inferred.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORES = ('4DO Atari800 Bliss BSNES CrabEmu DeSmuME Dolphin FCEU Flycast Gambatte '
         'GenesisPlus JollyCV MAME Mednafen mGBA Mupen64Plus Nestopia O2EM Picodrive '
         'PokeMini Potator PPSSPP ProSystem SNES9x Stella VecXGL VirtualJaguar blueMSX').split()
BUNDLE_SUFFIXES = {'.framework', '.xpc', '.app', '.appex', '.qlgenerator', '.oesystemplugin', '.bundle', '.oecoreplugin'}


def run(command, capture=False):
    # codesign writes display/requirements output to stderr, unlike security.
    return subprocess.run([str(value) for value in command], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None).stdout


def safe_directory(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=True) != path:
        raise ValueError(f'Use an existing, absolute, nonsymlink directory: {path}')
    mode = path.stat()
    if not path.is_dir() or mode.st_uid != os.geteuid() or mode.st_mode & 0o022:
        raise ValueError(f'Directory must be owned by the current user and not group/world-writable: {path}')
    for ancestor in (path, *path.parents):
        if (ancestor / '.openemu-data-folder.plist').exists():
            raise ValueError('A selected OpenEmu data folder is not a build input/output')
    return path


def fingerprint(directory):
    digest = hashlib.sha256()
    entries = []
    def read_error(error):
        raise error
    for root, directories, files in os.walk(directory, followlinks=False, onerror=read_error):
        entries.extend(Path(root) / name for name in directories + files)
    for path in sorted(entries):
        relative = path.relative_to(directory)
        if path.name == '.openemu-data-folder.plist':
            raise ValueError('A bundle contains selected data-folder metadata')
        info = path.lstat()
        digest.update((str(relative) + '\0' + str(info.st_mode) + '\0').encode())
        if stat.S_ISLNK(info.st_mode):
            target = path.resolve(strict=True)
            if target != directory and directory not in target.parents:
                raise ValueError(f'Bundle symlink escapes the input: {relative}')
            digest.update(os.readlink(path).encode())
        elif stat.S_ISREG(info.st_mode):
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, 'rb') as stream:
                current = os.fstat(stream.fileno())
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise ValueError('Input changed while fingerprinting')
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError(f'Special file in bundle: {relative}')
        digest.update(b'\0')
    return digest.hexdigest()


def macho_filetypes(path):
    """Read headers only; distinguish executable Mach-O from static archives."""
    with path.open('rb') as stream:
        magic = stream.read(4)
        thin = {b'\xce\xfa\xed\xfe': '<', b'\xcf\xfa\xed\xfe': '<',
                b'\xfe\xed\xfa\xce': '>', b'\xfe\xed\xfa\xcf': '>'}
        fat = {b'\xca\xfe\xba\xbe': ('>', 20), b'\xbe\xba\xfe\xca': ('<', 20),
               b'\xca\xfe\xba\xbf': ('>', 32), b'\xbf\xba\xfe\xca': ('<', 32)}
        if magic in thin:
            stream.seek(12)
            return {struct.unpack(thin[magic] + 'I', stream.read(4))[0]}
        if magic not in fat:
            return set()
        endian, size = fat[magic]
        count = struct.unpack(endian + 'I', stream.read(4))[0]
        if not 1 <= count <= 32:
            raise ValueError('Invalid universal Mach-O header')
        filetypes = set()
        for index in range(count):
            stream.seek(8 + size * index + 8)
            offset = struct.unpack(endian + ('Q' if size == 32 else 'I'), stream.read(8 if size == 32 else 4))[0]
            stream.seek(offset)
            slice_magic = stream.read(4)
            if slice_magic not in thin:
                # Universal static archives contain archive headers, not code.
                continue
            stream.seek(offset + 12)
            filetypes.add(struct.unpack(thin[slice_magic] + 'I', stream.read(4))[0])
        return filetypes


def verify_architectures(bundle):
    for architecture in ('arm64', 'x86_64'):
        run(['bash', ROOT / 'Scripts/verify-bundle-architectures.sh', '--arch', architecture, bundle])


def certificate_verify(bundle, identity):
    run(['codesign', '--verify', '--deep', '--strict', bundle])
    run(['codesign', '--verify', '--strict', '--test-requirement', f'=certificate leaf = H"{identity}"', bundle])


def sign_core(bundle, identity):
    # These are newly created staging copies. Never --deep sign: explicitly
    # seal binaries, then nested bundles inside-out, then this core's bundle.
    entries = []
    for root, directories, files in os.walk(bundle, followlinks=False):
        entries.extend(Path(root) / name for name in directories + files)
    for binary in sorted(entries):
        if binary.is_symlink() or not binary.is_file():
            continue
        types = macho_filetypes(binary)
        if types & {2, 6, 8}:  # MH_EXECUTE, MH_DYLIB, MH_BUNDLE
            if not types.issubset({2, 6, 8}):
                raise ValueError(f'Unexpected mixed executable/object slices: {binary}')
            run(['codesign', '--force', '--sign', identity, '--timestamp=none',
                 '--preserve-metadata=identifier,flags,entitlements', binary])
    bundles = [entry for entry in entries if not entry.is_symlink() and entry.is_dir() and entry.suffix in BUNDLE_SUFFIXES]
    for nested in sorted(bundles, key=lambda value: len(value.parts), reverse=True) + [bundle]:
        run(['codesign', '--force', '--sign', identity, '--timestamp=none',
             '--preserve-metadata=identifier,flags,entitlements', nested])
    certificate_verify(bundle, identity)


def stage(args):
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', args.signing_identity):
        raise ValueError('An exact 40-hex certificate SHA-1 is required; no ad-hoc fallback')
    if not re.fullmatch(r'[a-f0-9]{40}', args.source_sha):
        raise ValueError('Record the exact verified CI source commit with --source-sha')
    identity = args.signing_identity.upper()
    host, cores = safe_directory(args.host), safe_directory(args.cores)
    output = args.output
    canonical = ROOT / 'OpenEmu-Intel-test'
    if (not output.is_absolute() or output.is_symlink() or output.exists()
            or output == canonical or canonical in output.parents
            or host in output.parents or cores in output.parents):
        raise ValueError('Output must be a new absolute staging directory outside inputs and the canonical package')
    safe_directory(output.parent)
    if host.name != 'OpenEmu.app':
        raise ValueError('Expected an unbundled OpenEmu.app host')
    inputs = {host: fingerprint(host)}
    with (host / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'org.openemu.OpenEmu' or info.get('CFBundleExecutable') != 'OpenEmu':
        raise ValueError('Unexpected host identity')
    old_cores = host / 'Contents/PlugIns/Cores'
    if old_cores.exists() and (old_cores.is_symlink() or not old_cores.is_dir() or any(old_cores.iterdir())):
        raise ValueError('Host already contains cores; old bundles must not be merged into staging')
    expected_names = {name + '.oecoreplugin' for name in CORES}
    if {path.name for path in cores.iterdir()} != expected_names:
        raise ValueError('Core input must contain exactly the 28 expected premerged bundles')
    for name in CORES:
        core = safe_directory(cores / (name + '.oecoreplugin'))
        inputs[core] = fingerprint(core)
        verify_architectures(core)
    verify_architectures(host)
    run(['codesign', '--verify', '--deep', '--strict', host])
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture=True)
    available = {value.upper() for value in re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s', identities, re.MULTILINE)}
    if identity not in available:
        raise ValueError('The exact valid code-signing identity is unavailable; no key/trust changes will be made')
    with tempfile.TemporaryDirectory(prefix='.reborn-stage-', dir=output.parent) as directory:
        staging = Path(directory)
        app = staging / 'OpenEmu.app'
        run(['ditto', host, app])
        if fingerprint(app) != inputs[host]:
            raise ValueError('Host copy differs from its verified input')
        target_cores = app / 'Contents/PlugIns/Cores'
        target_cores.mkdir(parents=True, exist_ok=True)
        for name in CORES:
            source = cores / (name + '.oecoreplugin')
            target = target_cores / source.name
            run(['ditto', source, target])
            if fingerprint(target) != inputs[source]:
                raise ValueError(f'Core copy differs from input: {name}')
            sign_core(target, identity)
        run(['codesign', '--force', '--sign', identity, '--timestamp=none',
             '--preserve-metadata=identifier,flags', '--entitlements', ROOT / 'OpenEmu/OpenEmu.entitlements', app])
        certificate_verify(app, identity)
        verify_architectures(app)
        for architecture in ('arm64', 'x86_64'):
            requirements = run(['codesign', '--display', '--architecture', architecture, '--requirements', '-', app], capture=True)
            if not re.search(r'designated => .+', requirements) or re.search(r'\bcdhash\b', requirements):
                raise ValueError('Signed host lacks a stable certificate-based designated requirement')
        for path, expected in inputs.items():
            if fingerprint(path) != expected:
                raise ValueError(f'Input changed during staging: {path}')
        report = {'schema': 1, 'architecture': 'universal', 'source_sha': args.source_sha,
            'source_attribution': 'caller-verified CI artifacts; this script does not infer source provenance',
            'certificate_sha1': identity, 'bundle_version': info.get('CFBundleVersion'),
            'bundle_short_version': info.get('CFBundleShortVersionString'),
            'input_bundle_fingerprints': {str(path): value for path, value in inputs.items()},
            'output_bundle_fingerprint': fingerprint(app), 'bundled_cores': CORES,
            'checks': ['both-architectures-all-binaries', 'deep-strict-codesign', 'exact-certificate', 'input-copies-and-inputs-unchanged'],
            'registration_requested': False, 'ready_to_publish': False}
        (staging / 'STAGING-INFO.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
        output.mkdir(mode=0o700, exist_ok=False)
        for child in staging.iterdir():
            child.rename(output / child.name)
    print(f'Prepared signed universal staging app: {output / "OpenEmu.app"}')
    print('No input, installed app, registration, trust or permission was changed. Test and package this staging app separately.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--cores', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--signing-identity', required=True)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    try:
        stage(args)
    except (ValueError, OSError, subprocess.CalledProcessError, struct.error) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
