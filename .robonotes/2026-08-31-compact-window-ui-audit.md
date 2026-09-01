# Compact-window and UI ergonomics audit — 2026-08-31

## Measured target

Mac display facts at audit time:

- Built-in Retina panel: 2560×1600 physical pixels.
- macOS logical screen: 1680×1050 points at 2× scale.
- Usable visible frame: 1680×997 points.
- Exact four-way tile allocation: approximately **840×498.5 points** per window.

Current manager window:

- Actual running frame: 1120×641 points.
- SwiftUI root minimum: 1120×640 at `CodexAccountSwitcher.swift:3445`.
- AppKit `NSWindow.minSize`: 1120×640 at `CodexAccountSwitcher.swift:4607`.
- Initial requested width is 1080, smaller than its own minimum, so AppKit immediately clamps it.

The current hard minimum is 280 points wider and about 142 points taller than a four-way tile. This is the direct reason four-way tiling cannot work.

## Where the space goes

Active dashboard constraints:

- Fixed sidebar: 270 points.
- Main-pane horizontal padding: 44 points.
- Top padding duplicated in both panes: 54 points.
- Header has 44 points of vertical padding plus title and wrapping helper text.
- Permanent bottom status panel consumes another row even when the app merely says `Ready`.
- Grid cards require at least 360 points each and at least 270 points of height.
- Each card reserves a full-width disabled `No Saved State` control even though all seven profiles have no captured state.

At 840 points wide, removing the sidebar leaves roughly 796 points after main padding—enough for two approximately 389-point cards. Keeping the sidebar leaves only about 526 points for the main pane and forces a single oversized card column.

## Sidebar audit

The sidebar contains no navigation hierarchy. It contains only:

- a duplicated Codex logo/title;
- active-profile text;
- current-state text;
- theme toggle;
- privacy toggle; and
- open-profiles-folder action.

That is status and utility content, not sidebar navigation. It permanently consumes about 24% of the minimum window width.

Apple's current guidance supports removing it:

- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) says sidebars represent an app's information hierarchy, consume substantial space, and should collapse when a Mac window narrows.
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) says toolbars orient people and hold frequent actions, with system-managed overflow at narrower widths.
- [ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits) is specifically intended to select the first layout that fits the proposed size.
- [`NSWindow.minSize`](https://developer.apple.com/documentation/AppKit/NSWindow/minSize) is enforced during user resizing, so both the AppKit and SwiftUI minimums must be lowered together.

## Redundancy and “AI-designed” symptoms

- `Codex` is shown in the sidebar and again in a large custom header.
- A permanent green `Ready` chip conveys no actionable state and can contradict 401s or broken refresh credentials.
- A long instruction paragraph is permanently embedded in the header.
- A permanent bottom message panel commonly repeats `Ready`.
- Every section is wrapped in custom tinted glass, strokes, and shadows instead of using a clear native hierarchy.
- Profile cards allocate three large action rows plus refresh/delete chrome.
- Disabled actions such as `No Saved State` look like important controls.
- The live auth appears as a `Current Codex` pseudo-profile even when it is identical to the active saved profile.
- Status badges, card outlines, button colors, plan pills, and quota colors compete for attention.

Source metrics reinforce this:

- Main Swift file: 4,697 lines.
- `liquidGlass` calls: 22.
- Fixed-width frame calls: 43.
- `Ready` string occurrences: 6.
- A complete older `ManagerView` and its component tree remain dead from lines 2039–3433: approximately 1,395 lines, or 30% of the main Swift file.
- Only `ManagerDashboardView` is instantiated by the app delegate.

## Proposed information architecture

Use one responsive content pane and the native Mac titlebar/toolbar.

Wide/quarter-tile shape:

```text
┌ Active: upduck2  State: None ─────────────── + Account  Refresh  ••• ┐
│ Accounts                                                         │
│ ┌ upduck1 ─ quotas ─────────┐  ┌ upduck2 (Active) ─ quotas ─────┐ │
│ │ Make Active       •••      │  │ Re-authenticate          •••   │ │
│ └────────────────────────────┘  └────────────────────────────────┘ │
│ [Only show a compact action/error banner when one exists]         │
└────────────────────────────────────────────────────────────────────┘
```

Toolbar mapping:

- `Active: <nickname>`: leading status/control; selecting it can reveal the active account.
- `State: <nickname/None>`: adjacent secondary status; hidden when the feature has no saved states, or collapses into a status menu at narrow widths.
- Add Account and Refresh: normal toolbar actions.
- Privacy: toolbar toggle if room permits.
- Theme and Open Profiles Folder: app menu/Settings or system toolbar overflow.
- Every toolbar command also appears in the macOS menu bar, consistent with platform expectations.

Content mapping:

- Remove the sidebar and duplicated logo/title.
- Remove permanent `Ready` UI and the instructional paragraph.
- Show instructions contextually in re-auth/switch dialogs.
- Show a transient inline banner only for work, success, warning, or error.
- Do not render a full `Current Codex` card when live identity matches the active profile; show it only as a discrepancy/recovery row.
- Make `Make Active` the one visible primary profile action.
- Rename `Update Auth Token` to `Re-authenticate` once the safe isolated login flow exists.
- Put destructive and uncommon actions in the card context menu.
- Show `No saved state` as a small metadata label, not a disabled full-width button. Hide the state action entirely when unavailable.
- Use standard Mac materials, separators, buttons, lists, and toolbar placements. Reserve accent color for selection and the primary action.

## Responsive layout plan

### Wide: 1000 points and above

- Two or three quota cards depending on measured available width.
- Full text toolbar items where useful.

### Four-way tile: 720–999 points

- Two compact columns at 840×498.
- Compact card height around 190–220 points.
- Quota lines remain visible; secondary metadata and menu actions collapse.
- Vertical scrolling is allowed; horizontal scrolling is not.

### Narrow: 520–719 points

- One-column compact account rows/cards.
- `ViewThatFits` selects abbreviated toolbar status and icon actions.
- Context menus hold secondary actions.

### Proposed hard minimum

- AppKit window minimum: **520×420**.
- SwiftUI root minimum: **520×420** or no larger content-imposed minimum.
- This is not the primary visual target; it is a usable lower bound. The explicit acceptance target is the Mac's 840×498 four-way tile.

## UI implementation slices

1. Delete the dead `ManagerView` tree and components used only by it.
2. Replace the root sidebar `HStack` with one responsive pane.
3. Introduce a native toolbar and menu commands for active/state status and utilities.
4. Extract a compact `AccountRow/Card` with one primary action and a context menu.
5. Add explicit width breakpoints through `ViewThatFits` or a small tested layout model.
6. Remove permanent header/status chrome and nested custom glass layers.
7. Lower both minimum-size constraints together.
8. Add accessibility labels, keyboard focus order, menu equivalents, and reduced-motion/contrast checks.

## Acceptance criteria

1. Window tiles into one quadrant at 840×498 without AppKit resizing it larger.
2. At 840×498, two profiles can appear side by side, primary actions remain understandable, and no horizontal scrollbar appears.
3. At 520×420, every profile and critical command remains reachable by vertical scrolling and menus.
4. Active profile and current state are visible or one click away in the toolbar at every supported width.
5. No permanent sidebar, generic `Ready` chip, helper paragraph, or bottom idle-status bar remains.
6. `No Saved State` is not rendered as a large disabled button.
7. Theme, privacy, folder, add, refresh, switch, re-auth, and delete remain discoverable with tooltips/menu labels.
8. VoiceOver announces profile nickname, redacted identity, active state, quota, and primary action in a sensible order.
9. Keyboard-only users can select a profile, activate it, re-authenticate, and open secondary actions.
10. Existing menu-bar switching continues to use the same safe transaction service as the window UI.
