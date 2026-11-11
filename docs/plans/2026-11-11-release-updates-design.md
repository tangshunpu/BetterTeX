# Release updates

Use the existing GitHub Release ZIP assets, without a separate appcast service. Check at launch and every 24 hours, with a manual check in the app menu and Settings. Alpha builds include prereleases by default; users can change both automatic checking and prerelease participation in Settings.

Compare semantic versions, including numeric prerelease identifiers. Select the newest eligible non-draft release and the ZIP matching the running architecture. Display release notes, download only after the user clicks Install, verify GitHub's SHA-256 digest, bundle identity/version, minimum macOS, architecture and code signature. Developer ID builds must retain their signing team. Unsuitable or missing archives offer the release page instead.

Stage a verified app beside the installed bundle. Save documents and respect terminal-session cancellation before quitting. A detached installer waits for the old process to exit, swaps bundles, and opens the new app; replacement/launch failures restore the previous bundle. Read-only/translocated apps explain that they need to be moved to Applications. Paths are passed as process arguments, never interpolated into shell source.

The VERSION file is the default release version; BETTERTEX_VERSION and BETTERTEX_BUILD_NUMBER can override packaging. Future releases must attach the generated architecture-specific ZIP alongside the DMG. Existing releases cannot gain an updater retroactively.

Validate semantic ordering, release filtering, HTTP failures, digest mismatch, bundle checks, install/rollback in temporary directories, cancellation and UI states. Run the full suite and native build/run script before delivery.

## Validation

- Full suite: 73 tests, 72 passed, the opt-in live Overleaf test skipped.
- Temporary signed fixture bundles: preparation, version/identity/OS/signature rejection, archive symlink rejection, install, launch-failure rollback, and waiting for the parent process. Installation tests use isolated directories and controlled launch commands.
- Native UI: both Settings and the app menu can check the real GitHub releases; current version reports up to date. Temporarily stamping the local build as alpha.1 showed alpha.2, its release notes and Download and Install. A real download passed the asset check and was rejected at bundle validation because that old public package predates release-version metadata, leaving the current app intact.
- Release configuration built and launched successfully, restored to VERSION (0.1.0-alpha.2). Existing First Paper workspace and auto-preview were restored. No public release was created or modified; successful installation of a future public release remains dependent on publishing the documented ZIP.
