"""Inspect app update archives without executing/registering their apps."""
from contextlib import contextmanager
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unicodedata
import zipfile


def extract_app_zip(archive_path, destination):
    seen = set()
    links = []
    expanded = 0
    with zipfile.ZipFile(archive_path) as archive:
        if len(archive.infolist()) > 100000:
            raise ValueError('App archive has too many entries')
        for member in archive.infolist():
            path = PurePosixPath(member.filename)
            normalized = unicodedata.normalize('NFD', str(path)).casefold()
            if (path.is_absolute() or '..' in path.parts or '\\' in member.filename
                    or not path.parts or normalized in seen):
                raise ValueError('Unsafe or duplicate path in app archive')
            seen.add(normalized)
            expanded += member.file_size
            if expanded > 20 * 1024 ** 3:
                raise ValueError('Expanded app archive exceeds the 20 GiB safety limit')
            if path.parts[0] == '__MACOSX':
                # ditto --sequesterRsrc stores AppleDouble resource metadata.
                # Never allow a second actual app hidden under this prefix.
                if not member.is_dir() and not path.name.startswith('._'):
                    raise ValueError('Unexpected payload under __MACOSX')
                continue
            if path.parts[0] != 'OpenEmu.app':
                raise ValueError('Update ZIP must contain exactly one top-level OpenEmu.app')
            mode = member.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK) or mode & 0o6000:
                raise ValueError('Special file or unsafe permissions in app archive')
            target = destination.joinpath(*path.parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif kind == stat.S_IFLNK:
                link = archive.read(member).decode('utf-8')
                if not link or os.path.isabs(link):
                    raise ValueError('Absolute or empty app symlink')
                links.append((target, link))
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as stream, archive.open(member) as source:
                    shutil.copyfileobj(source, stream)
                target.chmod(stat.S_IMODE(mode) or 0o644)
    app = destination / 'OpenEmu.app'
    for target, link in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link)
    for target, _ in links:
        resolved = target.resolve(strict=True)
        if app != resolved and app not in resolved.parents:
            raise ValueError('App symlink escapes its bundle')
    if app.is_symlink() or not (app / 'Contents/Info.plist').is_file():
        raise ValueError('Archive has no complete OpenEmu.app')
    return app


def validate_app_files(app):
    for root, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            candidate = Path(root) / name
            if candidate.is_symlink():
                resolved = candidate.resolve(strict=True)
                if resolved != app and app not in resolved.parents:
                    raise ValueError('Archived app symlink escapes its bundle')
            else:
                mode = candidate.stat().st_mode
                if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)) or mode & 0o6000:
                    raise ValueError('Special file or unsafe permissions inside archived app')


@contextmanager
def extracted_update_app(archive):
    archive = Path(archive).resolve(strict=True)
    temporary = Path(tempfile.mkdtemp(prefix='reborn-update-inspect-'))
    cleanup_allowed = True
    try:
        if archive.suffix.lower() == '.zip':
            app = extract_app_zip(archive, temporary)
            validate_app_files(app)
            yield app
        elif archive.suffix.lower() == '.dmg':
            mountpoint = temporary / 'readonly-dmg'
            mountpoint.mkdir()
            mounted = False
            try:
                attached = subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                    '-mountpoint', str(mountpoint), '-plist', str(archive)], check=True, capture_output=True)
                mounted = True
                plistlib.loads(attached.stdout)  # Reject malformed attach output too.
                app = mountpoint / 'OpenEmu.app'
                if app.is_symlink() or not (app / 'Contents/Info.plist').is_file():
                    raise ValueError('DMG has no top-level OpenEmu.app')
                validate_app_files(app)
                for root, directories, _ in os.walk(mountpoint, followlinks=False):
                    for name in directories:
                        candidate = Path(root) / name
                        if name.endswith('.app') and candidate != app and app not in candidate.parents:
                            raise ValueError('DMG contains another app outside OpenEmu.app')
                yield app
            finally:
                if mounted or os.path.ismount(mountpoint):
                    # Only detach our exact private read-only mount, never a
                    # discovered disk/volume belonging to the user.
                    try:
                        subprocess.run(['hdiutil', 'detach', str(mountpoint)], check=True)
                    except subprocess.CalledProcessError as error:
                        cleanup_allowed = False
                        raise ValueError(f'Could not detach the private read-only update mount; retained {mountpoint}') from error
        else:
            raise ValueError('App update must be an app-only ZIP or DMG')
    finally:
        # Never recurse into a volume if detachment failed. This directory is
        # created by this invocation only, not an input/build/user directory.
        if cleanup_allowed:
            shutil.rmtree(temporary)
