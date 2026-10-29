# Releasing NoteAnywhere

A release is two files, built by `scripts/release.sh` into `dist/` (ignored by git):

- `NoteAnywhere-X.Y.Z.dmg`: the universal app (Apple silicon + Intel), signed with
  **Developer ID Application: Vishwas Prakash (GH5YVSN865)**, hardened runtime, notarized and stapled; the DMG itself is
  signed, notarized and stapled too.
- `NoteAnywhere-extension-X.Y.Z.zip`: the browser extension for the Chrome Web Store (no `"key"` in its manifest).

The version comes from a `vX.Y.Z` tag on the current commit, else from the `VERSION` file. The app, the DMG and the
extension all get the same number. Internal identifiers (`com.memorynotes.app`, `com.memorynotes.host`,
`memorynotes://`, the `MemoryNotes` data folder) never change, so updates keep notes, permissions and sync.

## First launch, in order

1. [One-time notarization setup](#one-time-notarization-setup).
2. [Chrome Web Store](#chrome-web-store): create the item and upload the zip as a draft, to learn the extension's id.
3. Put that id in `BrowserBridge.storeExtensionID` (step 7 of the Web Store section), commit.
4. [Cut the release](#cutting-a-release) of the app, which now trusts the store extension.
5. Submit the extension for review.
6. [Turn on GitHub Pages](#github-pages). Once the store listing is live, point the site's "Add to Chrome" button and the
   README at it.

## One-time notarization setup

The Developer ID certificate is already in the login keychain. Two certificates share its name, so `release.sh` picks
one by SHA-1 (`598A3CFA4889E9D4A2E865815A4328A30EEC1744`); override with `NOTEANYWHERE_SIGN_ID`. The script refuses a
signature from any team other than GH5YVSN865 (`NOTEANYWHERE_TEAM_ID`).

1. Make an app-specific password: [appleid.apple.com](https://appleid.apple.com) (signed in as timeupvishwa@gmail.com)
   → Sign-In and Security → App-Specific Passwords → add one named `notarytool`.
2. Save it in the keychain as the `NoteAnywhere` profile, pasting the password when asked:
   ```sh
   xcrun notarytool store-credentials NoteAnywhere --apple-id timeupvishwa@gmail.com --team-id GH5YVSN865
   ```
3. Check: `xcrun notarytool history --keychain-profile NoteAnywhere` lists submissions (none yet) without an error.

The password prompt needs a real terminal: run step 2 in Terminal, not through an agent's shell, where it reads an
empty password and Apple answers 401. Or skip the password and use an App Store Connect API key (what 0.1.0 used):
[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Users and Access → Integrations → generate a key with the
Developer role and download the `.p8` (once only). Keep it out of the repo, e.g. in `~/.appstoreconnect/private_keys/`:
```sh
xcrun notarytool store-credentials NoteAnywhere --key ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8 \
  --key-id <KEY ID> --issuer <ISSUER ID>   # leave out --issuer for an Individual key
```

Another profile name works with `NOTARY_PROFILE=<name> scripts/release.sh`.

## Cutting a release

Bump `VERSION` (X.Y.Z) and commit. Then use **one** of the two ways below.

### On your Mac

```sh
scripts/release.sh --skip-notarize   # optional dry run: builds and signs, spctl says "Unnotarized Developer ID"
scripts/release.sh                   # builds, notarizes the app, then the DMG (a few minutes each), staples both
```

Check the result; both must say `accepted` and `source=Notarized Developer ID`:

```sh
spctl -a -vv -t exec dist/NoteAnywhere.app
spctl -a -vv -t open --context context:primary-signature dist/NoteAnywhere-X.Y.Z.dmg
xcrun stapler validate dist/NoteAnywhere-X.Y.Z.dmg
```

If Apple rejects a submission, `release.sh` stops at the staple step; `xcrun notarytool log <submission id>
--keychain-profile NoteAnywhere` says why.

Publish. Push `main` first: this creates the tag on GitHub at `main`, which must be the commit you built.

```sh
gh release create vX.Y.Z dist/NoteAnywhere-X.Y.Z.dmg dist/NoteAnywhere-extension-X.Y.Z.zip \
  --target main --title "NoteAnywhere X.Y.Z" --generate-notes
```

The new tag can start the Release workflow; without its secrets it fails at the certificate step, which is harmless.
Disable the workflow (Actions → Release → ⋯ → Disable) if you only release from the Mac.

### From GitHub Actions

Once the secrets below exist, pushing a tag does everything, including the GitHub Release:

```sh
git tag vX.Y.Z && git push origin main vX.Y.Z
```

`.github/workflows/release.yml` runs `scripts/release.sh` on a macOS 26 runner and attaches the DMG and the zip.

Secrets (repository Settings → Secrets and variables → Actions, or `gh secret set NAME < file`):

| Secret | What it is | How to get it |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID certificate with its private key | Keychain Access → login → My Certificates → the "Developer ID Application: Vishwas Prakash (GH5YVSN865)" whose SHA-1 (Get Info → Fingerprints) is `598A3CFA…1744` → Export… as .p12 with a password. Then `base64 -i DeveloperID.p12 \| gh secret set MACOS_CERTIFICATE_P12` and delete the .p12. |
| `MACOS_CERTIFICATE_PASSWORD` | that export password | `gh secret set MACOS_CERTIFICATE_PASSWORD` |
| `NOTARY_API_KEY` | base64 of an App Store Connect API key | [App Store Connect](https://appstoreconnect.apple.com) → Users and Access → Integrations → App Store Connect API → Team Keys → generate one with **Developer** access, download `AuthKey_XXXXXXXXXX.p8` (only possible once). `base64 -i AuthKey_XXXXXXXXXX.p8 \| gh secret set NOTARY_API_KEY` |
| `NOTARY_API_KEY_ID` | the key's Key ID | same page, next to the key |
| `NOTARY_API_ISSUER_ID` | the Issuer ID | same page, above the keys list |

The workflow imports the certificate into a throwaway keychain, signs with the Developer ID it finds there, and
deletes the keychain at the end.

### After any release

- Try the DMG as a user would: download it from the GitHub Release (so it's quarantined), drag the app to
  Applications, open it. No Gatekeeper warning should appear. Opening the app writes the browser bridge for every
  installed Chromium browser.
- Your own copy: the DMG app is signed with Developer ID, `install.sh` builds with Apple Development. Switching
  between them changes the signature, so macOS asks once more for Accessibility (and the Keychain may ask once to
  let the app read its sync session).

## Chrome Web Store

1. **Developer account:** open the [Chrome Web Store developer dashboard](https://chrome.google.com/webstore/devconsole)
   with timeupvishwa@gmail.com, accept the agreement and pay the one-time **US$5** registration fee. Verify the contact
   email, and declare yourself a non-trader in the account settings (unless you sell something).
2. **Build the zip:** `scripts/release.sh --skip-notarize` is enough for it: `dist/NoteAnywhere-extension-X.Y.Z.zip`.
3. **New item** → upload the zip. It stays a draft until you submit it.
4. **Store listing:** description (the README's first paragraph works), category Productivity / Workflow & Planning,
   language English, at least one 1280×800 screenshot (an overlay on a web page), the 440×280 small promo tile.
   The icon comes from the zip. Homepage: `https://vishwas3000.github.io/NoteAnywhere/`; support:
   `https://github.com/Vishwas3000/NoteAnywhere/issues`.
5. **Privacy practices:**
   - *Single purpose:* "Shows and edits the user's own notes for the website they're on. The notes are stored by the
     NoteAnywhere Mac app on the same computer."
   - *nativeMessaging:* "Talks to the NoteAnywhere Mac app on the same computer, which stores the notes. It's the only
     place notes are read from or saved to."
   - *activeTab:* "When the user clicks the toolbar button (or presses ⌥⇧N) on a tab that was open before the extension
     was installed, the notes panel is added to that tab."
   - *scripting:* "Inserts the notes panel's script into that one tab, only after the click or shortcut above."
   - *storage:* "Remembers whether the user prefers the notes panel expanded or compact, on this device only."
   - *Host permissions (the content script on all sites):* "Notes are attached to sites and pages. To show a page's
     notes automatically, the extension checks each page the user opens against their notes. The page address and
     title go only to the Mac app on the same computer, never to a server."
   - *Remote code:* "No, I am not using remote code." Every script is in the package.
   - *Data usage:* tick **Web history** (page addresses and titles are read to find matching notes) and nothing else;
     tick the three certifications (not sold, not used for unrelated purposes, not used for credit decisions).
   - *Privacy policy URL:* `https://vishwas3000.github.io/NoteAnywhere/#privacy` (the site's privacy section).
6. Because the content script runs on all sites, review can take longer than usual (days, sometimes weeks).
7. **The store id:** the dashboard shows the item's id as soon as the draft exists (also in its store URL). Put it in
   `Sources/MemoryNotes/BrowserBridge.swift`:
   ```swift
   static let storeExtensionID = "<the 32-letter id from the dashboard>"
   ```
   then cut a new app release. Only apps that know the id let the store extension in; until users have that version,
   the store extension shows "Install NoteAnywhere for Mac and open it once". After the release, also fill in the
   "Add to Chrome" link in `site/index.html` (marked `FILL IN`) and the README.
8. **Updates:** bump `VERSION`, build, then dashboard → the item → Package → Upload new package.

If you also have the unpacked development extension loaded, turn it off: both would show a panel on every page.

## GitHub Pages

1. Repository Settings → Pages → Build and deployment → Source: **GitHub Actions**.
2. Push a change under `site/` to `main`, or run Actions → Pages → Run workflow.
3. The page is at `https://vishwas3000.github.io/NoteAnywhere/`. Add it as the repository's website (the ⚙ next to
   About on the repository page).
