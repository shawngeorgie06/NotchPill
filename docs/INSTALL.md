# Installing NotchPill

NotchPill is self-signed, not notarized (no paid Apple Developer account), so a
plain browser download trips Gatekeeper with:

> Apple could not verify "…" is free of malware

Every option below avoids that by clearing the download quarantine flag.
**Do not click Move to Trash.**

---

## Option 0 — Homebrew (recommended)

```sh
brew install --cask shawngeorgie06/tap/notchpill
```

Installs to `/Applications`, clears quarantine, and never shows a dialog. Update
with `brew upgrade --cask notchpill`; remove with `brew uninstall --cask notchpill`.

---

## Option 1 — One command (no Homebrew)

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
