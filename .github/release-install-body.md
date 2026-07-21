## ⚠️ macOS will block this download — read first

Gatekeeper blocks **both** `NotchPill.app` and `Install NotchPill.command`. **Do not click Move to Trash.**

### Fastest install — paste in Terminal

```sh
xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
```

(Adjust the path if you unzipped elsewhere.)

### Or: right-click (not double-click)

1. Unzip the download
2. **Right-click** `Install NotchPill.command` → **Open** → **Open**
3. If the app itself is blocked later: **right-click** `NotchPill.app` → **Open** → **Open**

### After install

- **Menu bar icon** (top right) — no Dock icon
- Enable **Launch at Login** from the menu
- **System Settings → Privacy & Security → Accessibility** → enable NotchPill

[Full install guide](https://github.com/shawngeorgie06/NotchPill/blob/main/docs/INSTALL.md)
