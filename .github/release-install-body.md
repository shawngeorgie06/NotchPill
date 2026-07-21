## ⚠️ First launch — macOS will block this app

NotchPill is **not notarized** yet. When you unzip the download, macOS may show:

> **"Apple could not verify NotchPill is free of malware"**

**Do not click Move to Trash.** Use one of these:

### Option A — Easiest
1. Unzip the download
2. **Double-click `Install NotchPill.command`** inside the folder
3. Done — look for the notch icon in your menu bar

### Option B — Right-click
1. **Right-click** `NotchPill.app` → **Open** → **Open**
2. Drag to **Applications**

### Option C — Terminal
```sh
cd ~/Downloads
unzip -o NotchPill-*-macOS-arm64.zip
xattr -cr NotchPill.app
open NotchPill.app
cp -R NotchPill.app /Applications/
```

### After install
- **Menu bar icon** (top right) — no Dock icon; that's normal
- Enable **Launch at Login** from the menu
- **System Settings → Privacy & Security → Accessibility** → enable NotchPill

[Full install guide](https://github.com/shawngeorgie06/NotchPill/blob/main/docs/INSTALL.md)
