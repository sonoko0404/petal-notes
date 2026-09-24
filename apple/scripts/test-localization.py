#!/usr/bin/env python3
import importlib.util, json, tempfile, unittest, sys
sys.dont_write_bytecode = True
from pathlib import Path
spec = importlib.util.spec_from_file_location('verify', Path(__file__).with_name('verify-localization.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class LocalizationVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.catalog = self.root / 'Resources/Localizable.xcstrings'
        self.catalog.parent.mkdir()
        self.source = self.root / 'View.swift'
        self.source.write_text('Text("ui.greeting")')
        self.entry = {'localizations': {lang: {'stringUnit': {'state': 'translated', 'value': value}} for lang, value in [('en','Hello'),('zh-Hans','你好')]}}
        self.data = {'sourceLanguage':'en','version':'1.0','strings':{'ui.greeting':self.entry}}
    def result(self):
        self.catalog.write_text(json.dumps(self.data))
        return module.verify(self.root)
    def test_valid(self): self.assertEqual(self.result(), [])
    def test_missing_language(self):
        del self.entry['localizations']['zh-Hans']
        self.assertTrue(self.result())
    def test_stale(self):
        self.entry['extractionState'] = 'stale'
        self.assertTrue(self.result())
    def test_untranslated(self):
        self.entry['localizations']['zh-Hans']['stringUnit']['state'] = 'needs_review'
        self.assertTrue(self.result())
    def test_placeholder_mismatch(self):
        self.entry['localizations']['en']['stringUnit']['value'] = '%lld items'
        self.assertTrue(self.result())
    def test_missing_key(self):
        self.source.write_text('Text("ui.absent")')
        self.assertTrue(self.result())
    def test_raw_literal(self):
        self.source.write_text('Button("Untranslated title") {}')
        self.assertTrue(self.result())
    def test_wrong_resource_bundle(self):
        self.source.unlink()
        widget = self.root/'PetalWidgets/View.swift'
        widget.parent.mkdir()
        widget.write_text('Text("ui.greeting", tableName: "Widgets")')
        self.assertTrue(self.result())
    def test_english_copied_into_chinese(self):
        self.entry['localizations']['zh-Hans']['stringUnit']['value'] = 'Hello'
        self.assertTrue(self.result())

unittest.main()
