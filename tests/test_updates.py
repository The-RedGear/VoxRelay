import hashlib
import io
import json
from pathlib import Path
import time
from unittest.mock import Mock, patch
import zipfile

import pytest

from voice_studio_speaker_bridge.settings import Settings
from voice_studio_speaker_bridge.updates import (UpdateManager, release_info, safe_relative,
    unpack_verified, version_key, installed_version, REPOSITORY)


def release(version='v0.6.0', preview=False, digest='a'*64):
    return dict(tag_name=version, prerelease=preview, draft=False, body='## Changes\nBetter speech',
        assets=[dict(name='YapLoq'+('-preview' if preview else '')+'-Windows-x64-update.zip',
            browser_download_url=f'https://github.com/{REPOSITORY}/releases/download/{version}/update.zip',
            digest='sha256:'+digest, size=123)], published_at='2026-10-17T12:00:00Z')


def github_response(data):
    response=Mock()
    response.__enter__=Mock(return_value=response)
    response.__exit__=Mock(return_value=False)
    response.read.return_value=json.dumps(data).encode()
    return response


def test_release_channels_and_versions():
    with patch('voice_studio_speaker_bridge.updates.urlopen', return_value=github_response([
        release('v0.6.0'), release('v0.7.0-preview.2',True), dict(release('v9.0.0'),draft=True)])) as request:
        stable=release_info(False,'0.5.0')
        preview=release_info(True,'0.5.0')
    assert stable['version']=='v0.6.0' and stable['compatible']
    assert preview['version']=='v0.7.0-preview.2' and preview['compatible']
    assert request.call_args.args[0].full_url.startswith('https://api.github.com/repos/The-RedGear/YapLoq/releases')
    assert version_key('0.7.0-preview.2')<version_key('0.7.0-rc.1')<version_key('0.7.0')


@pytest.mark.parametrize('change', [dict(digest=None),dict(browser_download_url='https://evil.example/update.zip'),dict(name='VoxRelay-Windows.zip'),dict(size=0)])
def test_unverified_or_unrelated_asset_cannot_install(change):
    data=release();data['assets'][0].update(change)
    with patch('voice_studio_speaker_bridge.updates.urlopen',return_value=github_response([data])):
        info=release_info(False,'0.5.0')
    assert info['available'] and not info['compatible']


def test_no_downgrade_or_release_means_no_upgrade():
    with patch('voice_studio_speaker_bridge.updates.urlopen',return_value=github_response([release('v0.4.0')])):
        assert not release_info(False,'0.5.0')['available']
    with patch('voice_studio_speaker_bridge.updates.urlopen',return_value=github_response([])):
        assert 'published' in release_info(True)['message']


@pytest.mark.parametrize('name',['../x','a/../../x','C:/x','/x','a\\x','data/settings.json','DATA-PREVIEW/settings.json','x/CON.txt','x/name.','x//y'])
def test_unsafe_paths_rejected(name):
    with pytest.raises(ValueError):safe_relative(name)


def make_package(path, extra=None, version='0.6.0',channel='stable'):
    exe='YapLoq-preview.exe' if channel=='preview' else 'YapLoq.exe'
    with zipfile.ZipFile(path,'w') as archive:
        archive.writestr('update-manifest.json',json.dumps(dict(schema=1,version=version,channel=channel,platform='windows-x64',executable=exe)))
        archive.writestr(exe,b'fixture executable')
        archive.writestr('_internal/YapLoq.ps1','fixture shell')
        archive.writestr('_internal/YapLoq.xaml','fixture UI')
        if extra:archive.writestr(*extra)
    return path


def test_verified_extraction_and_channel_mismatch(tmp_path):
    package=make_package(tmp_path/'update.zip')
    files=unpack_verified(package,tmp_path/'stage','v0.6.0','stable')
    assert len(files)==4
    assert all(len(item['sha256'])==64 for item in files)
    with pytest.raises(ValueError):unpack_verified(package,tmp_path/'other','v0.6.0','preview')


def test_zip_traversal_is_rejected_before_any_extraction(tmp_path):
    package=make_package(tmp_path/'update.zip',('../escaped.txt','bad'))
    with pytest.raises(ValueError):unpack_verified(package,tmp_path/'stage','0.6.0','stable')
    assert not (tmp_path/'stage').exists() and not (tmp_path/'escaped.txt').exists()


def test_case_colliding_zip_members_rejected(tmp_path):
    package=make_package(tmp_path/'update.zip',('yaploq.EXE','bad'))
    with pytest.raises(ValueError):unpack_verified(package,tmp_path/'stage','0.6.0','stable')


def test_download_hash_failure_never_becomes_ready(tmp_path):
    manager=UpdateManager(Settings(tmp_path/'settings.json'))
    manager.release=dict(available=True,compatible=True,version='v0.6.0',channel='stable',asset=release()['assets'][0])
    response=github_response({});response.read.side_effect=[b'bad',b''];response.geturl.return_value='https://release-assets.githubusercontent.com/test'
    with patch('voice_studio_speaker_bridge.updates.urlopen',return_value=response):
        manager.download();manager.worker.join(3)
    assert manager.status()['state']=='error' and not (manager.root/'ready.json').exists()


def test_download_persists_verified_package_for_restart(tmp_path,monkeypatch):
    monkeypatch.delenv('YAPLOQ_PREVIEW',raising=False)
    package=make_package(tmp_path/'fixture.zip');payload=package.read_bytes()
    manager=UpdateManager(Settings(tmp_path/'data'/'settings.json'))
    asset=release()['assets'][0];asset.update(size=len(payload),digest='sha256:'+hashlib.sha256(payload).hexdigest())
    manager.release=dict(available=True,compatible=True,version='v0.6.0',channel='stable',asset=asset)
    response=github_response({});response.read.side_effect=[payload,b''];response.geturl.return_value='https://release-assets.githubusercontent.com/test'
    with patch('voice_studio_speaker_bridge.updates.urlopen',return_value=response):
        manager.download();manager.worker.join(3)
    assert manager.status()['state']=='ready'
    restored=UpdateManager(manager.settings)
    assert restored.status()['state']=='ready' and restored.ready['files']


def test_active_speech_blocks_install_and_keeps_admission_enabled(tmp_path):
    manager=UpdateManager(Settings(tmp_path/'settings.json'))
    manager.ready={'id':'a'*32};manager.info['state']='ready'
    from threading import RLock
    engine=Mock();engine._admission_lock=RLock();engine._enabled=True
    engine.state.return_value={'current':{'status':'Playing'},'queueLength':0}
    with pytest.raises(ValueError,match='Speech is still active'):manager.prepare_apply(engine,123)
    assert engine._enabled


def test_installed_prerelease_version_comes_from_package(tmp_path,monkeypatch):
    monkeypatch.setenv('YAPLOQ_UPDATE_EXE',str(tmp_path/'YapLoq-preview.exe'))
    monkeypatch.setenv('YAPLOQ_PREVIEW','1')
    (tmp_path/'update-manifest.json').write_text(json.dumps(dict(version='0.6.0-preview.3',channel='preview')))
    assert installed_version()=='0.6.0-preview.3'
