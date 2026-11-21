# CraftPanel design tokens: web → SwiftUI

Source of truth: `Craft Panel/src/index.css` (the `--cp-*` variables), `src/theme.ts`, `src/components/ui.tsx`, `Icon.tsx` and `App.tsx`.
Swift implementation: `Core/CPTheme.swift` (CPColor, CPPalette, CPThemeID, CPFont, CPRadius, CPMotion, CPSpace, shadows) and `Views/CPKit.swift` (buttons, fields, banners, tab bar, setting rows).

## Color

Every `--cp-*` color is `CPColor.<name>` and reads from the active `CPPalette`. The root view re-identifies itself when the theme changes, so every screen redraws with the new palette.

| Web token | Swift | Dark | Light | Midnight | Sunset |
|---|---|---|---|---|---|
| `--cp-bg` | `CPColor.bg` | #0d0c0f | #f6f5f4 | #0a0e17 | #150a12 |
| `--cp-surface` | `surface` | #151418 | #ffffff | #10151f | #1e0f1a |
| `--cp-surface-2` | `surface2` | #1c1b21 | #f4f3f2 | #161c28 | #271521 |
| `--cp-surface-3` | `surface3` | #23222a | #ebe9e7 | #1c2330 | #301c29 |
| `--cp-surface-4` | `surface4` | #2c2b34 | #e0ddda | #242c3b | #3a2333 |
| `--cp-console` | `console` | #0a090c | #1a1920 | #070a10 | #100810 |
| `--cp-line-soft` / `line` / `line-strong` | `lineSoft` / `line` / `lineStrong` | #232228 / #2e2d36 / #3d3c47 | #eceae8 / #dedbd8 / #c6c2be | #1a212c / #252d3a / #34404f | #241522 / #33202e / #452c40 |
| `--cp-ink` … `ink-ghost` | `ink`, `inkDim`, `inkFaint`, `inkGhost` | #f2f0ef #b0adb6 #908d98 #6f6c79 | #1a1820 #55525c #6f6c77 #a8a5ad | #eef1f5 #a8b0bd #838da0 #5f6878 | #f5eef2 #c2adbd #a08d9b #7a6b75 |
| `--cp-accent` | `accent` | #ff8c00 | #d97400 | #3ea6ff | #ff4fa3 |
| `--cp-accent-hover` / `-press` / `-soft` / `-muted` | same names | #ffa033 / #e07a00 / #ffb066 / #2a1c0b | #c26800 / #a85a00 / #9c5400 / #fff2e0 | #5cb6ff / #2b8fe0 / #8fcaff / #0d2438 | #ff6fb5 / #e0398c / #ff8ec4 / #331020 |
| `--cp-accent-line` / `-ring` | `accentLine` / `accentRing` | accent @ 25% / 40% | ← | ← | ← |
| `--cp-on-accent` | `onAccent` | #180d00 | #ffffff | #001322 | #1a0010 |
| ok / warn / bad / info (+ soft, muted) | `ok`, `okSoft`, `okMuted`, … | #46c46e #e8a33d #f4655c #5aa2f0 | #1a8c45 #a86a08 #c9342b #1f6fc4 | Midnight and Sunset use Dark's status colors (as in the CSS) | ← |

`AccentColor.colorset` (#FF8C00) also covers system controls before the theme loads; `.tint(CPColor.accent)` covers them once it has.

## Typography

| Web | Swift |
|---|---|
| Display: Space Grotesk 400–700, `-0.018em` letter-spacing | `CPFont.display(size, weight:)`. The web app's own `space-grotesk-latin.woff2` is bundled (OFL) and loaded through CoreText as a variable font. |
| Body: system stack (`-apple-system`, SF Pro) | `.system(size:)` |
| Mono: `ui-monospace`, SF Mono | `CPFont.mono(size)` |
| Type scale: 11 / 12 / **13** (body) / 14 / 17 / 22 / 28 / 36 px | Same point sizes used directly: 11 hints, 12 controls, 13 body, 17 card titles, 22 screen titles. |

## Spacing, size, radius, shadow, motion

| Web | Swift |
|---|---|
| Tailwind 4 px scale | `CPSpace.s1…s10` (4…40) |
| `--cp-control-h` 32 px | `CPSpace.controlH`; button heights sm/md/lg = 26/30/38 (`CPButtonSize`) |
| Sidebar `w-[268px]` | `CPSpace.sidebarWidth` (the split view's ideal column is 240 pt; see deviations) |
| Radii xs–2xl = 4 / 6 / 9 / 12 / 16 / 22 | `CPRadius.xs…xl2` |
| Shadows `e1` / `e2` / `e3` | `cpShadowE1/E2/E3()` (two stacked drop shadows; the inset hairline is omitted) |
| `--cp-ease` cubic-bezier(.22, .61, .36, 1); 120 / 160 / 220 ms | `CPMotion.fast/base/slow` |
| `prefers-reduced-motion` | SwiftUI respects the system Reduce Motion setting for implicit animations |

## Components (`ui.tsx` → Swift)

Each Tauri component has a Swift counterpart:

| Web | Swift |
|---|---|
| Button (primary / secondary / ghost / subtle / quiet / danger; sm / md / lg) | `.cpButton(_:size:)`. `CPButtonStyle.appDefault` is applied at the window root, so plain `Button`s get the secondary style and `role: .destructive` renders as danger. |
| Card | `SettingsCard` |
| Field | `CPField` |
| SettingRow | `CPSettingRow` |
| Toggle | `CPToggle` |
| Slider | `CPSlider` |
| Segmented | `CPSegmentedPicker` |
| Tabs | `CPTabBar` (server tabs use the same style) |
| Banner | `CPBanner` |
| EmptyState / Skeleton | `CPEmptyState` / `CPStateBlock` |
| Badge / Pill | `Badge` |
| IconButton | `IconButton` |
| Modal | Native `.sheet` |

## States

These states all come from the same `CPButtonBody` / `CPStateBlock` code:

- **Hover:** a surface step up (`surface3`→`surface4`), accent→accentHover.
- **Pressed:** a 1 pt drop.
- **Disabled:** 40% opacity.
- **Focus:** the system focus ring, tinted with the accent.
- **Loading:** `CPStateBlock(.loading)` / `ProgressView`.
- **Empty:** `CPStateBlock(.empty)` / `CPEmptyState`.
- **Error:** `CPBanner(.bad)`.

## Icons

- The web app uses hand-inlined Lucide geometry (24×24, 2 px stroke). The Swift app uses **SF Symbols** with the closest equivalent (`terminal`, `person.2`, `slider.horizontal.3`, `archivebox`, and so on).
- Custom brand glyphs (the cube) are drawn in code (`Logo.swift`) or come from assets (`MenuBarIcon`).

## Intentional deviations (native conventions win)

1. **Window chrome:** macOS traffic lights with a hidden title bar. The same as Tauri on macOS; the Windows custom title bar does not apply.
2. **Menu bar:** the Tauri app has no menu bar. The Swift app adds File (New Server ⌘N, Add Folder ⇧⌘O), View (Overview ⌘0, Command Palette ⌘K) and a Server menu (Start ⌘R, Stop ⌘., Restart ⇧⌘R, Force Kill ⌥⌘., Show in Finder ⇧⌘F).
3. **Settings:** also available as the standard Settings window (⌘,). Every control saves immediately, so there is no "Save changes" button; only the theme saved instantly on the web.
4. **Tray:** the tray menu is a `MenuBarExtra` with a monochrome template glyph, so it follows the menu bar's light/dark appearance.
5. **Modals:** Tauri's modals are native sheets. Confirmations use `confirmationDialog`.
6. **Controls:** pickers, steppers and text fields are native AppKit-backed controls, restyled only through tint.
7. **Icons:** SF Symbols replace the Lucide set, as described above.
8. **Sidebar:** `NavigationSplitView` gives a user-resizable sidebar (ideal 240 pt, minimum 200) instead of a fixed 268 px.
9. **Scrollbars:** macOS overlay scrollbars instead of the web's hidden ones.
10. **Alerts:** performance alerts are macOS notifications rather than in-window toasts.
11. **Shadows:** the inset hairline highlight is omitted.

## Screen-by-screen visual checklist (run in Xcode on the Mac)

Compare each screen against the Tauri app, in Dark and at least one Premium theme:

- [ ] Sidebar: wordmark and running-count badge, New Server button and menu, Overview row, YOUR SERVERS list (status dots, selection), CraftPanel Settings footer
- [ ] Overview: 3 summary cards of equal height, server rows, Premium bulk bar (checkboxes, Start / Stop / Back up / Clear)
- [ ] Server header: name, type and version badges, status pill, Start/Stop capsule, ⋯ menu (Restart, Change Version, Duplicate, …), Java fix banner when Java is missing
- [ ] Server tabs: underline, whole-tab hit area, horizontal scroll at narrow widths
- [ ] Console: live and log-file toggle, line styling, command field with ↑/↓ history
- [ ] Network: join address and QR, reach ladder, UPnP card, tunnel, manual address, Geyser card
- [ ] Players: online list, ops / whitelist / bans, broadcast, player history, security
- [ ] Settings (server): launch, branding / MOTD preview, automation (snapshot section only with Premium), JVM, management API, plugin config, share, properties (Common / Advanced / raw in Expert mode)
- [ ] Add-ons: Modrinth / CurseForge browse, resource-pack Preview gallery, installed list
- [ ] Mods, Worlds, Files (NBT editor on level.dat), Backups (zip, smart retention, Time Machine gating)
- [ ] Create wizard: loader → version → details and "Your world"; modpack flow
- [ ] App settings: all 8 tabs; theme swatches (Premium lock on 3 of them); Remote access pairing QR
- [ ] Lock screen; Premium upsell sheet; menu-bar extra; Settings window (⌘,)
- [ ] Light theme: every screen legible (no dark-only hard-coded colors)
