# Release configuration gate

Before Task 13 submission, the owner must supply and verify a support mailbox and set `PETAL_FEEDBACK_EMAIL` in the release build configuration. The development default is deliberately empty; the app disables Feedback and explains why. Do not invent an address or imply ownership of a domain.

The current help/privacy copy explicitly identifies that development limitation. Update the approved Markdown and matching app catalogs when the mailbox is configured, then run `ruby apple/scripts/generate-site.rb` and the site/localization verifiers before publishing. Pages must be enabled deliberately by the owner; Task 11 does not publish, push, or enroll an external account.

Keep the checked-in localization keys stable when editing wording. Their suffixes were allocated during migration to distinguish previously colliding English labels, and must not be regenerated from revised English text. `ThemeID`, shortcut IDs, widget IDs, database keys, and CloudKit records never use these display keys.
