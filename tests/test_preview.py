import json
from pathlib import Path
from unittest.mock import patch

from voice_studio_speaker_bridge.channel import instance_name
from voice_studio_speaker_bridge.settings import Settings, default_config_dir


def test_preview_never_imports_legacy_or_production_override(tmp_path, monkeypatch):
    legacy = tmp_path / 'local' / 'YapLoq'
    legacy.mkdir(parents=True)
    (legacy / 'settings.json').write_text('{"api_key":"production-secret"}')
    monkeypatch.setenv('LOCALAPPDATA', str(tmp_path / 'local'))
    monkeypatch.setenv('YAPLOQ_DATA_DIR', str(legacy))
    monkeypatch.setenv('YAPLOQ_PREVIEW', '1')
    monkeypatch.setenv('YAPLOQ_PREVIEW_ROOT', str(tmp_path / 'preview'))
    target = default_config_dir()
    assert target == tmp_path / 'preview' / 'data-preview'
    assert not target.exists()
    settings = Settings()
    settings.save()
    assert settings.api_key != 'production-secret'
    assert json.loads((legacy / 'settings.json').read_text()) == {'api_key': 'production-secret'}


def test_preview_restricts_imported_ports_and_side_effects_on_reload(tmp_path, monkeypatch):
    monkeypatch.setenv('YAPLOQ_PREVIEW', '1')
    path = tmp_path / 'settings.json'
    path.write_text(json.dumps(dict(http_port=7582, ws_port=7581, udp_port=6670,
        http_address='0.0.0.0', enable_udp=True, streamerbot_actions_enabled=True,
        obs_ducking_enabled=True, persist_queue=True, check_updates_on_startup=True)))
    settings = Settings(path)
    for _ in range(2):
        settings.load()
        assert (settings.http_port, settings.ws_port, settings.udp_port) == (17582, 17581, 16670)
        assert settings.http_address == settings.ws_address == settings.udp_address == '127.0.0.1'
        assert not any((settings.enable_udp, settings.streamerbot_actions_enabled,
            settings.obs_ducking_enabled, settings.persist_queue, settings.check_updates_on_startup))


def test_windows_signals_are_separate(monkeypatch):
    for part in ('Desktop', 'Backend', 'Restore', 'BackendStop'):
        monkeypatch.delenv('YAPLOQ_PREVIEW', raising=False)
        production = instance_name(part)
        monkeypatch.setenv('YAPLOQ_PREVIEW', '1')
        assert instance_name(part) != production
        assert instance_name(part) == 'Local\\YapLoq.Preview.' + part


def test_readiness_rejects_unrelated_backend():
    import wpf_launcher
    with patch.object(wpf_launcher.urllib.request, 'urlopen') as request:
        response = request.return_value.__enter__.return_value
        response.status = 200
        response.read.return_value = b'{"channel":"yaploq","launchId":"other","ready":true}'
        assert not wpf_launcher._backend_ready(timeout_sec=1, port=17582, token='expected')


def test_readiness_waits_for_both_preview_servers():
    import wpf_launcher
    with patch.object(wpf_launcher.urllib.request, 'urlopen') as request:
        response = request.return_value.__enter__.return_value
        response.status = 200
        response.read.side_effect = [
            b'{"channel":"yaploq-preview","launchId":"expected","ready":false}',
            b'{"channel":"yaploq-preview","launchId":"expected","ready":true}',
        ]
        assert wpf_launcher._backend_ready(timeout_sec=1, port=17582, token='expected')
        assert request.call_count == 2


def test_production_workflows_and_spec_unchanged():
    # Preview must have no tag/release permissions, separate output and executable.
    root = Path(__file__).resolve().parents[1]
    workflow = (root / '.github/workflows/yaploq-preview.yml').read_text()
    assert 'contents: read' in workflow
    assert 'contents: write' not in workflow
    assert 'dist-preview' in workflow
    assert 'refs/heads/redesign/yaploq' in workflow
    assert "name='YapLoq-preview'" in (root / 'YapLoq-preview.spec').read_text()
