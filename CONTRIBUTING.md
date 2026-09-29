# Contributing to KeyHue

Thanks for your interest! Issues and pull requests are welcome in English or Korean.

## Before you start

- For anything larger than a small fix, please open an issue first so we can agree on the approach.
- KeyHue's core promises are **lightweight, event-driven (no polling), and privacy-first**. Changes must not read, store or send what the user types, and must not add network access or analytics.

## Development

```bash
swift test              # unit tests
scripts/build-app.sh    # build/KeyHue.app
scripts/install.sh      # build, install to /Applications and relaunch (use this to try your changes)
scripts/verify.sh       # build + test + bundle (run this before opening a PR)
```

- Run `scripts/signing.sh create` once (or `scripts/signing.sh install` with the maintainer's key files). It creates a local "KeyHue Development" signing certificate so Input Monitoring and Accessibility permissions survive rebuilds (ad-hoc builds lose them every time).
- Put logic that can be tested without macOS APIs in `Sources/KeyHueCore` and add tests in `Tests/KeyHueCoreTests`. Keep `Sources/KeyHue` (AppKit/Carbon glue) thin.
- Match the surrounding code style (4-space indent, see `.editorconfig`).

## Translations

UI strings use the English text as the key: `L("Show State Bar")`.

- Every key must exist in all of `Resources/en.lproj`, `ko.lproj` and `ja.lproj`. `swift test` fails if one is missing, unused, or has mismatched `%@` placeholders.
- To add a language:
  1. add `Resources/<code>.lproj/Localizable.strings`
  2. add it to `CFBundleLocalizations` in `Resources/Info.plist`
  3. add a case to `AppLanguage` in `Sources/KeyHueCore/KeyHueSettings.swift`
- Reviews from native speakers of the existing translations (especially Japanese) are very welcome.

## Website and manual

The website and manual live in `site/` and deploy to GitHub Pages on every push to `main`. If you change the settings window, regenerate its screenshots (English and Korean) with:

```bash
scripts/screenshots.sh   # renders the real SwiftUI views into site/assets/screens/
```

Keep `site/index.html` / `site/ko.html` and `site/manual.html` / `site/manual-ko.html` in sync.

## Default colors for more languages

Default colors per language live in `SourcePalette` (`Sources/KeyHueCore/InputState.swift`), and HUD glyphs live in `InputSourceGlyph`. Red is reserved for Caps Lock.

## Design decisions

Significant decisions are recorded as ADRs in `docs/adr/` (currently written in Korean). If your change alters a recorded decision, add a new ADR or mention it in the PR.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
