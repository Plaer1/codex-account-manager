# Clanked branding and eye-cloud icon

## Change requested

- Brand the app as `Codex Account Manager: Clanked Edition`.
- Combine the supplied orange eye artwork with the existing cloud-like icon.
- Publish the changed source as a GitHub fork of `ngnthanhdev/codex-account-manager`.
- Redeploy the local macOS app after verification.

## Implementation notes

- Kept the executable name, bundle identifier, profile storage paths, and auth file paths unchanged so the branding change does not migrate or overwrite account data.
- Updated visible macOS bundle metadata, window title, app-menu quit label, shell usage heading, README build paths, and contributor setup instructions.
- Generated `resources/AppIconClanked.png` as the editable source artwork, then packaged it into `resources/AppIcon.icns` and the 56px `resources/StatusIcon.png`.
- Disabled template rendering for the menu-bar image so the colored eye remains visible at runtime.

## Verification record

- Asset source: user-provided eye image plus the existing `resources/StatusIcon.png` reference.
- Build output: `build/Codex Account Manager Clanked Edition.app`.
- Auth/profile state was not read or modified as part of the branding/icon work.
- GitHub fork: `https://github.com/Plaer1/codex-account-manager`.
- Published commit: `96de4ad` (`Brand as Clanked Edition and add eye cloud icon`).
- Redeployed process verified at `build/Codex Account Manager Clanked Edition.app/Contents/MacOS/CodexAccountSwitcher`.

## Icon revision

- Added two opposing orange refresh arrows around the eye-cloud mark.
- The generator preview represented transparency with a checkerboard but saved the first result as RGB; this was detected before deployment.
- Converted the checkerboard exterior to actual alpha, verified `hasAlpha: yes`, and rebuilt both the `.icns` and 56px status icon from the RGBA source.
- Cleaned the remaining light fringe around the cloud and arrows, then verified the corrected RGBA candidate visually before the 1.0 packaging pass.

## Usage tint correction

- The profile-row tint now ignores context-window consumption and uses only the 5-hour and 7-day quota windows.
- This prevents a stale or oversized local context token count from turning a profile red when the actual quota fields show `No data`.

## Menu/main usage parity correction

- The menu-bar refresh path previously reloaded profile rows with `refreshUsage: false`, leaving its weekly values stale while the main manager refreshed usage.
- Menu-bar open/refresh now calls the same asynchronous per-profile usage refresh as the main app.

## Taskbar usage/source-of-truth cleanup

- Removed the taskbar's separate context-window meter and its context-number formatting helpers.
- Reused the main profile-card `QuotaLimitRow` for the taskbar's 5-hour and 7-day rows, so both surfaces render the same `UsageLimitWindow.usedPercent` values and reset data.
- Removed the taskbar-only `MenuBarUsageMeterRow` implementation, which had displayed the inverse “percent left” value and caused the taskbar to disagree with the main app.
- Removed hover-driven taskbar usage selection and `MenuBarState`; taskbar selection now uses the shared `AccountStore.selectedID`, the same selection used by the main manager.
