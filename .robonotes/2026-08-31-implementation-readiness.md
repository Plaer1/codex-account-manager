# Implementation readiness — 2026-08-31

## Audit disposition

Research and local auditing are complete enough to implement without another discovery pass.

No app code, auth data, profile data, running process state, or deployment was changed during this pass. The only repository changes are these `.robonotes` sidecars.

## What is settled

- Another physical machine is not involved.
- Codex must own token refresh and its updated live auth must be persisted.
- The manager's custom OAuth refresh path must be removed.
- Stale managed-login seeds must never be promoted as recovery credentials.
- Switching must save the verified outgoing live bundle after Codex quits and before target activation.
- Identity, not the active marker or Team account ID, authorizes a profile write.
- A profile that needs login gets a fresh isolated official `codex login` flow with identity verification.
- The permanent sidebar is not navigation and should be replaced by toolbar status/actions.
- The four-way-tile acceptance size on this Mac is 840×498 points.
- The hard window minimum should be reduced to about 520×420 points.

## What remains unknowable—and does not block the fix

The retained files do not reveal the exact server-side moment that upduck1's refresh token was revoked/superseded. The missing event could have been Codex's normal same-Mac refresh followed by lost writeback, a same-Mac re-login, or a competing local refresh attempt. The user has ruled out another physical machine.

The planned transaction and re-auth model prevents all of those local stale-copy paths without depending on the missing timestamp.

## Proposed implementation sequence

### Slice 1 — Stop credential damage and polling noise

- Remove direct OAuth refresh and auth-writing quota code.
- Make quota reads read-only.
- Add one active-profile request at a time, slower cadence, caching, cancellation, and backoff.
- Remove `Restore Original Auth` from the main view, menu-bar view, README, and supported CLI.
- Add regression tests proving quota code cannot write any auth path or call the OAuth endpoint.

### Slice 2 — Transactional account activation

- Add an identity-aware switch transaction shared by window, menu bar, and CLI.
- Require Codex to stop; persist verified outgoing live auth; atomically install target; commit markers; relaunch.
- Add preflight, journaled backup, rollback, and non-secret operation logs.
- Add crash/failure injection tests at every transaction boundary.

### Slice 3 — Safe re-authentication

- Add `Re-authenticate Profile` using a fresh isolated `CODEX_HOME` and official `codex login`.
- Verify the returned JWT subject/email against `identity.json` before promotion.
- Support inactive and active profile promotion through the same transaction service.
- Remove the temporary duplicate after successful promotion.
- Mark upduck1 `Needs re-authentication`; do not activate its old retained seed.

### Slice 4 — Credential-store migration

- Convert managed-home files from activatable recovery sources to identity evidence/quarantined archives.
- Inventory three orphan managed homes in the UI or migration report.
- Do not delete orphan or recovery credentials automatically; request an explicit cleanup confirmation after the fixed app is verified.
- Detect unsupported keyring-only configuration and fail with a clear explanation.

### Slice 5 — Compact native UI

- Remove the 1,395-line dead manager UI tree.
- Replace the active 270-point sidebar with a native toolbar.
- Move active profile/current state into compact toolbar status controls.
- Move theme/folder utilities to menu/Settings/overflow and retain privacy as a compact toggle.
- Build responsive wide, quarter-tile, and narrow account layouts.
- Remove redundant idle chrome and large disabled state controls.
- Lower both AppKit and SwiftUI minimums to 520×420.

### Slice 6 — Verification before redeploy

- Run identity, transaction, re-auth, rollback, polling, storage-permission, and layout tests.
- Build without touching the running app first.
- Launch a test bundle against fixture-only `SWITCHER_HOME` and `CODEX_AUTH_FILE` paths.
- Verify the real live and saved auth SHA-256 fingerprints are unchanged by tests.
- Present the changes and test results to the user before replacing/restarting the deployed manager.

## Release gates

The fixed build is not ready to redeploy unless all are true:

- No application code calls `auth.openai.com/oauth/token`.
- No quota path writes any auth file.
- No supported action can restore a managed-login seed.
- Every switch persists the identity-matched outgoing live bundle.
- Switch aborts if Codex remains running or identity is ambiguous.
- Wrong-account re-auth leaves all existing auth byte-identical.
- Four-way tiling works at 840×498.
- Narrow mode works at 520×420 without horizontal scrolling.
- Logs contain no credentials and are bounded/rotated.
- Existing real profiles are not altered during fixture tests.

## Expected user-visible recovery for upduck1

The old upduck1 refresh token cannot be repaired locally if the server rejects it. After the safe re-auth button exists, the user will need to complete one fresh browser login for the intended upduck1 account. The app will verify that identity and install the fresh bundle without using the Bryant backup or the old managed seed.

## Permission boundary

Implementation and redeployment intentionally stop here pending user approval.
