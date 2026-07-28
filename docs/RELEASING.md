# Releasing

**CI builds the artifact everyone downloads.** Pushing a `v*` tag runs
`.github/workflows/release.yml`, which builds on a macOS runner, signs with the
`NotchPill Self-Signed` identity (imported from repo secrets), packages the ZIP,
and **replaces whatever assets are on the release**.

That last part is the thing to keep in mind: anything you attach by hand is
temporary. It survives only until the workflow finishes, about 90 seconds later.

## The steps

```bash
# 1. bump MARKETING_VERSION in NotchPill.xcodeproj/project.pbxproj, commit
# 2. push, then tag — the tag is what triggers the build
git push origin main
git tag v1.9.3 && git push origin v1.9.3

# 3. write the release notes (CI appends the install warning to whatever is here)
gh release create v1.9.3 --title "NotchPill v1.9.3" --notes "…"
```

That is the whole thing. CI builds, signs, uploads the ZIP and `SHA256SUMS.txt`,
and then bumps the Homebrew cask itself — verified end to end on v1.9.2.

`Scripts/bump-cask.sh <version>` remains as a fallback for when CI's cask step
fails. It is safe to run either way: it waits for the Release workflow to
finish before hashing, refuses to push if the workflow failed or if the asset
disagrees with the published `SHA256SUMS.txt`, and does nothing if the cask is
already correct.

## Check the cask actually matches

Worth doing after any release where CI was rerun or the assets were touched by
hand, because a cask pinning a hash that no longer exists breaks `brew install`
for everyone:

```bash
gh release download v1.9.3 -R shawngeorgie06/NotchPill --dir /tmp/rel --pattern '*.zip'
shasum -a 256 /tmp/rel/*.zip
curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/homebrew-tap/main/Casks/notchpill.rb | grep sha256
```

Note that **rerunning a release workflow produces a different ZIP** even from
identical source — the `Info.plist` records the build machine — so the asset
hash changes. CI updates the cask in the same run, so the two stay consistent;
a hand-attached asset would not.

## Do not attach a locally built ZIP

It is not what ships, and it actively causes harm: hashing it produces a cask
checksum for a file that stops existing the moment CI replaces the asset, and
then `brew install` fails for every user with a checksum mismatch. This happened
on v1.7.1. If you want to test a build locally, install it directly — don't
route it through a release.

## Verifying a release is genuinely what users get

```bash
gh release download v1.8.0 --dir /tmp/rel
shasum -a 256 /tmp/rel/NotchPill-1.8.0-macOS-arm64.zip   # match SHA256SUMS.txt
codesign -dv --verbose=2 /path/to/extracted/NotchPill.app  # Authority=NotchPill Self-Signed
```

A locally built app differs from the CI one in `Info.plist` (`DTSDKName`,
`BuildMachineOSBuild`) even when the source is identical, because the runner has
a different Xcode. That is the quickest way to tell which build you are holding.

## Secrets

| secret | used for | if missing |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12` / `APPLE_CERTIFICATE_PASSWORD` | signing with the stable identity | falls back to ad-hoc, which **breaks users' Accessibility grants on every update** |
| `NOTCHPILL_SIGN_IDENTITY` | selects that identity | as above |
| `TAP_PUSH_TOKEN` | lets CI update the Homebrew cask itself | the cask step **reports success and silently does nothing** — you must run `bump-cask.sh` by hand |

All three are set. `TAP_PUSH_TOKEN` is a fine-grained PAT scoped to
`shawngeorgie06/homebrew-tap` with **Contents: read/write** — it grants nothing
on this repo, only on the tap. If it expires the cask step goes quiet again
rather than failing loudly, so the symptom to watch for is `brew upgrade`
serving a stale version while the GitHub release looks fine.
