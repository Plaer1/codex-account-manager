# Auth Lifecycle and Compact Window Implementation

Date: 2026-08-31
Status: Implemented and locally verified; not redeployed.

## Scope

Implemented the approved findings from the auth lifecycle and compact window audits. The working tree already contained the profile nickname and identity-anchor work; this change preserves it and hardens the account switch boundary around it.

## Auth changes

- Removed the manager's direct OAuth refresh implementation, including the hard-coded token endpoint call and writes to whichever auth copy happened to be polled.
- Usage polling now reads only the live auth for the active profile, uses saved auth only for inactive profile display, refreshes at most once per minute, and refuses overlapping refresh passes. Managed-login homes are no longer quota sources.
- Removed `restore-reference-auth` from the shell command surface and all user-facing actions. A managed-login home is no longer treated as an authoritative or recoverable token seed.
- `make-active`/`switch` now affect the live auth and active-profile marker only. They quit Codex first, verify the target identity, persist the outgoing live auth, atomically install the target auth, and reopen Codex. Desktop state is intentionally independent.
- `make-state` remains a separate restart-based operation. It saves the current live auth before replacing the Desktop state and updates the state marker only after the state source has been validated.
- Codex shutdown is now a hard precondition. If the process remains alive, the operation fails before auth/state mutation.
- Shell-side auth writes now use same-directory temporary files plus rename, and profile operations compare JWT `sub` with email fallback. Shared Team `account_id` is not used as identity.
- Added `replace-auth <profile> <codex-home>` for re-authentication. The Swift button creates an isolated file-backed `CODEX_HOME`, runs `codex login`, checks the returned identity against the profile anchor, replaces only that profile, stores a recovery copy, and removes the temporary login home. If active, the live auth is replaced only while Codex is stopped and Codex is opened again.
- Added a safe manual `Update Auth Token` path for a live login of the same anchored identity; it is identity-gated and restart-based.
- New profile imports create an identity anchor and no longer retain `managed_codex_home` references.

## UI changes

- Removed the fixed sidebar from the active dashboard.
- Moved active-profile and current-state information into a compact top status row; theme, privacy, and profile-folder controls are in the overflow menu.
- Reduced the SwiftUI and AppKit minimum window size from 1120×640 to 520×420 points.
- Reduced the card grid minimum width from 360 to 300 points and compacted card actions so a quarter-width MacBook window can use two columns and scroll naturally.
- The visible actions are now `Make Active Profile`, `Re-authenticate`, `Update Auth Token`, and `Use This State`; there is no reference-auth restore button.

## Verification

Passed on this Mac:

- `bash -n codex-account-switcher.sh`
- `tests/SwitcherAuthTransactionTests.sh`
  - outgoing auth persistence during switch
  - stale marker resolution by verified identity
  - identity-mismatched target refusal
  - no writes if Codex cannot quit
  - anchored inactive-profile re-auth replacement
  - removed `restore-reference-auth` command rejection
- `swiftc AccountIdentity.swift tests/AccountIdentityTests.swift` plus test execution
- temporary full app compile with `swiftc AccountIdentity.swift CodexAccountSwitcher.swift -framework AppKit -framework SwiftUI`
- `git diff --check`
- source scan for the direct OAuth refresh endpoint, old refresh helper, managed-home restore command, and managed-home references in the active code/docs

No live auth, profile, managed-home, or installed app files were changed during verification. The existing installed app was not rebuilt, replaced, restarted, or redeployed.

## References

- [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth)
- [OpenAI Codex auth lifecycle guidance](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
- [OpenAI `CODEX_HOME` documentation](https://learn.chatgpt.com/docs/config-file/environment-variables)
