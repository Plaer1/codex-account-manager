# Auth lifecycle research — 2026-08-31

## Scope and safety

This was a read-only research and audit pass. No application behavior, profile data, live auth, saved auth, or deployed binary was changed. The app was not rebuilt or redeployed.

No complete email address, JWT, refresh token, access token, or identity subject is recorded here. Identity values below are redacted; hashes are short comparison fingerprints only.

The user confirmed that the affected upduck1 credential has only been used on this physical Mac. Another physical machine is therefore ruled out as the incident cause. Multiple stale copies and competing consumers on this same Mac remain in scope.

## Executive finding

The recurring failure is a stale-snapshot lifecycle bug, not a simple expired-access-token problem.

The switcher currently treats `auth.json` as a static file. Codex treats it as mutable session state: Codex can rotate tokens and write an updated bundle back to the live file. The switcher does not persist the outgoing live bundle before replacing it during a profile switch, and its recovery action can restore an older seed. That can discard the only current refresh token and later force a browser login.

There is also a separate release-blocking defect in the quota subsystem: the manager directly calls the OAuth refresh endpoint and can rewrite live, saved, or retained managed-home auth files. This is contrary to OpenAI's documented lifecycle and is exposed to overlapping eight-second polling passes. The available mtimes show that this direct refresher did not rewrite the currently restored upduck1 copy, so it is a confirmed architectural bug but not proven to be the exact event that invalidated this particular copy.

## Official Codex behavior

Primary sources:

- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Maintain Codex account auth in CI/CD](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
- [Codex environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)

Confirmed from those sources:

1. `CODEX_HOME` defaults to `~/.codex` and contains auth, configuration, logs, sessions, and other Codex state.
2. With file-backed credential storage, Codex stores credentials in `$CODEX_HOME/auth.json`.
3. Codex CLI and the IDE extension share the cached login.
4. Codex automatically refreshes ChatGPT sessions during use and writes new tokens and `last_refresh` back to `auth.json`.
5. The current client can refresh when `last_refresh` is roughly eight days old and can also refresh-and-retry after a `401`.
6. OpenAI's documented persistence rule is to run Codex and keep the updated `auth.json`; restoring the original seed throws away the refreshed token bundle.
7. OpenAI explicitly says not to call the OAuth refresh endpoint manually for this workflow.
8. A given auth file must have one serialized consumer stream. Concurrent jobs or machines must not share and rotate the same copy. On this installation, the analogous hazard is several local copies plus custom refresh code on the same Mac.
9. `codex login status` reports the active authentication method; it is not documented as a server-side refresh-token validity check.

## Local Codex observations

- Installed CLI: `codex-cli 0.151.0-alpha.7.2` from the installed OpenAI VS Code extension.
- `codex login` supports browser login, device auth, API key input, access-token input, and `status`.
- `codex logout` removes stored credentials.
- `codex login status` returned `Logged in using ChatGPT` and did not change the live auth file's SHA-256 hash.
- Running `codex login status` against an empty isolated `CODEX_HOME` returned `Not logged in` with exit status 1.
- The user's config has no explicit `cli_auth_credentials_store` override. A live file exists at `~/.codex/auth.json`, so this machine is currently using the file path the switcher expects.
- `~/Library/Application Support/Codex` is currently absent. Every saved profile is auth-only; no profile has a captured Codex Desktop-state directory.

## Redacted incident evidence

Current markers at audit time:

- Active profile: `upducksoftware` (nickname upduck2)
- Current-state marker: empty
- upduck1 storage profile: `whatsupduck13`

Relevant credential snapshots:

| Copy | Redacted user | File relationship | Last refresh | Access JWT expiry |
| --- | --- | --- | --- | --- |
| Live `~/.codex/auth.json` | `up***` | Byte-identical to upduck2 saved auth | 2026-08-25 21:50 UTC | 2026-09-04 21:49 UTC |
| upduck1 saved auth | `wh***` | Byte-identical to retained upduck1 managed-login seed | 2026-08-25 21:07 UTC | 2026-09-04 21:07 UTC |
| upduck1 retained seed | `wh***` | Byte-identical to upduck1 saved auth | 2026-08-25 21:07 UTC | 2026-09-04 21:07 UTC |
| upduck1 pre-repair backup | `br***` | Different JWT subject and token bundle | 2026-08-25 22:26 UTC | 2026-09-04 22:26 UTC |
| upduck2 saved auth | `up***` | Byte-identical to live auth | 2026-08-25 21:50 UTC | 2026-09-04 21:49 UTC |

Additional facts:

- upduck1 was initially captured at `2026-08-25T21:07:56Z`.
- Its last explicit `auth_saved_at` is `2026-08-25T22:26:41Z`, when the wrong user's auth was written into that profile.
- `Restore Original Auth` ran on 2026-08-31 and created `auth-before-identity-repair-20260831T002013Z-45210.json`.
- The restore copied the original 2026-08-25 managed-login seed back into upduck1 exactly.
- There is no later `auth_saved_at` showing that a fresh upduck1 login or rotated live bundle was promoted into the profile.
- All relevant access JWTs are locally unexpired until 2026-09-04. Local access-token expiry therefore does not explain the current failure.
- A refresh token can be revoked or superseded server-side while its accompanying access JWT still has a future `exp`; JWT inspection cannot prove refresh health.

## Confirmed local defects

### 1. Outgoing live auth is discarded on switch

`cmd_switch` quits Codex and then copies the target saved profile over `~/.codex/auth.json`. It never copies the just-flushed outgoing live file back into the outgoing profile.

If Codex refreshed or rotated the live bundle while that account was active, the profile remains stale. Switching away destroys the newest bundle; switching back restores the stale one.

This is the closest fit to the upduck1 recurrence and directly violates the official “persist the updated auth.json” rule.

### 2. “Restore Original Auth” resurrects a seed, not a known-good session

The retained managed-home file is useful as identity evidence, but its refresh token is not immutable. Restoring that file can replace a newer or recoverable profile snapshot with a refresh token that Codex has already rotated or the server has revoked.

For upduck1, the action restored the exact six-day-old initial seed. The action has no way to verify server-side refresh validity before promoting it.

### 3. The quota reader implements its own OAuth refresh client

`codexAccessTokenFresh` posts a refresh token to `https://auth.openai.com/oauth/token`, rewrites the selected auth file, and updates `last_refresh`. The candidate file can be:

- live `~/.codex/auth.json`;
- a saved profile auth file; or
- a retained managed-login auth file.

This bypasses Codex's built-in serialized refresh-and-writeback path and uses the same refresh credentials from several local copies.

### 4. Polling passes can overlap

The app starts a new all-profile refresh pass every eight seconds without a single-flight guard. Each pass performs serial network requests with a 20-second request timeout. A slow pass can remain alive while many later passes begin.

The log contained 27,804 `usage endpoint returned HTTP 401` entries and was still adding two more approximately every eight seconds during this audit. The log had grown to about 3.9 MB and 59,269 lines. This is both an auth-risk multiplier and needless traffic.

### 5. Health labels overstate certainty

`Ready` currently means that token fields exist and the access JWT is not locally expired. It does not mean the refresh token works or even that the usage endpoint accepts the access token. The live log's repeated 401s coexist with `Ready` cards.

## Incident conclusion: fact versus inference

What is proven:

- The switch path discards newer outgoing live auth.
- The recovery path restored an old local seed.
- The app contains an unsupported direct refresh path capable of rotating independent local copies.
- The app generates overlapping polling work and tens of thousands of 401s.
- The affected credential was not used on another physical machine.

Most likely incident chain (inference):

1. upduck1's live bundle was refreshed, rotated, or replaced during use on this Mac.
2. The newer live bundle was not persisted to the upduck1 profile before another profile was activated, or the subsequent recovery action replaced it.
3. `Restore Original Auth` reintroduced the initial saved refresh token.
4. Codex later attempted its normal refresh/401 recovery and the server rejected that stale token, forcing login.

What cannot be proven from retained artifacts:

- The exact timestamp or process that first invalidated upduck1's refresh token. The app has no token-lifecycle journal, `codex-login.log` is absent, and the superseded live file no longer exists.

The fix does not depend on guessing that missing event. It must make stale-copy restoration impossible and preserve Codex's latest writeback transactionally.
