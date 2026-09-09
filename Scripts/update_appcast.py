#!/usr/bin/env python3
# update_appcast.py — Prepend a new release entry to appcast.xml
#
# Usage:
#   python3 Scripts/update_appcast.py <appcast.xml> <version> <sparkle_version> \
#       <pub_date> <ed_sig> <length> [notes.md]
#
# Arguments:
#   appcast.xml      Path to the appcast file to update
#   version          Marketing version string (e.g. 1.0.7)
#   sparkle_version  Integer build counter (e.g. 7)
#   pub_date         RFC 2822 UTC date string (e.g. "Thu, 18 Apr 2026 12:00:00 +0000")
#   ed_sig           EdDSA signature from sign_update
#   length           Byte size of the DMG
#   notes.md         Optional — path to markdown file for release notes
#                    If omitted, a placeholder is inserted.

import sys
import re
import os
import argparse
import base64
import hashlib
import html
import json
import plistlib
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import subprocess
from urllib.parse import quote
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from update_archive import extracted_update_app


SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
INHERITED_KEY = 'wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg='
REPOSITORY = Path(__file__).resolve().parents[1]


def validate_metadata(version, build, signature, length, architecture, public_key):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Version must be X.Y.Z')
    if not re.fullmatch(r'[1-9][0-9]*', str(build)):
        raise ValueError('Build must be a positive integer')
    if not re.fullmatch(r'[1-9][0-9]*', str(length)):
        raise ValueError('Archive length must be positive')
    if architecture not in ('arm64', 'x86_64', 'universal'):
        raise ValueError('Explicit architecture must be arm64, x86_64 or universal')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('EdDSA signature must contain 64 bytes')
    if public_key == INHERITED_KEY or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('A fork-owned 32-byte Sparkle public key is required')


def verify_archive(archive, signature, length, public_key):
    archive = Path(archive)
    if not archive.is_file() or archive.stat().st_size != int(length):
        raise ValueError('Signed archive is missing or its size changed')
    # This helper only uses the public key. Never expose/read a private key to
    # check that sign_update selected the correct Keychain account.
    subprocess.run(['swift', str(Path(__file__).with_name('verify-update-signature.swift')),
                    str(archive), public_key, signature], check=True)
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def published_asset_url(repository, version, archive_name, length, sha256):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid GitHub owner/repository')
    if Path(archive_name).name != archive_name or not archive_name.endswith(('.dmg', '.zip')):
        raise ValueError('Archive name must be a .dmg or .zip filename')
    # Use an unauthenticated API request: a draft/private asset visible only to
    # the maintainer must never become an update URL for ordinary users.
    request = Request(f'https://api.github.com/repos/{repository}/releases/tags/v{version}',
                      headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'OpenEmu-Reborn-release'})
    with urlopen(request, timeout=30) as response:
        release = json.load(response)
    if release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('Publish a stable GitHub Release before advertising its archive')
    url = f'https://github.com/{repository}/releases/download/v{version}/{quote(archive_name)}'
    assets = [asset for asset in release.get('assets', []) if asset.get('name') == archive_name]
    if len(assets) != 1:
        raise ValueError('Published release must have exactly one matching archive')
    asset = assets[0]
    if (asset.get('state') != 'uploaded' or asset.get('size') != int(length)
            or asset.get('browser_download_url') != url
            or asset.get('digest') != f'sha256:{sha256}'):
        raise ValueError('Published archive is not the exact signed local archive (URL, size or SHA-256 mismatch)')
    return url


def markdown_to_html(path):
    with open(path) as f:
        lines = f.read().splitlines()

    out = []
    in_ul = False
    for line in lines:
        if line.startswith('## '):
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<h3>{html.escape(line[3:].strip())}</h3>')
        elif re.match(r'^[-*] ', line):
            if not in_ul:
                out.append('<ul>')
                in_ul = True
            item = html.escape(line[2:].strip())
            item = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', item)
            out.append(f'<li>{item}</li>')
        elif line.strip():
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<p>{html.escape(line.strip())}</p>')

    if in_ul:
        out.append('</ul>')
    return '\n        '.join(out)


def render_feed(content, version, sparkle_version, pub_date, ed_sig, length, notes_html, url, architecture):
    existing = ET.fromstring(content)
    versions = [int(item.get(f'{{{SPARKLE}}}version')) for item in existing.findall('./channel/item/enclosure')
                if (item.get(f'{{{SPARKLE}}}version') or '').isdigit()]
    if int(sparkle_version) <= max(versions, default=0):
        raise ValueError('New build counter must be greater than every published appcast build')
    # Sparkle recognizes arm64 here, NOT an x86_64 exclusion. Intel-only
    # updates therefore need their own feed, checked before this function.
    hardware = '\n      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' if architecture == 'arm64' else ''
    new_item = f"""    <item>
      <title>OpenEmu Reborn {version}</title>
      <description>
        <![CDATA[
        <h2>OpenEmu Reborn {version}</h2>
        {notes_html}
        ]]>
      </description>
      <pubDate>{html.escape(pub_date)}</pubDate>
      <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>{hardware}
      <enclosure
        url="{html.escape(url, quote=True)}"
        sparkle:version="{sparkle_version}"
        sparkle:shortVersionString="{version}"
        sparkle:edSignature="{ed_sig}"
        length="{length}"
        type="application/octet-stream"/>
    </item>"""

    insert_after = re.search(r'(<language>[^<]*</language>\s*)', content)
    if not insert_after:
        raise ValueError('Could not find insertion point in appcast.xml')

    pos = insert_after.end()
    content = content[:pos] + new_item + '\n' + content[pos:]

    ET.fromstring(content)
    return content


def validate_feed_architecture(appcast, architecture, app_feed=None):
    appcast = Path(appcast).resolve()
    if appcast.parent != REPOSITORY:
        raise ValueError('A published appcast must be at the repository root')
    if architecture == 'x86_64' and appcast.name != 'appcast-x86_64.xml':
        raise ValueError('Thin Intel updates require appcast-x86_64.xml; Sparkle does not enforce an x86_64 hardware requirement')
    if appcast.name == 'appcast-x86_64.xml' and architecture == 'arm64':
        raise ValueError('Cannot advertise an ARM-only update in the Intel feed')
    repository = os.environ.get('OPENEMU_RELEASE_REPO', 'communism420/OpenEmu-Reborn')
    expected = f'https://raw.githubusercontent.com/{repository}/main/{appcast.name}'
    if app_feed is not None and app_feed != expected:
        raise ValueError('Packaged SUFeedURL does not match the appcast that will advertise this update')


def check_source_key(public_key):
    with (REPOSITORY / 'OpenEmu/OpenEmu-Info.plist').open('rb') as stream:
        source = plistlib.load(stream)
    if source.get('SUPublicEDKey') != public_key:
        raise ValueError('Archive key does not match the reviewed app source SUPublicEDKey')


def checked_app_metadata(app_path, appcast, architecture):
    with (Path(app_path) / 'Contents/Info.plist').open('rb') as stream:
        app = plistlib.load(stream)
    if app.get('CFBundleIdentifier') != 'org.openemu.OpenEmu':
        raise ValueError('Expected the OpenEmu Reborn app bundle identifier')
    validate_metadata(app['CFBundleShortVersionString'], app['CFBundleVersion'],
                      base64.b64encode(bytes(64)).decode(), 1, architecture, app['SUPublicEDKey'])
    check_source_key(app['SUPublicEDKey'])
    validate_feed_architecture(appcast, architecture, app.get('SUFeedURL'))
    # Read-only preflight, before asking the Keychain to sign any archive.
    render_feed(Path(appcast).read_text(encoding='utf-8'), app['CFBundleShortVersionString'],
                app['CFBundleVersion'], 'not published', '', 1, '',
                'https://example.invalid/not-published', architecture)
    return app


def require_feature_branch():
    branch = subprocess.check_output(['git', '-C', str(REPOSITORY), 'branch', '--show-current'], text=True).strip()
    if not branch or branch == 'main':
        raise ValueError('Create a new release feature branch from main before updating the appcast; review it in a PR')


def validate_archive_app(archive, metadata):
    """Bind advertised metadata to the signed archive, not a separate app/JSON."""
    with extracted_update_app(archive) as app:
        actual = checked_app_metadata(app, metadata['appcast'], metadata['architecture'])
        for key, field in [('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'build'),
                           ('SUPublicEDKey', 'public_key')]:
            if actual.get(key) != metadata[field]:
                raise ValueError(f'Archived app {key} does not match the proposed update metadata')
        expected_architectures = ['arm64', 'x86_64'] if metadata['architecture'] == 'universal' else [metadata['architecture']]
        for architecture in expected_architectures:
            subprocess.run(['bash', str(REPOSITORY / 'Scripts/verify-bundle-architectures.sh'),
                            '--arch', architecture, str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        certificate = metadata.get('certificate_sha1')
        if certificate:
            if not re.fullmatch(r'[A-Fa-f0-9]{40}', certificate):
                raise ValueError('Invalid expected code-signing certificate SHA-1')
            subprocess.run(['codesign', '--verify', '--strict', '--test-requirement',
                            f'=certificate leaf = H"{certificate}"', str(app)], check=True)


def prepare_manifest(argv):
    parser = argparse.ArgumentParser(description='Prepare verified metadata; does not publish or modify appcast.xml')
    parser.add_argument('--prepare-manifest', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--signature', required=True)
    parser.add_argument('--arch', required=True, choices=['arm64', 'x86_64', 'universal'])
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--appcast', type=Path, default=REPOSITORY / 'appcast.xml')
    parser.add_argument('--certificate-sha1')
    args = parser.parse_args(argv)
    if args.prepare_manifest.exists():
        raise ValueError('Prepared manifest already exists; do not overwrite a previously signed release')
    app = checked_app_metadata(args.app, args.appcast, args.arch)
    metadata = {
        'schema': 1, 'version': app['CFBundleShortVersionString'], 'build': app['CFBundleVersion'],
        'public_key': app['SUPublicEDKey'], 'signature': args.signature,
        'archive': str(args.archive.resolve()), 'length': args.archive.stat().st_size,
        'architecture': args.arch, 'appcast': str(args.appcast.resolve()),
        'notes_html': markdown_to_html(args.notes),
        'repository': os.environ.get('OPENEMU_RELEASE_REPO', 'communism420/OpenEmu-Reborn'),
        'certificate_sha1': args.certificate_sha1,
    }
    validate_metadata(metadata['version'], metadata['build'], metadata['signature'], metadata['length'],
                      metadata['architecture'], metadata['public_key'])
    for architecture in (['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch]):
        subprocess.run(['bash', str(REPOSITORY / 'Scripts/verify-bundle-architectures.sh'),
                        '--arch', architecture, str(args.app)], check=True)
    metadata['sha256'] = verify_archive(args.archive, args.signature, metadata['length'], metadata['public_key'])
    validate_archive_app(args.archive, metadata)
    # Check the build counter now too, without writing the result to the feed.
    render_feed(args.appcast.read_text(encoding='utf-8'), metadata['version'], metadata['build'],
                format_datetime(datetime.now(timezone.utc)), args.signature, metadata['length'],
                metadata['notes_html'], 'https://example.invalid/not-published', args.arch)
    with args.prepare_manifest.open('x', encoding='utf-8') as stream:
        json.dump(metadata, stream, indent=2)
        stream.write('\n')
    print(f'Prepared {args.prepare_manifest}; the live appcast was not changed')


def advertise_manifest(path):
    metadata = json.loads(Path(path).read_text(encoding='utf-8'))
    if metadata.get('schema') != 1:
        raise ValueError('Unsupported prepared update metadata')
    validate_metadata(metadata['version'], metadata['build'], metadata['signature'], metadata['length'],
                      metadata['architecture'], metadata['public_key'])
    check_source_key(metadata['public_key'])
    validate_feed_architecture(metadata['appcast'], metadata['architecture'])
    require_feature_branch()
    digest = verify_archive(metadata['archive'], metadata['signature'], metadata['length'], metadata['public_key'])
    if digest != metadata['sha256']:
        raise ValueError('Prepared archive changed after signing')
    validate_archive_app(metadata['archive'], metadata)
    url = published_asset_url(metadata['repository'], metadata['version'], Path(metadata['archive']).name,
                              metadata['length'], digest)
    appcast = Path(metadata['appcast'])
    result = render_feed(appcast.read_text(encoding='utf-8'), metadata['version'], metadata['build'],
                         format_datetime(datetime.now(timezone.utc)), metadata['signature'], metadata['length'],
                         metadata['notes_html'], url, metadata['architecture'])
    appcast.write_text(result, encoding='utf-8')
    print(f'Updated {appcast}. Commit on this feature branch, push and open a PR against main.')


def main():
    if '--validate-app' in sys.argv:
        parser = argparse.ArgumentParser(description='Read-only prebuilt app metadata preflight')
        parser.add_argument('--validate-app', required=True, type=Path)
        parser.add_argument('--arch', required=True, choices=['arm64', 'x86_64', 'universal'])
        parser.add_argument('--appcast', required=True, type=Path)
        args = parser.parse_args()
        checked_app_metadata(args.validate_app, args.appcast, args.arch)
        return print('PASS: prebuilt app version, key and update feed are consistent')
    if '--prepare-manifest' in sys.argv:
        return prepare_manifest(sys.argv[1:])
    if len(sys.argv) == 3 and sys.argv[1] == '--manifest':
        return advertise_manifest(sys.argv[2])
    parser = argparse.ArgumentParser(description='Advertise only a published, signed Reborn update. Never publishes a release.')
    parser.add_argument('appcast')
    parser.add_argument('version')
    parser.add_argument('sparkle_version')
    parser.add_argument('pub_date')
    parser.add_argument('ed_sig')
    parser.add_argument('length')
    parser.add_argument('notes_file')
    parser.add_argument('--arch', required=True, choices=['arm64', 'x86_64', 'universal'])
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--public-key', required=True)
    args = parser.parse_args()
    validate_metadata(args.version, args.sparkle_version, args.ed_sig, args.length, args.arch, args.public_key)
    check_source_key(args.public_key)
    validate_feed_architecture(args.appcast, args.arch)
    require_feature_branch()
    content = Path(args.appcast).read_text(encoding='utf-8')
    notes_html = markdown_to_html(args.notes_file)
    digest = verify_archive(args.archive, args.ed_sig, args.length, args.public_key)
    validate_archive_app(args.archive, {'appcast': args.appcast, 'architecture': args.arch,
        'version': args.version, 'build': args.sparkle_version, 'public_key': args.public_key})
    url = published_asset_url(os.environ.get('OPENEMU_RELEASE_REPO', 'communism420/OpenEmu-Reborn'),
                              args.version, args.archive.name, args.length, digest)
    content = render_feed(content, args.version, args.sparkle_version, args.pub_date,
                          args.ed_sig, args.length, notes_html, url, args.arch)
    Path(args.appcast).write_text(content, encoding='utf-8')

    print(f'Prepended v{args.version} ({args.arch}, build {args.sparkle_version}) to {args.appcast}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f'ERROR: {error}')
