#!/usr/bin/env python3
"""Mutate real resources/source; expected paths are independent of the verifier manifest."""
import importlib.util, json, shutil, tempfile, unittest, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('verify', Path(__file__).with_name('verify-localization.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

APP = 'PetalChecklist/Resources/Localizable.xcstrings'
WIDGET = 'PetalWidgets/Resources/Widgets.xcstrings'
APP_INFO = 'PetalChecklist/Resources/InfoPlist.xcstrings'
WIDGET_INFO = 'PetalWidgets/Resources/InfoPlist.xcstrings'
CORE = 'Packages/PetalKit/Sources/PetalCore/Resources/Localizable.xcstrings'
NOTIFICATIONS = 'Packages/PetalKit/Sources/PetalNotifications/Resources/Localizable.xcstrings'
EXPECTED_CATALOGS = [APP, WIDGET, APP_INFO, WIDGET_INFO, CORE, NOTIFICATIONS]
WIDGET_VIEW = 'PetalWidgets/ChecklistWidgetView.swift'
NOTIFICATION_SOURCE = 'Packages/PetalKit/Sources/PetalNotifications/SystemNotificationCenter.swift'

class LocalizationVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        original = Path(__file__).resolve().parents[1]
        for path in original.rglob('*'):
            relative = path.relative_to(original)
            if any(x in relative.parts for x in ('.build', 'Tests', 'PetalChecklistTests', 'PetalChecklistUITests', 'scripts')): continue
            if path.is_file() and path.suffix in ('.swift', '.xcstrings', '.pbxproj'):
                destination = self.root/relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)

    def mutate(self, path, old, new):
        file = self.root/path; text = file.read_text()
        self.assertIn(old, text, 'mutation must alter the intended real call site')
        file.write_text(text.replace(old, new, 1))

    def edit_catalog(self, path, operation):
        file = self.root/path; data = json.loads(file.read_text())
        operation(data); file.write_text(json.dumps(data))

    def assertRejected(self, diagnostic=None):
        errors = module.verify(self.root)
        self.assertTrue(errors)
        if diagnostic: self.assertTrue(any(diagnostic in error for error in errors), errors)

    def test_valid_real_workspace(self): self.assertEqual(module.verify(self.root), [])

    def test_each_required_catalog_is_mandatory(self):
        for path in EXPECTED_CATALOGS:
            with self.subTest(path=path):
                file = self.root/path; saved = file.read_bytes(); file.unlink()
                try: self.assertRejected('missing catalog: '+path)
                finally: file.write_bytes(saved)

    def test_both_infoplist_catalogs_cannot_disappear_together(self):
        (self.root/APP_INFO).unlink(); (self.root/WIDGET_INFO).unlink()
        self.assertRejected('missing catalog: '+APP_INFO)

    def test_each_infoplist_key_is_required(self):
        for path in [APP_INFO, WIDGET_INFO]:
            for key in ['CFBundleDisplayName', 'CFBundleName']:
                with self.subTest(path=path, key=key):
                    saved = (self.root/path).read_bytes()
                    self.edit_catalog(path, lambda d: d['strings'].pop(key))
                    try: self.assertRejected('required key: '+key)
                    finally: (self.root/path).write_bytes(saved)

    def test_renaming_each_table_is_rejected(self):
        for path in EXPECTED_CATALOGS:
            with self.subTest(path=path):
                file = self.root/path; renamed = file.with_name('Renamed.xcstrings')
                file.rename(renamed)
                try: self.assertRejected('unexpected catalog: '+str(renamed.relative_to(self.root)))
                finally: renamed.rename(file)

    def test_extra_misplaced_catalog_is_rejected(self):
        target = self.root/'PetalWidgets/Resources/Localizable.xcstrings'
        shutil.copyfile(self.root/APP, target)
        self.assertRejected('unexpected catalog: PetalWidgets/Resources/Localizable.xcstrings')

    def test_duplicate_table_in_nested_resource_directory_is_rejected(self):
        target = self.root/'PetalChecklist/Resources/Duplicate/Localizable.xcstrings'
        target.parent.mkdir(); shutil.copyfile(self.root/APP, target)
        self.assertRejected('unexpected catalog: PetalChecklist/Resources/Duplicate/Localizable.xcstrings')

    def test_catalog_must_be_registered_in_owning_target(self):
        self.mutate('PetalChecklist.xcodeproj/project.pbxproj', '0000000000000000000000E7, 0000000000000000000000D3', '0000000000000000000000D3')
        self.assertRejected('resource ownership')

    def test_widget_cannot_register_app_infoplist(self):
        self.mutate('PetalChecklist.xcodeproj/project.pbxproj', 'files = (0000000000000000000000ED, 0000000000000000000000BE,)', 'files = (0000000000000000000000E7, 0000000000000000000000BE,)')
        self.assertRejected('resource ownership')

    def test_package_resources_must_be_processed(self):
        self.mutate('Packages/PetalKit/Package.swift', '.target(name: "PetalNotifications", dependencies: ["PetalCore"], resources: [.process("Resources")])', '.target(name: "PetalNotifications", dependencies: ["PetalCore"])')
        self.assertRejected('resource ownership')

    def test_missing_language(self):
        self.edit_catalog(APP, lambda d: d['strings']['ui.storage_retry']['localizations'].pop('zh-Hans'))
        self.assertRejected('missing zh-Hans')

    def test_stale(self):
        self.edit_catalog(APP, lambda d: d['strings']['ui.storage_retry'].update(extractionState='stale'))
        self.assertRejected('stale')

    def test_untranslated(self):
        self.edit_catalog(APP, lambda d: d['strings']['ui.storage_retry']['localizations']['zh-Hans']['stringUnit'].update(state='needs_review'))
        self.assertRejected('untranslated')

    def test_placeholder_mismatch(self):
        self.edit_catalog(APP, lambda d: d['strings']['ui.feedback_metadata']['localizations']['zh-Hans']['stringUnit'].update(value='App %@'))
        self.assertRejected('placeholders differ')

    def test_missing_key(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'privacy.body', 'ui.absent')
        self.assertRejected('missing key')

    def test_raw_literal(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'privacy.body', 'Untranslated title')
        self.assertRejected('raw user-facing literal')

    def test_english_copied_into_chinese(self):
        self.edit_catalog(APP, lambda d: d['strings']['ui.storage_retry']['localizations']['zh-Hans']['stringUnit'].update(value='Your input is kept. Check local storage and retry.'))
        self.assertRejected('English copied into Chinese')

    def test_widget_explicit_missing_table(self):
        self.mutate(WIDGET_VIEW, 'tableName: "Widgets"', 'tableName: "MissingTable"')
        self.assertRejected('unavailable table: MissingTable')

    def test_widget_dynamic_key_missing_table(self):
        self.mutate(WIDGET_VIEW, 'Text(stateMessage, tableName: "Widgets")', 'Text(stateMessage, tableName: "MissingTable")')
        self.assertRejected('unavailable table: MissingTable')

    def test_intent_resource_missing_table(self):
        self.mutate('PetalWidgets/Intents/OpenCardIntent.swift', 'table: "Widgets"', 'table: "MissingTable"')
        self.assertRejected('unavailable table: MissingTable')

    def test_widget_cannot_use_app_default_table(self):
        self.mutate(WIDGET_VIEW, 'tableName: "Widgets"', 'tableName: "Localizable"')
        self.assertRejected('unavailable table: Localizable')

    def test_widget_cannot_use_app_only_key(self):
        self.mutate(WIDGET_VIEW, '"ui.open_card.32bf59", tableName: "Widgets"', '"privacy.body", tableName: "Widgets"')
        self.assertRejected('missing key')

    def test_app_cannot_use_widget_key_in_default_table(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'privacy.body', 'ui.open_card.32bf59')
        self.assertRejected('missing key')

    def test_widget_module_bundle_is_invalid(self):
        self.mutate(WIDGET_VIEW, 'tableName: "Widgets"', 'tableName: "Widgets", bundle: .module')
        self.assertRejected('invalid bundle')

    def test_app_module_bundle_is_invalid(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'Text("privacy.body")', 'Text("privacy.body", bundle: Bundle.module)')
        self.assertRejected('invalid bundle')

    def test_notification_package_cannot_use_main_bundle(self):
        self.mutate(NOTIFICATION_SOURCE, 'bundle: .module', 'bundle: .main')
        self.assertRejected('invalid bundle')

    def test_notification_package_cannot_implicitly_use_main_bundle(self):
        self.mutate(NOTIFICATION_SOURCE, ', bundle: .module', '')
        self.assertRejected('invalid bundle')

    def test_notification_package_table_must_exist(self):
        self.mutate(NOTIFICATION_SOURCE, 'bundle: .module', 'table: "Widgets", bundle: .module')
        self.assertRejected('unavailable table: Widgets')

    def test_notification_package_cannot_use_core_only_key(self):
        self.mutate(NOTIFICATION_SOURCE, 'ui.complete.143b27', 'ui.inbox.94835e')
        self.assertRejected('missing key')

    def test_core_helper_cannot_switch_to_main_bundle(self):
        self.mutate('Packages/PetalKit/Sources/PetalCore/PetalStrings.swift', 'bundle = .module', 'bundle = .main')
        self.assertRejected('invalid bundle')

    def test_core_helper_table_must_exist(self):
        self.mutate('Packages/PetalKit/Sources/PetalCore/PetalStrings.swift', 'table: "Localizable"', 'table: "MissingTable"')
        self.assertRejected('unavailable table: MissingTable')

    def test_core_helper_cannot_resolve_notification_only_key(self):
        self.mutate('Packages/PetalKit/Sources/PetalPersistence/SwiftDataPetalRepository.swift', 'ui.inbox.94835e', 'ui.complete.143b27')
        self.assertRejected('missing key')

    def test_unknown_dynamic_bundle_fails_closed(self):
        self.mutate(WIDGET_VIEW, 'tableName: "Widgets"', 'tableName: "Widgets", bundle: otherBundle')
        self.assertRejected('unresolved bundle')

    def test_unknown_dynamic_table_fails_closed(self):
        self.mutate(WIDGET_VIEW, 'tableName: "Widgets"', 'tableName: otherTable')
        self.assertRejected('unresolved table')

    def test_explicit_main_bundle_is_valid_for_app(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'Text("privacy.body")', 'Text("privacy.body", tableName: "Localizable", bundle: Bundle.main)')
        self.assertEqual(module.verify(self.root), [])

    def test_explicit_module_bundle_is_valid_for_package(self):
        self.mutate(NOTIFICATION_SOURCE, 'bundle: .module', 'bundle: Bundle.module')
        self.assertEqual(module.verify(self.root), [])

    def test_app_can_resolve_explicitly_shared_widgets_table(self):
        self.mutate('PetalChecklist/Settings/PrivacyView.swift', 'Text("privacy.body")', 'Text("privacy.body"); Text("ui.open_card.32bf59", tableName: "Widgets")')
        self.assertEqual(module.verify(self.root), [])

if __name__ == '__main__': unittest.main()
