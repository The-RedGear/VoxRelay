"""GitHub Releases update discovery and verified, staged portable updates.

No release creation or automatic restart. Installation is delegated to the
bundled helper only after explicit desktop confirmation and idle admission.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
from threading import Event, RLock, Thread
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import uuid
import zipfile

from . import __version__
from .channel import is_preview

REPOSITORY = 'The-RedGear/YapLoq'
API = f'https://api.github.com/repos/{REPOSITORY}/releases?per_page=100'
MAX_DOWNLOAD = 1024 * 1024 * 1024
MAX_EXPANDED = 3 * MAX_DOWNLOAD


def version_key(value: str) -> tuple:
    match = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)(?:-(preview|beta|rc)(?:[.-](\d+))?)?', value)
    if not match:
        raise ValueError('Unsupported release version')
    major, minor, patch, kind, number = match.groups()
    return (int(major), int(minor), int(patch), {None: 4, 'rc': 3, 'beta': 2, 'preview': 1}[kind], int(number or 0))


def installed_version() -> str:
    executable = os.environ.get('YAPLOQ_UPDATE_EXE')
    if executable:
        try:
            metadata = json.loads((Path(executable).parent / 'update-manifest.json').read_text(encoding='utf-8'))
            version = metadata['version']
            version_key(version)
            if metadata.get('channel') == ('preview' if is_preview() else 'stable'):
                return version
        except (OSError, ValueError, KeyError):
            pass
    return __version__ + ('-preview.0' if is_preview() else '')


def release_info(preview: bool, current: str | None = None) -> dict:
    current = current or installed_version()
    request = Request(API, headers={'Accept': 'application/vnd.github+json',
        'User-Agent': f'YapLoq/{__version__}', 'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=15) as response:
        releases = json.loads(response.read(2_000_000))
    if not isinstance(releases, list):
        raise ValueError('GitHub returned an unexpected release list')
    candidates = []
    for release in releases:
        if release.get('draft') or bool(release.get('prerelease')) != preview:
            continue
        try:
            key = version_key(str(release.get('tag_name', '')))
        except ValueError:
            continue
        if bool(key[3] != 4) != preview:
            continue
        candidates.append((key, release))
    channel = 'preview' if preview else 'stable'
    base = dict(checked=True, available=False, currentVersion=current, channel=channel)
    if not candidates:
        return dict(base, message=f'No {channel} release has been published yet.')
    key, release = max(candidates, key=lambda entry: entry[0])
    # The initial preview identifies as 0.5.0; do not offer older preview builds
    # or same-version ambiguous packages as upgrades.
    available = key > version_key(current)
    asset_name = 'YapLoq-preview-Windows-x64-update.zip' if preview else 'YapLoq-Windows-x64-update.zip'
    asset = next((a for a in release.get('assets', []) if a.get('name') == asset_name), None)
    compatible = False
    if asset:
        parsed = urlparse(str(asset.get('browser_download_url', '')))
        compatible = (parsed.scheme == 'https' and parsed.hostname == 'github.com'
            and parsed.path.startswith(f'/{REPOSITORY}/releases/download/')
            and re.fullmatch(r'sha256:[0-9a-fA-F]{64}', str(asset.get('digest', ''))) is not None
            and 0 < int(asset.get('size', 0)) <= MAX_DOWNLOAD)
    return dict(base, available=available, version=str(release['tag_name']),
        publishedAt=release.get('published_at', ''), notes=str(release.get('body') or 'No release notes provided.')[:100000],
        releaseUrl=f'https://github.com/{REPOSITORY}/releases',
        size=int(asset.get('size', 0)) if asset else 0, compatible=compatible,
        asset=asset if compatible else None,
        message=(f"YapLoq {release['tag_name']} is available." if available else 'You’re up to date.')
        + (' This release does not include a verified compatible update package.' if available and not compatible else ''))


def safe_relative(name: str) -> Path:
    path = PurePosixPath(name)
    if (not name or '\\' in name or ':' in name or path.is_absolute()
            or any(part in ('', '.', '..') or part.endswith((' ', '.')) for part in name.split('/'))):
        raise ValueError('Unsafe path in update package')
    if path.parts[0].casefold() in {'data', 'data-preview', '.git', 'src', 'updates', 'backups'}:
        raise ValueError('Update package may not replace user data')
    for part in path.parts:
        if re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part):
            raise ValueError('Reserved Windows filename in update package')
    return Path(*path.parts)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def unpack_verified(package: Path, stage: Path, version: str, channel: str) -> list[dict]:
    """Validate every member before extracting; never trust ZipFile.extractall."""
    with zipfile.ZipFile(package) as archive:
        members = [item for item in archive.infolist() if not item.is_dir()]
        if len(members) > 20000 or sum(item.file_size for item in members) > MAX_EXPANDED:
            raise ValueError('Update package is too large')
        seen = set()
        for item in members:
            safe_relative(item.filename)
            key = item.filename.casefold()
            if key in seen or stat.S_ISLNK(item.external_attr >> 16) or item.flag_bits & 1:
                raise ValueError('Duplicate, linked, or encrypted update entry')
            seen.add(key)
        manifest = json.loads(archive.read('update-manifest.json'))
        executable = 'YapLoq-preview.exe' if channel == 'preview' else 'YapLoq.exe'
        if (manifest.get('schema') != 1 or manifest.get('version') != version.lstrip('v')
                or manifest.get('channel') != channel or manifest.get('platform') != 'windows-x64'
                or manifest.get('executable') != executable or executable.casefold() not in seen
                or '_internal/yaploq.ps1' not in seen or '_internal/yaploq.xaml' not in seen):
            raise ValueError('This update is not compatible with this installation')
        files = []
        for item in members:
            relative = safe_relative(item.filename)
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, destination.open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            files.append(dict(path=relative.as_posix(), sha256=sha256(destination)))
    return files


class UpdateManager:
    def __init__(self, settings):
        self.settings = settings
        self.root = settings.path.parent / 'updates'
        self.lock = RLock()
        self.cancel = Event()
        self.info = dict(state='idle', currentVersion=installed_version(), channel='preview' if is_preview() else 'stable', message='Check GitHub Releases for updates.')
        self.release = None
        self.ready = None
        self.worker = None
        saved = self.root / 'ready.json'
        if saved.is_file():
            try:
                ready = json.loads(saved.read_text(encoding='utf-8'))
                # Only managed direct child directories can ever become stages.
                if not re.fullmatch(r'[a-f0-9]{32}', ready['id']):
                    raise ValueError('Invalid saved update')
                if ready['channel'] == self.info['channel'] and version_key(ready['version']) > version_key(installed_version()):
                    self.ready = ready
                    self.info.update(state='ready', version=ready['version'], notes=ready.get('notes', ''), size=ready.get('size', 0), packagePath=str(self.root / ready['id'] / 'package.zip'), message='Update downloaded. Restart when you’re ready.', available=True)
            except (ValueError, KeyError, OSError):
                pass
        outcome = self.root / 'outcome.json'
        if outcome.is_file():
            try:
                self.info['lastResult'] = json.loads(outcome.read_text(encoding='utf-8-sig'))
            except (ValueError, OSError):
                pass

    def status(self):
        with self.lock:
            return dict(self.info)

    def _set(self, **values):
        with self.lock:
            self.info.update(values)

    def check(self):
        with self.lock:
            if self.info['state'] in {'checking', 'downloading', 'ready', 'applying'}:
                return self.status()
            self._set(state='checking', message='Checking GitHub Releases…')
            self.worker = Thread(target=self._check, name='Update check', daemon=True)
            self.worker.start()
        return self.status()

    def _check(self):
        try:
            release = release_info(is_preview())
            with self.lock:
                self.release = release
                self.info.update(release, state='available' if release.get('available') else 'current')
        except Exception:
            self._set(state='error', message='Couldn’t reach GitHub Releases. Check your connection and try again.')

    def download(self):
        with self.lock:
            if self.info['state'] in {'downloading', 'ready', 'applying'}:
                return self.status()
            if not self.release or not self.release.get('available') or not self.release.get('compatible'):
                raise ValueError('Check for a compatible update first')
            self.cancel.clear()
            self._set(state='downloading', progress=0, message='Downloading. You can keep using YapLoq.')
            self.worker = Thread(target=self._download, args=(dict(self.release),), name='Update download', daemon=True)
            self.worker.start()
        return self.status()

    def _download(self, release):
        try:
            update_id = uuid.uuid4().hex
            folder = self.root / update_id
            folder.mkdir(parents=True)
            package = folder / 'package.zip'
            asset = release['asset']
            request = Request(asset['browser_download_url'], headers={'User-Agent': f'YapLoq/{__version__}'})
            total = 0
            with urlopen(request, timeout=30) as source, package.open('xb') as target:
                if urlparse(source.geturl()).scheme != 'https':
                    raise ValueError('Insecure update download')
                while chunk := source.read(1024 * 1024):
                    if self.cancel.is_set():
                        self._set(state='available', message='Download cancelled. You can try again later.')
                        return
                    total += len(chunk)
                    if total > asset['size'] or total > MAX_DOWNLOAD:
                        raise ValueError('Unexpected download size')
                    target.write(chunk)
                    self._set(progress=min(99, int(total * 100 / asset['size'])))
            if total != asset['size'] or sha256(package) != asset['digest'].split(':')[1].lower():
                raise ValueError('Download verification failed. Please download again.')
            files = unpack_verified(package, folder / 'stage', release['version'], release['channel'])
            ready = dict(id=update_id, version=release['version'], channel=release['channel'],
                files=files, packageHash=sha256(package), notes=release.get('notes', ''), size=total)
            temporary = self.root / 'ready.tmp'
            temporary.write_text(json.dumps(ready), encoding='utf-8')
            temporary.replace(self.root / 'ready.json')
            self.ready = ready
            self._set(state='ready', progress=100, packagePath=str(package), message='Download verified. Restart when you’re ready.')
        except Exception as exc:
            self._set(state='error', message=f'Update download failed: {exc}')

    def cancel_download(self):
        self.cancel.set()
        return self.status()

    def prepare_apply(self, engine, desktop_pid: int):
        with self.lock, engine._admission_lock:
            if not self.ready or self.info['state'] != 'ready':
                raise ValueError('Download and verify an update first')
            state = engine.state()
            if state.get('current') or state.get('queueLength'):
                raise ValueError('Speech is still active. Wait for the queue to finish.')
            executable = Path(os.environ.get('YAPLOQ_UPDATE_EXE', ''))
            expected = 'YapLoq-preview.exe' if is_preview() else 'YapLoq.exe'
            if not executable.is_absolute() or executable.name != expected or not executable.is_file():
                raise ValueError('In-app installation is available in the packaged Windows app only.')
            install = executable.parent.resolve()
            folder = self.root / self.ready['id']
            if sha256(folder / 'package.zip') != self.ready['packageHash']:
                raise ValueError('The downloaded package changed. Download it again.')
            for item in self.ready['files']:
                relative = safe_relative(item['path'])
                target = install / relative
                data_root = self.settings.path.parent.resolve()
                if data_root != install and target.resolve().is_relative_to(data_root):
                    raise ValueError('Update package may not replace the configured data folder')
                if not target.resolve().is_relative_to(install) or any(p.is_symlink() for p in [target, *target.parents] if p.is_relative_to(install)):
                    raise ValueError('Installation contains an unsafe linked path')
                if sha256(folder / 'stage' / relative) != item['sha256']:
                    raise ValueError('The staged update changed. Download it again.')
            # Probe write access before asking the desktop to close.
            probe = install / f'.update-probe-{uuid.uuid4().hex}'
            try:
                probe.touch(exist_ok=False)
                probe.unlink()
            except OSError as exc:
                raise ValueError('YapLoq can’t write to its installation folder. Move it to a writable folder and try again.') from exc
            from .maintenance import Maintenance
            Maintenance(self.settings).backup()
            helper_source = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parents[2])) / 'assets' / 'ApplyUpdate.ps1'
            helper = folder / 'ApplyUpdate.ps1'
            shutil.copy2(helper_source, helper)
            plan = dict(install=str(install), stage=str((folder / 'stage').resolve()),
                backup=str((folder / 'rollback').resolve()), data=str(self.settings.path.parent.resolve()),
                executable=expected, version=self.ready['version'].lstrip('v'), files=self.ready['files'],
                processes=[os.getpid(), int(os.environ.get('YAPLOQ_PARENT_PID', '0')), desktop_pid],
                port=self.settings.http_port, channel='yaploq-preview' if is_preview() else 'yaploq')
            plan_path = folder / 'plan.json'
            plan_path.write_text(json.dumps(plan), encoding='utf-8')
            previously_enabled = engine._enabled
            engine._enabled = False
            try:
                subprocess.Popen(['powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                    '-File', str(helper), '-Plan', str(plan_path)], creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), close_fds=True)
            except Exception:
                engine._enabled = previously_enabled
                raise
            self._set(state='applying', message='Closing YapLoq to install the update…')
            return dict(close=True)
