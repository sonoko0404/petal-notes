# Localization verification contract

Run `zsh apple/scripts/verify-localization.sh` and
`python3 apple/scripts/test-localization.py` from the repository root.

`localization-manifest.json` declares exactly six source catalogs, their table
names, source owners, destination bundles, and mandatory anchor keys. Every
statically referenced key is additionally required in its actual lookup table.
The two InfoPlist catalogs each require both `CFBundleDisplayName` and
`CFBundleName`, even though these keys have no Swift call site.

| Source owner | Table | Runtime resource bundle |
| --- | --- | --- |
| PetalChecklist | Localizable | PetalChecklist main bundle |
| PetalChecklist | InfoPlist | PetalChecklist main bundle |
| PetalWidgets | Widgets | PetalWidgets and PetalChecklist main bundles |
| PetalWidgets | InfoPlist | PetalWidgets main bundle only |
| PetalCore | Localizable | PetalKit_PetalCore module bundle |
| PetalNotifications | Localizable | PetalKit_PetalNotifications module bundle |

Widget sources are also compiled into the App for hosted tests/intents, so its
Widgets table is intentionally installed in both main bundles. The App's
Localizable/InfoPlist tables must never be copied into the Widget. The verifier
resolves PBX groups/file references and each target's resources phase rather
than assuming directory membership proves installation. It also checks both
SwiftPM resource-processing declarations. Missing, extra, renamed, nested
duplicate, and incorrectly registered catalogs fail.

The Swift lookup scanner balances call arguments, ignores comments, and visits
interpolation expressions. It checks `Text`/other common SwiftUI localizable
initializers, `String(localized:)`, `LocalizedStringResource`,
`NSLocalizedString`, and `Bundle.localizedString`. Literal `table`/`tableName`
arguments must resolve in the chosen bundle. `.main`/`Bundle.main` and
`.module`/`Bundle.module` are resolved separately; package-local strings cannot
silently fall back to a host's main bundle. Unknown table or bundle expressions
fail closed, including calls whose keys are variables.

`PetalStrings.text` has a bounded, checked provenance contract: its optional
language bundle must come from `Bundle.module`'s lproj directory, and its other
branch must remain `.module`. Its actual table is checked and used for callers
in other packages. The Markdown export's one-line wrapper is recognized only
when it delegates to this checked helper. Changing these helper shapes requires
updating this contract and adding mutations; they are not allowlisted strings.

This is a static checker, not a complete Swift parser/type checker. The current
Widget's typed key branches are checked against Widgets, while each receiving
call's explicit table/bundle is checked independently. Arbitrary runtime-built
keys, future custom wrappers, or new raw/multiline-string syntax require manual
review and scanner tests. User-authored content and preview/test fixtures are
not catalog identities. The framework-localized allowlist is deliberately
empty; any future entry must be an individually documented Apple/framework
lookup, never an application key or source-file exemption.

Mutation tests copy real production files. Their six expected paths and
InfoPlist keys are independently spelled out, not loaded from the manifest.
Positive controls also exercise explicit main/module bundles and the App's
intentionally shared Widgets table.
