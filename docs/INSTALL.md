# Installing NotchPill (unsigned release)

NotchPill is not notarized yet, so macOS Gatekeeper blocks the first open. **Do not click “Move to Trash.”**

## Quick install (recommended)

1. Download `NotchPill-*-macOS-arm64.zip` from [Releases](https://github.com/shawngeorgie06/NotchPill/releases) and double-click to unzip.
2. **Right-click** `NotchPill.app` → **Open**.
3. In the dialog, click **Open** again (not Move to Trash).
4. Drag **NotchPill.app** into **Applications** (Finder sidebar → Applications, or `Cmd+Shift+A`).
5. Eject Downloads copy if you like; open **Applications → NotchPill** from now on.

## Terminal install

```sh
cd ~/Downloads
unzip -o NotchPill-*-macOS-arm64.zip
xattr -cr NotchPill.app
open NotchPill.app
cp -R NotchPill.app /Applications/
open -a NotchPill
```

## After install

- **Menu bar** — look for the notch icon (top right). No Dock icon; that’s normal.
- **Launch at Login** — click the menu bar icon → enable **Launch at Login**.
- **Accessibility** — System Settings → Privacy & Security → Accessibility → enable **NotchPill** (for hover keyboard shortcuts).

## If it still won’t open

1. System Settings → **Privacy & Security** → scroll down → **Open Anyway** next to NotchPill (appears after the first block).
2. Or run again: `xattr -cr /Applications/NotchPill.app && open /Applications/NotchPill.app`

## Build from source (no download quarantine)

```sh
git clone https://github.com/shawngeorgie06/NotchPill.git
cd NotchPill
./Scripts/setup-vendor.sh
open NotchPill.xcodeproj   # Run (⌘R)
```

Apps you build locally are not quarantined like browser downloads.
