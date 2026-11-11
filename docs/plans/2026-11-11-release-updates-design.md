# Release updates

Use the existing GitHub Release ZIP assets, without a separate appcast service. Check at launch and every 24 hours, with a manual check in the app menu and Settings. Alpha builds include prereleases by default; users can change both automatic checking and prerelease participation in Settings.

Compare semantic versions, including numeric prerelease identifiers. Select the newest eligible non-draft release and the ZIP matching the running architecture. Display release notes, download only after the user clicks Install, verify GitHub's SHA-256 digest and an Ed25519 detached signature against the public key pinned in the installed app, then validate bundle identity/version, minimum macOS, architecture and code signature. Developer ID builds must retain their signing team. Unsuitable or missing archives offer the release page instead.

Stage a verified app beside the installed bundle. Save documents and respect terminal-session cancellation before quitting. A detached installer waits for the old process to exit, swaps bundles, and opens the new app; replacement/launch failures restore the previous bundle. Read-only/translocated apps explain that they need to be moved to Applications. Paths are passed as process arguments, never interpolated into shell source.

The VERSION file is the default release version; BETTERTEX_VERSION and BETTERTEX_BUILD_NUMBER can override packaging. Future releases must attach the generated architecture-specific ZIP and its `.zip.sig` alongside the DMG. The signing key stays outside the repository and is supplied explicitly when packaging. Existing releases cannot gain an updater retroactively.

Validate semantic ordering, release filtering, HTTP failures, digest mismatch, bundle checks, install/rollback in temporary directories, cancellation and UI states. Run the full suite and native build/run script before delivery.

## Validation

- Full suite: 73 tests, 72 passed, the opt-in live Overleaf test skipped.
- Temporary signed fixture bundles: preparation, version/identity/OS/signature rejection, archive symlink rejection, install, launch-failure rollback, and waiting for the parent process. Installation tests use isolated directories and controlled launch commands.
- Native UI: both Settings and the app menu can check the real GitHub releases; current version reports up to date. Temporarily stamping the local build as alpha.1 showed alpha.2, its release notes and Download and Install. A real download passed the asset check and was rejected at bundle validation because that old public package predates release-version metadata, leaving the current app intact.
- Release configuration built and launched successfully, restored to VERSION (0.1.0-alpha.2). Existing First Paper workspace and auto-preview were restored. No public release was created or modified; successful installation of a future public release remains dependent on publishing the documented ZIP.

## PR review follow-up

- Publisher authentication: require an Ed25519 signature before extracting any archive; unsigned releases offer manual download. Pin the public key in the app and keep the private key outside Git. Add interoperable signing/verification tooling and publishing instructions.
- Rollback: track whether the old and new apps have moved. If recovery cannot restore the old app, retain both files, report `recovery-required` with the backup path, and never reopen the new app automatically.
- Resources: replace fatal `Bundle.module` use in BetterTeXCore with optional discovery, localized fallback and throwing required-resource lookup. Validate resources in app packaging and both the staged and mounted DMG.
- Keep the existing restart-language hint and remove forced version unwraps during release ordering.

Follow-up validation: 78 tests executed (77 passed, 1 opt-in live Overleaf skip). Tests cover signed archive preparation, tampering/wrong-key rejection before extraction, signing-tool interoperability and private-file permissions, failed rollback without a second launch, and absent resources. The release build generated a detached signature verified against the pinned public key; app launch and English localization were inspected. DMG staging and mounted app resource/signature checks passed. Removing the installer from an isolated app copy correctly failed packaging. Resource bundles are replaced and signed individually so incremental builds cannot retain obsolete signatures; FileProvider metadata cleanup has bounded retries and still fails closed on a bad bundle.

## Second review follow-up

Installation requires a one-shot explicit restart request. Cancelling save/session termination clears it; Later and ordinary quitting never launch the installer. Normal quit discards the uninstalled download. A typed pending-update lifecycle owns this transition and is covered by effect-based tests.

Staging directories carry an application path, creation date and owner PID; the installer records its PID. Startup collection only removes recorded, idle copies older than 24 hours for this exact installation. Unknown directories, symlinks and any recovery backup are preserved. The staging lease is refreshed before launching the helper, and timeout before any swap removes only the unused staged copy.

Automatic-check and prerelease controls persist their own values independently, preserving the prerelease channel’s inferred default unless it is explicitly changed.

Second follow-up validation: 86 tests executed (85 passed, 1 opt-in live Overleaf skip). New tests cover normal quit, cancelled and failed restart requests, one-shot installation, conservative staging collection, helper timeout before swapping, independent update preferences, command/template conflicts, and commented label hints. The release build and app launch passed, the generated ZIP signature verified against the pinned public key, and DMG staging and mounted app validation passed.

## Third review follow-up

Automatic update notices use `orderFront` without making the update window key; manual checks can bring the same window into focus. Install/restart actions have no default Return binding. This preserves editor input when a release is discovered and requires deliberate button activation. The controller carries the user-initiated flag through both immediate and deferred automatic presentation paths.

The exit lifecycle, staging cleanup and publisher-authentication concerns repeated in this review were already addressed in the previous follow-ups. Both READMEs now explicitly describe publisher signatures, and the guide documents focus and keyboard behavior alongside the existing cancellation rules.

Third follow-up validation: 88 tests executed (86 passed, 2 skipped: the opt-in live Overleaf test and focus verification requiring an active macOS GUI test host). The AppKit Return-event test passed and confirmed explicit clicks still work; temporarily restoring the old Return binding made that regression test fail. The focus test is included but was not validated in this environment: test windows could not activate and the native UI inspection tool timed out. The release build, launch/process check, resource/code-signature validation and detached ZIP signature verification passed.
