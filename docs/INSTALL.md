# Installing NotchPill (unsigned release)

macOS Gatekeeper quarantines the **entire unzipped folder** — including `Install NotchPill.command`. You will see:

> Apple could not verify "…" is free of malware

**Do not click Move to Trash.**

## One-line install (recommended)

Paste in **Terminal** (updates path if needed):

```sh
xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
```

This removes the quarantine flag on everything in the folder, then runs the installer.

## Finder install

1. Download and unzip `NotchPill-*-macOS-arm64.zip`.
2. **Right-click** `Install NotchPill.command` → **Open** → **Open**  
   (Double-click shows the malware warning — right-click is required the first time.)
3. If prompted about `NotchPill.app` too: **right-click** it → **Open** → **Open**.

## Manual Terminal install

```sh
cd ~/Downloads/NotchPill-*-macOS-arm64
xattr -cr .
cp -R NotchPill.app /Applications/
xattr -cr /Applications/NotchPill.app
open /Applications/NotchPill.app
```

## After install

- **Menu bar** — notch icon (top right). No Dock icon; that's normal.
- **Launch at Login** — menu bar icon → enable it.
- **Accessibility** — System Settings → Privacy & Security → Accessibility → NotchPill.

## If it still won't open

System Settings → **Privacy & Security** → scroll down → **Open Anyway** next to NotchPill.

## Build from source (no download quarantine)

```sh
git clone https://github.com/shawngeorgie06/NotchPill.git
cd NotchPill
./Scripts/setup-vendor.sh
open NotchPill.xcodeproj   # Run (⌘R)
```
