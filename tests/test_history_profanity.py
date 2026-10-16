import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from voice_studio_speaker_bridge.engine import SpeechEngine
from voice_studio_speaker_bridge.events import EventBus
from voice_studio_speaker_bridge.settings import Settings
from voice_studio_speaker_bridge.profanity import default_rules, filter_text, filter_ssml, normalize_rules


class RecordingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name) / 'settings.json')
        self.engine = SpeechEngine(self.settings, EventBus())

    def tearDown(self):
        self.engine.shutdown()
        self.temp.cleanup()

    def recording(self, name='recording.wav', age=0):
        import os
        path = Path(self.temp.name) / 'audio_cache' / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b'RIFF existing recording')
        os.utime(path, (time.time()-age, time.time()-age))
        return path

    def test_replay_reuses_file_without_provider_or_new_history(self):
        path = self.recording()
        self.engine.history = [dict(id='old', text='Original message', alias='EventVoice', audioPath=str(path))]
        self.settings.max_characters = 1
        self.settings.blocked_words = ['Original']
        self.engine.audio = Mock()
        self.engine.audio.decode_wav.return_value = (b'pcm', 1000)
        self.engine.audio.play.return_value = True
        self.engine._generate = Mock(side_effect=AssertionError('Replay resynthesized'))
        job = self.engine.replay_history('old')
        self.assertEqual(job.audio_path, str(path))
        self.engine.start()
        deadline = time.monotonic()+3
        while self.engine.pending.unfinished_tasks and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(job.status, 'Finished')
        self.engine._generate.assert_not_called()
        self.assertEqual(list(path.parent.iterdir()), [path])
        self.assertEqual(len(self.engine.history), 1)

    def test_history_only_includes_existing_saved_or_cached_files(self):
        path = self.recording()
        self.engine.history = [dict(id='gone',audioPath='missing'),dict(id='saved',audioPath='missing',savedPath=str(path))]
        self.assertEqual([x['id'] for x in self.engine.history_items()], ['saved'])

    def test_retention_protects_pending_recording_and_uses_limit(self):
        self.settings.history_limit=2
        oldest=self.recording('old.wav',30)
        self.engine.history=[dict(id='old',text='Replay',alias='EventVoice',audioPath=str(oldest))]
        self.engine.replay_history('old')
        middle=self.recording('middle.wav',20)
        newest=self.recording('new.wav',10)
        self.engine._trim_audio_cache()
        self.assertTrue(oldest.exists())
        self.assertFalse(middle.exists())
        self.assertTrue(newest.exists())

    def test_retention_keeps_configured_thirty_newest(self):
        self.settings.history_limit=30
        for index in range(35):self.recording(f'{index}.wav',100-index)
        self.engine._trim_audio_cache()
        files=list((Path(self.temp.name)/'audio_cache').iterdir())
        self.assertEqual(len(files),30)
        self.assertFalse((files[0].parent/'0.wav').exists())
        self.assertTrue((files[0].parent/'34.wav').exists())

    def test_saved_export_reused_if_cache_missing(self):
        path=self.recording()
        self.settings.voice_save_folder=str(Path(self.temp.name)/'exports')
        self.engine.history=[dict(id='old',text='Saved',alias='Voice',audioPath=str(path),timestamp='2026-10-15T12:00:00Z')]
        saved=self.engine.save_history_audio('old')
        path.unlink()
        self.assertEqual(self.engine.replay_history('old').audio_path,saved)
        self.assertEqual(self.engine.save_history_audio('old'),saved)
        self.assertEqual(len(list(Path(saved).parent.iterdir())),1)

    def test_recovered_queue_reuses_recording(self):
        path=self.recording();self.settings.persist_queue=True
        self.engine.history=[dict(id='old',text='Replay',alias='EventVoice',audioPath=str(path))]
        self.engine.replay_history('old')
        restored=SpeechEngine(self.settings,EventBus())
        try:
            job=list(restored.pending.queue)[0]
            self.assertTrue(job.replay_recording)
            self.assertEqual(job.audio_path,str(path))
        finally:
            restored.shutdown()


class ProfanityTests(unittest.TestCase):
    def test_ssml_split_words_and_spoken_aliases(self):
        from xml.etree import ElementTree as ET
        root=ET.fromstring('<speak>gr<emphasis>ass</emphasis> a<emphasis>ss</emphasis> and <sub alias="shit">term</sub></speak>')
        filter_ssml(root,default_rules())
        self.assertEqual(''.join(root.itertext()),'grass bleep and term')
        self.assertEqual(root.find('sub').get('alias'),'bleep')
        rules=normalize_rules([dict(word='ass',action='block')])
        with self.assertRaises(ValueError):filter_ssml(ET.fromstring('<speak>a<emphasis>ss</emphasis></speak>'),rules)

    def test_whole_words_and_plurals(self):
        self.assertEqual(filter_text('grass class assessment ASS asses asshole',default_rules()),'grass class assessment bleep bleep bleep')

    def test_custom_actions_and_non_cascading_replacements(self):
        rules=normalize_rules([dict(word='alpha',replacement='beta'),dict(word='beta',replacement='clean'),dict(word='omit',action='remove')])
        self.assertEqual(filter_text('alpha beta omit',rules),'beta clean')
        rules[0]['action']='block'
        with self.assertRaisesRegex(ValueError,'profanity filter'):
            filter_text('ALPHA',rules)
        rules[0]['enabled']=False
        self.assertEqual(filter_text('alpha',rules),'alpha')

    def test_alternatives_and_forms_toggle(self):
        rules=normalize_rules([dict(word='test',variants=['tests'],match_variants=False,replacement='first, second')])
        with patch('voice_studio_speaker_bridge.profanity.random.choice',side_effect=['first','second']):
            self.assertEqual(filter_text('test test tests',rules),'first second tests')

    def test_setting_persistence_and_engine_integration(self):
        with tempfile.TemporaryDirectory() as folder:
            settings=Settings(Path(folder)/'settings.json');settings.profanity_enabled=True
            settings.profanity_rules=normalize_rules([dict(word='test',replacement='clean',variants=['tests'])])
            settings.save();loaded=Settings(settings.path)
            self.assertTrue(loaded.profanity_hide_words)
            engine=SpeechEngine(loaded,EventBus())
            try:
                self.assertEqual(engine._prepare_text('test tests contest',''),'clean clean contest')
                self.assertEqual(engine._normalize_viewer('viewer'),'viewer')
            finally:engine.shutdown()

if __name__=='__main__':unittest.main()
