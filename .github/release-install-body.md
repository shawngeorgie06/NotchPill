## ⚠️ macOS will block this download — read first

Gatekeeper blocks **both** `NotchPill.app` and `Install NotchPill.command`. **Do not click Move to Trash.**

### Fastest install — paste in Terminal

```sh
curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/NotchPill/main/Scripts/install-notchpill.sh | bash
```

This downloads, clears quarantine, installs to Applications, and launches — no Finder dialogs.

### If you already unzipped the ZIP

```sh
xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
```

**Important:** run via `bash` in Terminal — double-clicking `Install NotchPill.command` is still blocked by Gatekeeper.

### Or: right-click (not double-click)

1. Unzip the download
2. **Right-click** `Install NotchPill.command` → **Open** → **Open**
3. If the app itself is blocked later: **right-click** `NotchPill.app` → **Open** → **Open**

### After install

- **Menu bar icon** (top right) — no Dock icon
- Enable **Launch at Login** from the menu
- **System Settings → Privacy & Security → Accessibility** → enable NotchPill

[Full install guide](https://github.com/shawngeorgie06/NotchPill/blob/main/docs/INSTALL.md)
