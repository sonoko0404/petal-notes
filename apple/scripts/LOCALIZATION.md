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

## Closed dynamic-key contracts

`localization-dynamic-contracts.json` binds each current dynamic lookup to a
closed key set, required table, required bundle, source path, callee, and exact
key expression (Swift tokens, insensitive to whitespace/comments). Each listed
receiving site must occur exactly once. Table existence alone is insufficient:
`Text(stateMessage, tableName: "InfoPlist")` fails even if every state key is
copied into that existing table.

| Producer | Closed keys | Receiving sites | Required bundle/table |
| --- | ---: | ---: | --- |
| Widget stateMessage | 5 | 1 | PetalWidgets/Widgets |
| Widget badge label | 3 | 1 | PetalWidgets/Widgets |
| App scopeName | 5 | 3 | PetalChecklist/Localizable |
| App statusKey | 7 | 1 | PetalChecklist/Localizable |
| Widget completion ternary | 2 | 1 | PetalWidgets/Widgets |
| App reset-action ternary | 2 | 1 | PetalChecklist/Localizable |
| Core key forwarder | 6 | 1 | PetalKit_PetalCore/Localizable |
| Markdown key forwarder | 4 | 1 | PetalKit_PetalCore/Localizable |

The four typed producer bodies are checked against the reviewed token-level
branch definitions and their declared key sets. The relevant input bindings
and complete `WidgetCardState`, `WidgetSyncBadge`, `LibraryScope`, `SyncState`,
and `SyncFailure` domains are checked too. Thus even a new badge case that Swift
would silently route through the final ternary branch requires localization
review. A new nested sync failure similarly cannot silently inherit fallback
copy. Literal inputs to the forwarding helpers must belong to their closed
sets; new dynamically computed inputs fail until a separate contract is added.

All `LocalizedStringKey` declarations must be contracted. New consumers of a
known typed key, inferred aliases of those keys, duplicate/missing receiving
sites, and uncontracted explicit dynamic localization calls fail closed. Swift
`String` user content or already-translated text displayed by `Text` is not a
localized-key lookup. Nested `Text` passed to an accessibility modifier is
checked at its lookup, not incorrectly treated as another key.

This is a bounded static checker, not a complete Swift parser/type checker.
Changes to producer branch shapes, enum domains, forwarding sets, or call sites
require explicit contract review and independent mutations. Future custom APIs
or unsupported Swift syntax require scanner tests; this is not a proof for
arbitrary third-party Swift. User-authored content and preview/test fixtures
are not catalog identities. The framework-localized allowlist is deliberately
empty; any future entry must be an individually documented Apple/framework
lookup, never an application key or source-file exemption.

Mutation tests copy real production files. Their six expected paths and
InfoPlist keys are independently spelled out, not loaded from the manifest.
Positive controls also exercise explicit main/module bundles and the App's
intentionally shared Widgets table. Dynamic-key mutations change production
Swift/catalog inputs only; they never rewrite the contracts to agree with the
mutation. Producer/branch deletion, enum widening, wrong existing tables,
wrong bundles, moved keys, aliases, and forwarding-set widening are covered.
