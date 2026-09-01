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
