#!/usr/bin/env python3
import sys, json, re
def verify(root):
    root = root.resolve()
    errors = []
    keys = set()
    catalogs_by_path = {}
    sources = [p for p in root.rglob('*.swift') if not any(x in p.parts for x in ('.build', 'Tests', 'PetalChecklistTests', 'PetalChecklistUITests', 'scripts'))]
    source = '\n'.join(p.read_text() for p in sources)
    placeholders = lambda text: sorted(re.findall(r'%(?:\d+\$)?(?:lld|ld|@|d|f)', text))
    def units(value):
        if isinstance(value, dict):
            if 'stringUnit' in value: yield value['stringUnit']
            for key, item in value.items():
                if key != 'stringUnit': yield from units(item)
    catalogs = [p for p in root.rglob('*.xcstrings') if '.build' not in p.parts]
    for path in catalogs:
        try: catalog = json.loads(path.read_text())
        except Exception as error:
            errors.append(f'{path}: {error}'); continue
        catalogs_by_path[path] = set(catalog['strings'])
        for key, entry in catalog['strings'].items():
            keys.add(key)
            if entry.get('extractionState') == 'stale': errors.append(f'{path}: stale {key}')
            if not key.startswith(('ui.', 'help.', 'privacy.', 'CFBundle')): errors.append(f'{path}: non-programmatic key {key}')
            localized = entry.get('localizations', {})
            english = [u.get('value') for u in units(localized.get('en', {}))]
            chinese = [u.get('value') for u in units(localized.get('zh-Hans', {}))]
            if english and english == chinese: errors.append(f'{path}: English copied into Chinese: {key}')
            expected = None
            for language in ('en', 'zh-Hans'):
                values = list(units(localized.get(language, {})))
                if not values: errors.append(f'{path}: missing {language}: {key}')
                for unit in values:
                    text = unit.get('value', '')
                    if unit.get('state') != 'translated' or not text.strip(): errors.append(f'{path}: untranslated {language}: {key}')
                    current = placeholders(text)
                    if expected is None: expected = current
                    elif current != expected: errors.append(f'{path}: placeholders differ: {key}')
            if key not in source and not key.startswith('CFBundle'):
                # SwiftUI interpolation turns expressions into typed format specifiers.
                prefix = key.split(' %')[0]
                if prefix not in source: errors.append(f'{path}: unused/stale key {key}')
    for path in sources:
        text = path.read_text()
        # Ignore documented preview fixtures and the test-only launch fixture block.
        text = text.split('enum ChecklistWidgetPreviews')[0]
        for key in re.findall(r'"((?:ui|help|privacy)\.[^"\n]*)"', text):
            normalized = re.sub(r'\\\([^)]*\)', '%@', key)
            if normalized not in keys: errors.append(f'{path}: missing key {normalized}')
            if 'PetalWidgets' in path.parts:
                available = set().union(*(k for p,k in catalogs_by_path.items() if 'PetalWidgets' in p.parts and p.stem == 'Widgets'))
                if normalized not in available: errors.append(f'{path}: missing Widgets resource: {normalized}')
            elif 'PetalChecklist' in path.parts:
                available = set().union(*(k for p,k in catalogs_by_path.items() if 'PetalChecklist' in p.parts and p.stem == 'Localizable'))
                if normalized not in available: errors.append(f'{path}: missing App resource: {normalized}')
        for match in re.finditer(r'\b(?:Text|Button|Toggle|TextField|Picker|ProgressView|GroupBox|Window|ContentUnavailableView|navigationTitle|accessibilityLabel|accessibilityHint|configurationDisplayName|String\(localized:|LocalizedStringResource)\s*\(?\s*"([^"\n]*)"', text):
            literal = match.group(1)
            if literal and not literal.startswith(('ui.', 'help.', 'privacy.')) and re.search('[A-Za-z\u4e00-\u9fff]', literal):
                errors.append(f'{path}: raw user-facing literal {literal}')
    return errors
if __name__ == '__main__':
    from pathlib import Path
    errors = verify(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'apple')
    print('\n'.join(errors) if errors else 'Localization verified')
    sys.exit(bool(errors))
