import base64
import gzip
import json
from pathlib import Path
from unittest.mock import patch
import uuid

from voice_studio_speaker_bridge.maintenance import Maintenance
from voice_studio_speaker_bridge.settings import Settings, default_config_dir
from voice_studio_speaker_bridge.streamerbot_export import export_actions


def test_existing_settings_copy_to_new_identity_without_changing_original(tmp_path, monkeypatch):
    monkeypatch.delenv('YAPLOQ_PREVIEW', raising=False)
    monkeypatch.delenv('YAPLOQ_DATA_DIR', raising=False)
    monkeypatch.delenv('VOXRELAY_DATA_DIR', raising=False)
    monkeypatch.setenv('LOCALAPPDATA', str(tmp_path))
    old = tmp_path / 'VoxRelay'
    old.mkdir()
    original = '{"aliases":{"Saved":{"provider":"windows","favorite":true}}}'
    (old / 'settings.json').write_text(original)
    assert default_config_dir() == tmp_path / 'YapLoq'
    settings = Settings()
    assert settings.aliases['Saved'].favorite
    settings.save()
    assert (old / 'settings.json').read_text() == original
    assert Settings().aliases['Saved'].favorite


def test_legacy_presets_import_but_new_exports_use_current_brand(tmp_path):
    settings = Settings(tmp_path / 'settings.json')
    settings.save()
    maintenance = Maintenance(settings)
    result = maintenance.import_presets({'format': 'VoxRelay-presets', 'version': 1,
        'settings': {'aliases': {'Saved': {'provider': 'windows', 'favorite': True}}}})
    assert result['aliasesImported'] == 1
    assert settings.aliases['Saved'].favorite
    exported = Path(maintenance.export_presets())
    assert exported.name.startswith('YapLoq-')
    assert json.loads(exported.read_text())['format'] == 'YapLoq-presets'


def test_old_backup_remains_available_under_new_name(tmp_path):
    settings = Settings(tmp_path / 'settings.json')
    settings.save()
    folder = tmp_path / 'backups'
    folder.mkdir()
    legacy = folder / 'VoxRelay-20260101.json'
    legacy.write_bytes(settings.path.read_bytes())
    maintenance = Maintenance(settings)
    assert maintenance.backups() == ['YapLoq-20260101.json']
    assert maintenance.backups() == ['YapLoq-20260101.json']
    assert legacy.exists()
    maintenance.restore('YapLoq-20260101.json')


def test_action_display_names_change_without_replacing_installed_ids():
    encoded = base64.b64decode(export_actions(6670, 'random'))
    envelope = json.loads(gzip.decompress(encoded[4:]))
    action = envelope['data']['actions'][0]
    assert action['name'] == 'YapLoq - Speak'
    assert action['id'] == str(uuid.uuid5(uuid.NAMESPACE_OID, 'VoxRelay/action/Speak'))
    assert 'VoxRelay' not in json.dumps(envelope)
    assert action['actions'][0]['payload'].startswith('VSPEAK\r\n')


def test_updater_does_not_advertise_old_product_as_new_release():
    with patch('voice_studio_speaker_bridge.maintenance.urlopen') as request:
        request.return_value.__enter__.return_value.read.return_value = json.dumps(
            {'tag_name': 'v99.0.0', 'assets': [{'name': 'VoxRelay-Windows.zip'}]}).encode()
        result = Maintenance.check_updates()
    assert result['checked'] is False
    assert 'available' not in result


def test_updater_accepts_current_product_assets():
    with patch('voice_studio_speaker_bridge.maintenance.urlopen') as request:
        request.return_value.__enter__.return_value.read.return_value = json.dumps(
            {'tag_name': 'v99.0.0', 'assets': [{'name': 'YapLoq-Windows.zip'}]}).encode()
        result = Maintenance.check_updates()
    assert result['available'] is True
    assert result['message'].startswith('YapLoq ')
