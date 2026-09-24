#!/usr/bin/env python3
import sys, json, re, subprocess
from pathlib import Path

MANIFEST = json.loads(Path(__file__).with_name('localization-manifest.json').read_text())['catalogs']

# No application strings are exempt. Add only documented Apple/framework-owned
# (callee, key) pairs here if one is ever required; never exempt a source file.
FRAMEWORK_LOCALIZED_ALLOWLIST = frozenset()
UI_CALLS = {'Text', 'Button', 'Toggle', 'TextField', 'Picker', 'ProgressView', 'GroupBox',
            'Window', 'ContentUnavailableView', 'Label', 'navigationTitle',
            'accessibilityLabel', 'accessibilityHint', 'accessibilityValue',
            'configurationDisplayName', 'description', 'Section'}

def swift_tokens(source):
    """Small lexical scanner, not a Swift compiler. Preserve balanced calls and
    parse interpolation expressions separately; ignore comments and string text."""
    tokens, interpolations = [], []
    i = 0
    while i < len(source):
        if source[i].isspace(): i += 1; continue
        if source.startswith('//', i):
            end = source.find('\n', i); i = len(source) if end < 0 else end; continue
        if source.startswith('/*', i):
            depth = 1; i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i): depth += 1; i += 2
                elif source.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            continue
        if source[i] == '"':
            value = ''; i += 1
            while i < len(source) and source[i] != '"':
                if source.startswith('\\(', i):
                    start = i + 2; i = start; depth = 1
                    while i < len(source) and depth:
                        if source[i] == '(': depth += 1
                        elif source[i] == ')': depth -= 1
                        i += 1
                    interpolations.append(source[start:i-1]); value += '%@'
                elif source[i] == '\\' and i + 1 < len(source):
                    value += source[i:i+2]; i += 2
                else: value += source[i]; i += 1
            tokens.append(('string', value)); i += 1; continue
        match = re.match(r'[A-Za-z_][A-Za-z_0-9]*', source[i:])
        if match:
            tokens.append(('id', match[0])); i += len(match[0])
        else: tokens.append(('punct', source[i])); i += 1
    return tokens, interpolations

def calls(tokens):
    for index, token in enumerate(tokens):
        if token != ('punct', '(') or index == 0 or tokens[index-1][0] != 'id': continue
        start = index - 1
        while start >= 2 and tokens[start-1][1] == '.' and tokens[start-2][0] == 'id': start -= 2
        name = ''.join(t[1] for t in tokens[start:index])
        depth = 0; begin = index + 1; args = []
        for end in range(begin, len(tokens)):
            value = tokens[end][1]
            if tokens[end][0] == 'punct':
                if value in ('(', '[', '{'): depth += 1
                elif value in (')', ']', '}'):
                    if depth == 0: args.append((begin, end)); break
                    depth -= 1
                elif value == ',' and depth == 0: args.append((begin, end)); begin = end + 1
        yield name, args

def verify_lookups(path, root, text, catalogs, errors, helper_table):
    relative = path.relative_to(root)
    if relative.parts[0] in ('PetalChecklist', 'PetalWidgets'): target = relative.parts[0]
    elif 'Sources' in relative.parts: target = relative.parts[relative.parts.index('Sources')+1]
    else: return
    package = target not in ('PetalChecklist', 'PetalWidgets')
    main_bundle = None if package else target
    module_bundle = 'PetalKit_'+target if package else None
    installed = {(bundle, e['table']): catalogs.get(root/e['path'], set())
                 for e in MANIFEST for bundle in e['bundles']}
    def check(bundle, table, key=None):
        if bundle is None: errors.append(f'{path}: invalid bundle for {target}'); return
        if (bundle, table) not in installed:
            errors.append(f'{path}: unavailable table: {table} in {bundle}'); return
        if key is not None and key not in installed[bundle, table]:
            errors.append(f'{path}: missing key {key} in {bundle}/{table}')
    def scan(source):
        tokens, nested = swift_tokens(source); consumed = set()
        for name, ranges in calls(tokens):
            args = {}; positional = []
            for a, b in ranges:
                if b-a >= 2 and tokens[a][0] == 'id' and tokens[a+1][1] == ':': args[tokens[a][1]] = (a+2,b)
                else: positional.append((a,b))
            leaf = name.split('.')[-1]
            helper = name == 'PetalStrings.text' or (name == 'localized' and
                re.search(r'func localized\(_ key: String\) -> String\s*\{\s*PetalStrings.text\(key, languageCode: languageCode\)\s*\}', text))
            explicit = 'tableName' in args or 'table' in args or 'bundle' in args
            localized = name == 'LocalizedStringResource' or name == 'NSLocalizedString' or (name == 'String' and 'localized' in args) or leaf == 'localizedString'
            if not (helper or localized or leaf in UI_CALLS): continue
            key_range = args.get('localized') or args.get('forKey') or (positional[0] if positional else (0,0))
            a,b = key_range; direct_keys = []; depth = 0
            for n in range(a,b):
                kind, value = tokens[n]
                if kind == 'punct':
                    if value in ('(', '[', '{'): depth += 1
                    elif value in (')', ']', '}'): depth -= 1
                if depth == 0 and kind == 'string' and value.startswith(('ui.', 'help.', 'privacy.')):
                    direct_keys.append((n,value))
            if not (helper or localized or explicit or direct_keys): continue
            if helper:
                bundle, table = 'PetalKit_PetalCore', helper_table
            else:
                table_range = args.get('tableName') or args.get('table')
                table_tokens = tokens[slice(*table_range)] if table_range else [('string','Localizable')]
                if table_tokens == [('id','nil')]: table_tokens = [('string','Localizable')]
                if len(table_tokens) != 1 or table_tokens[0][0] != 'string':
                    errors.append(f'{path}: unresolved table in {name}'); continue
                table = table_tokens[0][1]
                bundle_tokens = tokens[slice(*args['bundle'])] if 'bundle' in args else []
                expression = ''.join(t[1] for t in bundle_tokens)
                if leaf == 'localizedString': expression = name.rsplit('.',1)[0]
                if expression in ('', 'nil', '.main', 'Bundle.main'): bundle = main_bundle
                elif expression in ('.module', 'Bundle.module'): bundle = module_bundle
                elif expression == 'bundle' and target == 'PetalCore' and path.name == 'PetalStrings.swift': bundle = module_bundle
                else:
                    errors.append(f'{path}: unresolved bundle in {name}: {expression}'); continue
            check(bundle, table)
            for n,key in direct_keys:
                consumed.add(n)
                if (name,key) not in FRAMEWORK_LOCALIZED_ALLOWLIST: check(bundle,table,key)
        # Typed LocalizedStringKey branches (Widget state/badge labels) are bound
        # to the same declared Widget table. Explicit calls above still validate
        # their table/bundle even when their key is a variable.
        for n,(kind,key) in enumerate(tokens):
            if kind != 'string' or n in consumed or not key.startswith(('ui.', 'help.', 'privacy.')): continue
            check(main_bundle, 'Widgets' if target == 'PetalWidgets' else 'Localizable', key)
        for expression in nested: scan(expression)
    scan(text)

def verify_core_helper(root, errors):
    path = root/'Packages/PetalKit/Sources/PetalCore/PetalStrings.swift'
    text = path.read_text()
    # Deliberately bounded provenance proof: both branches are module-owned.
    # If this helper changes shape, update this contract and mutation tests.
    valid = (re.search(r'let path = Bundle\.module\.path\(forResource:', text) and
             re.search(r'let localized = Bundle\(path: path\)\s*\{ bundle = localized \}', text) and
             re.search(r'else\s*\{ bundle = \.module \}', text) and
             re.findall(r'\bbundle\s*=\s*([^}\n]+)', text) == ['localized ', '.module '])
    if not valid: errors.append(f'{path}: invalid bundle provenance in PetalStrings.text')
    match = re.search(r'localizedString\(forKey: key, value: nil, table: "([^"]+)"\)', text)
    if not match:
        errors.append(f'{path}: unresolved table in PetalStrings.text'); return None
    return match[1]

def inventory(root, errors):
    expected = {entry['path']: entry for entry in MANIFEST}
    actual = {str(p.relative_to(root)) for p in root.rglob('*.xcstrings') if '.build' not in p.parts}
    for path in sorted(expected.keys() - actual): errors.append('missing catalog: '+path)
    for path in sorted(actual - expected.keys()): errors.append('unexpected catalog: '+path)
    owners = set()
    for entry in MANIFEST:
        if Path(entry['path']).stem != entry['table']: errors.append('manifest table mismatch: '+entry['path'])
        for bundle in entry['bundles']:
            identity = (bundle, entry['table'])
            if identity in owners: errors.append('duplicate catalog ownership: '+str(identity))
            owners.add(identity)
    if len(expected) != len(MANIFEST): errors.append('duplicate catalog path in manifest')
    return expected

def verify_registration(root, errors):
    """Resolve actual Xcode groups/build phases and SwiftPM process declarations."""
    try:
        result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(root/'PetalChecklist.xcodeproj/project.pbxproj')], capture_output=True, text=True, check=True)
        project = json.loads(result.stdout)
        objects = project['objects']; paths = {}
        def walk(identifier, parent):
            obj = objects[identifier]
            path = parent / obj.get('path', '')
            if obj['isa'] == 'PBXGroup':
                for child in obj.get('children', []): walk(child, path)
            elif obj['isa'] == 'PBXFileReference': paths[identifier] = str(path)
        walk(objects[project['rootObject']]['mainGroup'], Path())
        resources = {}
        for obj in objects.values():
            if obj['isa'] != 'PBXNativeTarget': continue
            files = []
            for phase_id in obj['buildPhases']:
                phase = objects[phase_id]
                if phase['isa'] == 'PBXResourcesBuildPhase':
                    files += [paths.get(objects[build]['fileRef']) for build in phase['files']]
            resources[obj['name']] = files
        for entry in MANIFEST:
            if entry['target'] not in ('PetalChecklist', 'PetalWidgets'): continue
            for target, files in resources.items():
                wanted = 1 if target in entry['bundles'] else 0
                if files.count(entry['path']) != wanted:
                    errors.append(f"resource ownership: {entry['path']} must occur {wanted} time(s) in {target}")
        package = (root/'Packages/PetalKit/Package.swift').read_text()
        for target in ('PetalCore', 'PetalNotifications'):
            if not re.search(r'\.target\(name:\s*"'+target+r'"[^\n]*resources:\s*\[\.process\("Resources"\)\]', package):
                errors.append('resource ownership: missing SwiftPM Resources processing for '+target)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        errors.append('resource ownership: cannot resolve project/package registrations: '+str(error))

def verify(root):
    root = root.resolve()
    errors = []
    expected_catalogs = inventory(root, errors)
    verify_registration(root, errors)
    catalogs_by_path = {}
    sources = sorted(p for p in root.rglob('*.swift') if not any(x in p.parts for x in ('.build', 'Tests', 'PetalChecklistTests', 'PetalChecklistUITests', 'scripts')))
    source = '\n'.join(p.read_text() for p in sources)
    placeholders = lambda text: sorted(re.findall(r'%(?:\d+\$)?(?:lld|ld|@|d|f)', text))
    def units(value):
        if isinstance(value, dict):
            if 'stringUnit' in value: yield value['stringUnit']
            for key, item in value.items():
                if key != 'stringUnit': yield from units(item)
    catalogs = sorted(p for p in root.rglob('*.xcstrings') if '.build' not in p.parts)
    for path in catalogs:
        try: catalog = json.loads(path.read_text())
        except Exception as error:
            errors.append(f'{path}: {error}'); continue
        catalogs_by_path[path] = set(catalog['strings'])
        entry = expected_catalogs.get(str(path.relative_to(root)))
        if entry:
            for key in entry['requiredKeys']:
                if key not in catalog['strings']: errors.append(f'{path}: missing required key: {key}')
        for key, entry in catalog['strings'].items():
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
    helper_table = verify_core_helper(root, errors)
    for path in sources:
        text = path.read_text()
        # Ignore documented preview fixtures and the test-only launch fixture block.
        text = text.split('enum ChecklistWidgetPreviews')[0]
        verify_lookups(path, root, text, catalogs_by_path, errors, helper_table)
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
