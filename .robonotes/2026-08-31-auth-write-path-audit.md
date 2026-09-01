# Auth write-path and storage audit — 2026-08-31

## Scope

This note maps every path that creates, copies, refreshes, activates, archives, or deletes credentials. It records the implementation plan only; no path was changed in this pass.

## Mutation inventory

| Path | Source location | What it writes | Existing guard | Audit result |
| --- | --- | --- | --- | --- |
| Add Account | `CodexAccountSwitcher.swift:578-608` | New isolated managed home, then a profile copy | Browser login succeeds; unique profile name | Good isolation, but leaves two credential copies indefinitely |
| Capture | Swift `558-575`; shell `164-190`, `230-243` | Live auth and optional Desktop state into a profile; active markers | Swift identity check only when overwriting an existing profile | Direct shell invocation bypasses identity; direct `cp`; capture quits Codex |
| Update Auth Token | Swift `686-704`; shell `193-204`, `246-253` | Live auth into selected profile | Swift verifies live JWT subject/email against identity anchor | Shell command itself has no identity guard; also rewrites active marker |
| Make Active / Switch | Swift `612-650`; shell `283-289`, `359-384` | Target profile auth to live auth; optional state; markers | Swift blocks known identity mismatch; shell lock | Does not persist outgoing live auth; no rollback; direct copy isn't atomic |
| Make Current State | Swift `673-684`; shell `291-302` | Saved Desktop state to live Desktop-state path | Profile must have state | Quits/reopens Codex but does not persist a freshly flushed active auth bundle |
| Restore Original Auth | Swift `652-671`; shell `255-281` | Managed-home seed over profile auth; old profile copy to recovery | Requires identity mismatch and retained managed home | Unsafe concept: promotes stale seed without server validity; must be removed |
| Import auth | Swift `743-769`; shell `460-485` | External auth file into a new profile | New profile name only | Identity is anchored later, but shell accepts any parseable/nonempty file |
| Import managed home | shell `487-513` | Isolated login auth into profile, while retaining original | New profile only | Duplicate refresh credential remains available to unsafe recovery and polling |
| Quota auto-refresh | Swift `1094-1250` | Potentially rewrites live, saved, or managed auth after direct OAuth refresh | Access JWT must be near local expiry | Release blocker; conflicts with official Codex lifecycle |
| Active-marker correction | Swift `300-318`; shell `410-416` | Active marker only | Exactly one non-mismatched identity match | Identity correction is sound; marker is metadata, never authority to overwrite auth |
| Rename | shell `422-457` | Profile directory and marker names | Profile-name validation and lock | Auth bytes unchanged |
| Export | shell `515-530` | Credential-bearing zip | Existing profile; output mode 0600 | Warning is present; exported secret remains user responsibility |
| Delete | Swift `728-741`; shell `533-551` | Deletes profile directory | Cannot delete active profile/state | Does not delete referenced managed home; creates credential orphans |

## Transaction and race findings

### Process shutdown is not a hard precondition

`quit_codex` waits ten seconds, logs a warning if Codex is still running, and then continues. Continuing can overwrite `~/.codex/auth.json` while Codex still owns and may rewrite it. A switch must abort if the process cannot be stopped safely.

### Destination writes are not atomic

Live and profile auth are copied directly with `cp -p`. A reader can observe a truncated or partially copied destination. Marker files are also written directly. The implementation needs same-directory temporary files, mode 0600, fsync where practical, and atomic rename.

### The switch has no rollback boundary

Auth can be replaced before Desktop-state sync fails; markers can disagree with the live file; app launch can fail after committed changes. The operation needs preflight, a journal/backup, ordered commit, and rollback.

### Identity checks live only in the GUI layer

The Swift app validates identity for common buttons, but documented direct shell commands can call `capture`, `save-auth`, `switch`, `import-auth`, or recovery without those checks. Security and integrity invariants must live in the transaction layer, not just button handlers.

### The previous auto-save had the right goal and the wrong authority

The upstream app auto-saved live auth into the profile named by the active marker every eight seconds. That preserved rotations but caused account/label bleed when the marker was stale. The recent identity fix removed this marker-only auto-save, exposing the opposite failure: rotated live auth is no longer persisted.

The replacement is not marker-only auto-save. It is an identity-gated outgoing save after Codex has quit and flushed its latest auth.

## Storage audit

Good findings:

- Switcher root, profile directories, auth directories, and recovery directories are mode 0700.
- Saved auth, identity anchors, and recovery auth files are mode 0600.
- Debug output inspected during this pass did not contain raw token values.
- Identity anchors use JWT `sub` first and normalized email only as fallback; shared Team account IDs are not treated as person identity.

Risk findings:

- Seven profiles currently have seven profile auth files and seven referenced managed-home auth files.
- One recovery auth file is retained for upduck1.
- Three additional managed-home directories are unreferenced, apparently from deleted/abandoned profiles or login attempts.
- The profile delete command removes only the profile folder, not its managed home.
- Retained managed-home credentials are actively considered by quota polling and can be promoted by recovery.
- `auth.json` is plaintext secret material. OpenAI explicitly says to handle it like a password.
- The app assumes file-backed credentials and has no safe behavior if Codex is configured to use Keychain storage.

No orphan or retained credential was deleted during this audit.

## Required implementation architecture

### A. Codex owns refresh

- Delete `refreshCodexTokens`, `writeCodexAuth`, and every direct OAuth refresh call.
- Never call the OAuth token endpoint from the manager.
- Quota reads may use a locally unexpired access token read-only, but a 401 or expiry must produce an unavailable/stale status, not a refresh attempt.
- Prefer local Codex rate-limit snapshots for inactive profiles.
- Poll only the active profile on a slower interval, with a single-flight guard, cancellation, and backoff. Manual refresh remains available.

### B. One serialized switch transaction

1. Acquire the switch lock.
2. Preflight target profile, identity anchor, file-backed credential mode, free space, and optional state source.
3. Ask Codex to quit and fail safely if it remains running.
4. Re-read the outgoing live auth after shutdown.
5. Resolve its JWT identity independently of the active marker.
6. If it matches exactly one saved profile (normally the recorded active profile), atomically persist it to that profile.
7. If identity is missing, ambiguous, or mismatched, stop before overwriting any profile and surface a recovery choice.
8. Atomically install the target auth in the live path.
9. Restore optional state only after all state preflight succeeds.
10. Atomically update active/state markers.
11. Verify live identity matches the target.
12. Relaunch Codex.
13. If a post-mutation step fails, restore the journaled live auth and markers before returning an error.

The transaction service must be used by the main window, menu-bar switcher, and any supported CLI entry point.

### C. Replace stale recovery with profile re-authentication

- Remove every `Restore Original Auth` button and the `restore-reference-auth` command from supported workflows.
- Add `Re-authenticate Profile`.
- Create a new isolated `CODEX_HOME` and force file-backed login storage for that process.
- Run official `codex login` browser/device flow.
- Decode the new bundle and verify JWT subject/email against the profile's immutable `identity.json`.
- Reject and discard a wrong-account login without touching saved or live auth.
- Atomically promote the fresh bundle into the saved profile.
- If that profile is currently active, use the same quit/commit/relaunch transaction to update live auth.
- Remove the temporary auth copy after successful promotion so there is only one saved inactive copy plus the live copy while active.
- Retain identity evidence, not an activatable refresh-token seed.

### D. Honest lifecycle state

Replace `Ready` with explicit, evidence-based states:

- `Active and synced`
- `Live auth changed; will save on switch`
- `Saved token locally usable`
- `Access rejected; refresh unverified`
- `Needs re-authentication`
- `Identity mismatch`
- `Missing auth`

Never claim that a refresh token is valid solely from local JSON/JWT inspection.

### E. Non-secret lifecycle journal

Record only:

- timestamp and operation ID;
- source and destination role (live/profile/temp), not token text;
- profile ID and redacted identity fingerprint;
- whole-file SHA-256 prefix before/after;
- `last_refresh` timestamp;
- outcome and rollback status.

Do not record JWTs, full email addresses, access/refresh tokens, or exported auth content. Rotate and cap logs.

## Test matrix required before redeploy

1. Codex rotates live auth, then switch away and back: newest outgoing bundle survives.
2. Live identity differs from active marker: no profile is overwritten.
3. Two users share one Team account ID: subject anchors keep profiles distinct.
4. Same user receives a new token bundle: identity match succeeds and nickname remains attached.
5. Codex refuses to quit: switch aborts without changing live auth or markers.
6. Crash/failure after target preflight, outgoing save, live install, state restore, and marker commit: rollback is deterministic at every boundary.
7. Wrong account chosen during re-auth: fresh bundle is rejected and both saved/live auth stay byte-identical.
8. Correct re-auth for active and inactive profiles: exact intended destination changes, no other profile changes.
9. Old managed seed and recovery backup can never be activated through UI or CLI.
10. Repeated rapid menu-bar and window switches serialize through one lock.
11. Polling never posts to the OAuth endpoint, never writes auth, never overlaps, and backs off on 401/timeouts.
12. File-backed credential mode absent/keyring-only: app explains the incompatibility and refuses unsafe switching.
13. Profile deletion identifies its managed-home orphan and asks separately before removal.
14. No test or log emits secret material.

## Priority order

1. P0: remove direct OAuth refresh and stop the eight-second all-profile 401 loop.
2. P0: remove stale-seed recovery from all surfaces.
3. P0: implement identity-gated outgoing persistence and atomic switch transaction.
4. P1: implement isolated `Re-authenticate Profile` and migrate upduck1 through a fresh browser login.
5. P1: add honest auth state and lifecycle journal.
6. P1: quarantine retained managed-home seeds from executable paths; inventory orphans without deleting them automatically.
7. P2: simplify quota collection and add backoff/caching tests.
