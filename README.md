<p align="center">
  <img src="docs/icon.png" width="160" alt="KeyHue icon">
</p>

<h1 align="center">KeyHue</h1>

<p align="center">
  <b>Know which language you're about to type in, before you type.</b><br>
  A tiny macOS menu bar app that paints the edge of your screen with the color of the current input source.
</p>

<p align="center">
  <a href="https://sejoung.github.io/KeyHue/"><b>Download</b></a> ·
  <a href="https://sejoung.github.io/KeyHue/manual.html">Manual</a> ·
  English · <a href="README.ko.md">한국어</a>
</p>

---

If you switch between keyboard input sources (Korean ↔ English, Japanese ↔ English, Russian ↔ English, German ↔ U.S., …), you have probably typed a whole sentence, or a terminal command, in the wrong one. The input source indicator in the macOS menu bar is small and easy to miss.

KeyHue shows the **actual input source selected in macOS** as a thin colored line at the edge of your screen, so you can see it out of the corner of your eye. If you pressed the switch key and the switch didn't happen, the color doesn't change either.

## Features

- **State bar**: a thin colored line on every display (bottom by default; top, left or right if you prefer). You can change its thickness (1–16 px) and opacity.
- **A color for each input source**: every input source enabled in System Settings gets its own color. Sensible defaults: Latin layouts blue, Korean green, Japanese orange, Chinese purple, Cyrillic teal, and so on.
- **Caps Lock**: shown in red, on top of the input source color.
- **Menu bar chameleon**: the menu bar icon changes color with the input source.
- **Switch back automatically** (optional): return to your default input source (ABC by default, configurable) when you
  - switch apps
  - move to another window or tab of the same app, like between two Terminal windows
  - press ESC (handy in Vim, VS Code, terminals)
  - leave a text field (experimental)
- **Remember input per app** (optional): restore the last input source when you come back to an app.
- **HUD** (optional): the chameleon pops up briefly in the new input source's color when you switch.
- **Localized**: English, 한국어 and 日本語. The app language can differ from the macOS language.
- **Lightweight**: native Swift/AppKit and fully event-driven, with no polling. Idle CPU is about 0%. No dependencies, no network.

## Privacy

**KeyHue never records what you type.**

| Feature | What KeyHue reads | Permission |
|---|---|---|
| State bar, Caps Lock, app switch | The currently selected input source, Caps Lock state, which app is active | None |
| Switch on ESC | Only whether the pressed key is ESC (a listen-only event tap; no characters are read) | Input Monitoring |
| Switch when leaving a text field (experimental) | Only the *role* of the focused UI element (e.g. "text field"), never its contents | Accessibility |

Permissions are requested only when you turn on the feature that needs them. KeyHue has no network code and no analytics. The source code is here for you to verify.

## Requirements

- macOS 13 Ventura or later (Apple silicon and Intel)

## Install

### Download

1. Download the latest version from the [KeyHue website](https://sejoung.github.io/KeyHue/) (or [Releases](https://github.com/sejoung/KeyHue/releases/latest)), unzip it, and move **KeyHue.app** to **Applications**. The [manual](https://sejoung.github.io/KeyHue/manual.html) covers every option.
2. The release builds are **not signed with an Apple Developer ID and not notarized** (KeyHue is a free, open-source side project), so macOS blocks the first launch:
   - **macOS 15 Sequoia or later**: open KeyHue once, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
   - **macOS 13–14**: Control-click KeyHue.app › **Open** › **Open**.
   - Or: `xattr -dr com.apple.quarantine /Applications/KeyHue.app`

   You can check the zip against the `.sha256` file attached to the release, or build it yourself from the source.

### Build from source

```bash
git clone https://github.com/sejoung/KeyHue.git
cd KeyHue
scripts/build-app.sh          # → build/KeyHue.app
open build/KeyHue.app
```

KeyHue shows a chameleon in the menu bar and an icon in the Dock. Click the Dock icon, or choose **Settings… (⌘,)** from the chameleon menu, to change colors, position and automation. Turn off **Show in Dock** if you want it only in the menu bar.

> Local builds are ad-hoc signed unless you create a development certificate. With ad-hoc signing, macOS forgets the Input Monitoring / Accessibility permission after every rebuild. Run `scripts/signing.sh create` once and later builds keep the permission.

## Known limitations

- KeyHue follows the input source that **macOS reports**. If an input method switches modes internally without changing the input source (for example Shift in some Chinese input methods), KeyHue cannot detect it.
- With many input sources, colors alone can become hard to tell apart. Pattern and thickness cues are on the roadmap.
- On MacBooks with a notch, a top bar is interrupted by the notch.

## Development

Requirements: Xcode 16+ (Swift 6 toolchain).

```bash
swift test                    # unit + integration tests (KeyHueCore, KeyHueApp)
scripts/build-app.sh          # build the .app bundle
scripts/install.sh            # build, install to /Applications, and relaunch
scripts/verify.sh             # build, all tests (Swift, scripts, lint, site), bundle — logs in TestResults/
```

```text
Sources/KeyHueCore   state model, colors, reset policy and timing, permissions, menu state, settings (pure logic)
Sources/KeyHueApp    AppKit/Carbon runtime: monitors, state bar, HUD, menu bar, settings window (SwiftUI)
Sources/KeyHue       executable entry point
Tests/               Swift unit/integration tests, script tests, site tests — see docs/TESTING.md
Resources/           Info.plist template, en/ko/ja translations
scripts/             build, verify, release and notarize scripts
site/                website and manual (GitHub Pages), screenshots from scripts/screenshots.sh
docs/SPEC.md         product specification (Korean)
docs/adr/            architecture decision records (Korean)
```

### Releasing (maintainers)

The version lives in [`VERSION`](VERSION). Tags look like `vX.Y.Z`. `release.sh` runs the real build and tests, and only commits, tags and pushes if they pass. Pushing the tag triggers the [Release workflow](.github/workflows/release.yml), which tests again, builds a universal app, and publishes it to GitHub Releases with notes taken from the tag message.

```bash
scripts/release.sh patch --dry-run    # checks + build + test only
scripts/release.sh patch|minor|major  # bump → verify → commit → tag → push → GitHub Actions publishes the release
scripts/package.sh                    # the same universal zip, built locally (build/dist/)
```

#### Signing key

Releases are signed with a self-signed certificate so that macOS keeps Input Monitoring and Accessibility permissions across updates. Without it every build gets a new signature and users must allow them again. The key never enters the repository:

```bash
scripts/signing.sh create     # once: key → ~/.config/keyhue/, installed in your keychain
scripts/signing.sh github     # add KEYHUE_SIGNING_P12 / KEYHUE_SIGNING_PASSWORD to the repo's Actions secrets
scripts/signing.sh install    # on another Mac, after copying ~/.config/keyhue/ securely
```

If the secrets are missing, the Release workflow falls back to ad-hoc signing with a warning. `scripts/notarize.sh` is ready for Developer ID signing and notarization if the project ever gets an Apple Developer account.

See [ADR 0017](docs/adr/0017-distribution-developer-id-notarization.md) for details.

## Contributing

Issues and pull requests are welcome, especially translations and default colors for more languages. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The source code is released under the [MIT License](LICENSE).

The **KeyHue name and the app icon** (`docs/icon.png` and assets generated from it) are not covered by the MIT License. If you distribute a modified version, please use a different name and icon.
