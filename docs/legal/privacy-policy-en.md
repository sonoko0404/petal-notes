# Privacy

Effective date: September 24, 2026

Petal Checklist stores cards, todos, completion states, reminders, and import history locally on your Mac. The app and widget share a sandboxed local store. Device preferences, widget layout, shortcuts, and onboarding completion stay local and are excluded from Petal JSON backups and iCloud replication.

When iCloud sync is enabled, card and reminder data are replicated through Apple's CloudKit private database for your Apple Account. Apple provides this service under its own terms. Petal has no developer-operated content server, Petal account, advertising, or analytics SDK, and the developer does not collect your card contents or usage analytics. Your Mac login and Apple's services protect access; Petal does not provide an additional password lock or custom encryption.

Notifications are optional. Petal asks for permission when you save your first enabled reminder, and schedules notifications on each authorized device. Notification text may reveal todo content on your lock screen according to macOS settings. Sound is off by default. You can change notification permission in System Settings.

You can import Windows notes, export JSON backups or Markdown, and replace your data from a JSON backup. Files are written to locations you choose. You control any copies you share or store elsewhere. A full restore replaces the dataset on all synced devices; it is not a local-only merge. Backups include reminder sound preference but exclude device layout and onboarding state.

Trash and recoverable conflict copies are retained for 30 days and cleaned up when the app next processes the store. Content-free deletion metadata can remain in private iCloud to prevent older offline edits from returning. Very old devices with genuinely newer edits may restore records after the 30-day deletion-precedence window. Pending cloud changes require sync to be enabled and iCloud to be available; disabling sync keeps the local copy and does not erase the cloud copy.

Delete All Data requires the localized product name and replaces data with one empty Inbox. Deletion propagates to all synced devices when they connect. Local cleanup and widget refresh can be retried if they fail. Cloud deletion is asynchronous: check sync status, and reconnect other devices. External backups, exports, Apple-managed backups, and copies you shared are not deleted by Petal. Recovery is possible only from copies you retained.

Feedback opens your email app with only app version, build, macOS version, and architecture. No card content, identifiers, paths, logs, or diagnostics are automatically attached. You choose whether to send and what to include. Your email provider and a configured support mailbox receive any email you send. The development build has no support mailbox configured; it will be configured before release.

This static help site uses no cookies, analytics, scripts, remote fonts, or external resources. GitHub Pages hosting may process standard connection information under GitHub's own privacy terms; Petal adds no tracking.
