# Installing NotchPill

macOS blocks unsigned downloads with:

> Apple could not verify "…" is free of malware

**Do not click Move to Trash.** Double-clicking the installer **does not work** — use Terminal.

---

## Option 1 — One command (easiest)

Open **Terminal** and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/NotchPill/main/Scripts/install-notchpill.sh | bash
```

Downloads the latest release, installs to Applications, and launches. No Finder dialogs.

---

## Option 2 — Already downloaded the ZIP?

1. Unzip `NotchPill-*-macOS-arm64.zip`
2. Open **Terminal** and paste:

```sh
xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
```

Change `~/Downloads/...` if you unzipped somewhere else.

**Do not double-click** `Install NotchPill.command` — macOS blocks it before it can run.

---

## Option 3 — Manual install

```sh
cd ~/Downloads/NotchPill-*-macOS-arm64
xattr -cr .
ditto NotchPill.app /Applications/NotchPill.app
xattr -cr /Applications/NotchPill.app
open /Applications/NotchPill.app
```

---

## After install

- **Menu bar** — look for the notch icon (top right). No Dock icon; that's normal.
- **Launch at Login** — click the menu bar icon → enable it.
- **Accessibility** — System Settings → Privacy & Security → Accessibility → enable **NotchPill** (for hover keyboard shortcuts).

## Still blocked?

System Settings → **Privacy & Security** → scroll down → **Open Anyway** next to NotchPill.

## Build from source (no quarantine)

```sh
git clone https://github.com/shawngeorgie06/NotchPill.git
cd NotchPill
./Scripts/setup-vendor.sh
open NotchPill.xcodeproj   # Run (⌘R)
```
