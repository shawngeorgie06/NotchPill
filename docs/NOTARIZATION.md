# Signing & Notarizing Releases

There are two ways to sign NotchPill. You only need one.

## Free path — stable self-signed identity (recommended, no Apple payment)

This does **not** make the app notarized — users still clear one Gatekeeper
prompt (Homebrew and the install script do it automatically). What it fixes is
**identity stability**: pure ad-hoc signing changes the code identity on every
build, and macOS ties Accessibility/Calendar permissions to that identity, so
each update silently drops the grants. Signing every release with one stable
self-signed certificate keeps permissions across updates.

**One-time setup:**

```sh
./Scripts/make-signing-cert.sh
```

It generates a non-expiring code-signing cert, trusts it in your login keychain,
and prints the three GitHub secrets to paste (so CI release builds use the same
identity):

| Secret | Value |
|--------|--------|
| `NOTCHPILL_SIGN_IDENTITY` | `NotchPill Self-Signed` |
| `APPLE_CERTIFICATE_P12` | base64 of the generated `.p12` (printed by the script) |
| `APPLE_CERTIFICATE_PASSWORD` | the random password the script prints |

Leave `NOTCHPILL_NOTARY_KEYCHAIN_PROFILE` / `APPLE_ID` unset — the build signs
with the cert and skips notarization. Local signed build:

```sh
NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-release.sh
```

To also keep the Homebrew cask current on each release, add a repo-scoped PAT for
`shawngeorgie06/homebrew-tap` as secret `TAP_PUSH_TOKEN` (or run
`./Scripts/bump-cask.sh <version>` by hand).

---

## Paid path — Developer ID + notarization (no Gatekeeper prompt at all)

Only this removes the "Apple could not verify…" prompt entirely, and it requires
the **$99/year Apple Developer Program**. The same three secrets above apply;
just use a real *Developer ID Application* certificate instead of the self-signed
one, and add the notary credentials below.

## One-time setup (maintainer)

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year).
2. In **Keychain Access → Certificate Assistant**, create a **Developer ID Application** certificate.
3. Store a notary API key or app-specific password:
   ```sh
   xcrun notarytool store-credentials "notchpill-notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```
   (App-specific password from [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords.)

## Local release build

```sh
export NOTCHPILL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTCHPILL_NOTARY_KEYCHAIN_PROFILE="notchpill-notary"
./Scripts/build-release.sh
open dist/
```

Upload `dist/NotchPill-*-macOS-arm64.zip` to GitHub Releases.

## GitHub Actions secrets

Add these repository secrets so tagged releases are notarized automatically:

| Secret | Value |
|--------|--------|
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` export of your Developer ID cert |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `APPLE_TEAM_ID` | 10-character team ID |
| `NOTCHPILL_SIGN_IDENTITY` | Full cert name, e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTCHPILL_NOTARY_KEYCHAIN_PROFILE` | Profile name from `notarytool store-credentials` |

For CI notarization without a stored profile, you can instead set:

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Export the certificate:

```sh
security find-identity -v -p codesigning
# export from Keychain Access as .p12, then:
base64 -i DeveloperID.p12 | pbcopy
```

## Until the next notarized release

Users downloading **v1.1.0** (ad-hoc signed) can still install:

1. Unzip the download.
2. **Right-click** `NotchPill.app` → **Open** → **Open** again in the dialog.
3. Or remove the quarantine flag in Terminal:
   ```sh
   xattr -cr ~/Downloads/NotchPill.app
   open ~/Downloads/NotchPill.app
   ```
4. Drag to **Applications** after it opens once.

Do **not** click “Move to Trash” on the Gatekeeper dialog — that only deletes the app.
