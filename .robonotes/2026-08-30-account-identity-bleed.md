# Account identity and nickname bleed fix — 2026-08-30

## Reported symptom

The `upduck1` nickname appeared above the redacted Bryant Gmail address after profiles were switched. The same card was marked as both the active profile and current state even though it had no saved Desktop state.

## Local diagnosis

- The live `~/.codex/auth.json` belongs to the same JWT user subject as the saved `bryanteliott` profile.
- The recorded active-profile marker incorrectly points to `whatsupduck13`.
- `whatsupduck13/auth/auth.json` was overwritten with the Bryant user's auth during an earlier explicit auth update.
- The retained managed-login auth for `whatsupduck13` still belongs to its original redacted `wh…@gmail.com` user, so recovery remains possible.
- All inspected Team profiles expose the same token `account_id` even though their JWT user subjects and emails differ. The old safety check compared `account_id` before email, so it incorrectly approved a cross-user overwrite.
- Nicknames were stored on profile folders without an immutable user-identity anchor, allowing a nickname to remain visible after that folder's auth changed users.
- `active-state` previously fell back to the active-profile marker when no state marker existed, producing a false Current State badge on auth-only profiles.

No tokens or complete identity values were printed or copied into this note.

## Source changes

- Added `AccountIdentity`, keyed primarily by JWT `sub` with normalized email as fallback. Shared Team `account_id` is no longer accepted as user identity.
- Added per-profile `identity.json` anchors. On first launch, managed-login profiles anchor to their retained original login; other profiles anchor to their current saved auth.
- Added fail-closed mismatch handling:
  - hide the nickname when saved auth belongs to a different user;
  - show an Identity Mismatch badge;
  - suppress potentially misattributed usage data;
  - block account/state switching and nickname edits until repaired;
  - keep Update Auth Token restricted to the anchored user.
- Active Profile is now resolved from the live auth identity. A stale marker is corrected only when exactly one non-mismatched saved profile matches the live user.
- Removed the implicit active-state fallback and validate that a Current State profile really has saved Desktop state.
- Added Restore Original Auth for mismatched managed-login profiles. It backs up the displaced auth under `auth/recovery/` before restoring the retained original copy; it does not touch live auth or switch accounts.
- Capture now preserves profile metadata such as managed-login references instead of rewriting `profile.env` down to a few fields.
- Updated documentation and build inputs for the new identity module.

## Verification completed without deployment

- Compiled the full macOS executable to an isolated `/tmp` directory.
- Ran identity regression tests covering different users that share one Team `account_id`, same-user refreshes, email fallback, and stale active-marker correction.
- Ran shell syntax checks and `git diff --check`.
- The recovery-command fixture verifies both restoration and creation of a backup copy.

## Deployment completed

- Ran `build-app.sh` successfully and relaunched Codex Account Manager.
- Did not restart Codex Desktop.
- Startup created the identity anchors and corrected the stale active marker from `whatsupduck13` to `bryanteliott`.
- Startup left the state marker empty because the recorded profile has no saved Desktop state.
- SHA-256 checks confirmed the live auth, Bryant profile auth, mismatched profile auth, and retained managed-login auth were unchanged by deployment.

The `whatsupduck13` card should now show Identity Mismatch and offer Restore Original Auth. Use that action, review the restored identity, then make it active. If its retained token is revoked, re-login as the intended `wh…` user and use Update Auth Token.
