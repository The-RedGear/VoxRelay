from voice_studio_speaker_bridge.models import VoiceAlias
from voice_studio_speaker_bridge.settings import Settings


def test_legacy_alias_defaults_to_music_note():
    assert VoiceAlias.from_dict('Legacy', {'provider': 'windows'}).icon_id == 'mdi:music-note'


def test_icon_id_normalizes_and_rejects_markup():
    for value in ('cat', 'mdi-cat', ' MDI:CAT '):
        assert VoiceAlias('Voice', icon_id=value).icon_id == 'mdi:cat'
    assert VoiceAlias('Voice', icon_id='<svg onload="alert(1)"/>').icon_id == 'mdi:music-note'


def test_icon_survives_settings_reload(tmp_path):
    path = tmp_path / 'settings.json'
    settings = Settings(path)
    settings.aliases['Cat'] = VoiceAlias('Cat', provider='windows', icon_id='mdi:cat', favorite=True, color='#87C9AF')
    settings.save()
    loaded = Settings(path).aliases['Cat']
    assert loaded.icon_id == 'mdi:cat'
    assert loaded.favorite
    assert loaded.color == '#87C9AF'


def test_invalid_voice_color_uses_app_default():
    assert VoiceAlias('Voice', color='bad color').color == '#B6A3FF'


def test_all_collection_identifiers_survive_roundtrip():
    for identifier in ('material-symbols:hdr-auto-outline-rounded', 'picon:alien', 'logos:python', 'tabler:cat'):
        alias = VoiceAlias('Voice', icon_id=identifier)
        assert VoiceAlias.from_dict('Voice', alias.to_dict()).icon_id == identifier
