# Contributing to KeyHue

Thanks for your interest! Issues and pull requests are welcome in English or Korean.

## Before you start

- For anything larger than a small fix, please open an issue first so we can agree on the approach.
- KeyHue's core promises are **lightweight, event-driven (no polling), and privacy-first**. Never persist, log or transmit typed content, or add analytics. The opt-in mix-up warning processes words only in memory ([ADR 0041](docs/adr/0041-wrong-language-warning.md)). Network access is limited to release checks ([ADR 0044](docs/adr/0044-update-check-and-release-link.md)).
- The experimental input method is embedded in KeyHue.app and managed through its settings/menu. Follow [ADR 0051](docs/adr/0051-single-app-distribution-and-managed-input-method.md) for distribution, installation/removal and current-character composition, and the [design](docs/INPUT_METHOD_DESIGN.md) for process/session boundaries. Word fixing follows [ADR 0064](docs/adr/0064-correction-modes-off-manual-automatic.md)–[0068](docs/adr/0068-fix-words-with-a-shortcut.md): words stay in the input method's memory (only the opt-in undone-fix record is saved, on this Mac) and never travel in distributed notifications.

## Development

```bash
swift test              # unit tests
scripts/build-app.sh    # build/KeyHue.app
scripts/install.sh      # build, install to /Applications and relaunch (use this to try your changes)
scripts/verify.sh       # build + test + bundle (run this before opening a PR)
```

- Run `scripts/signing.sh create` once (or `scripts/signing.sh install` with the maintainer's key files). It creates a local "KeyHue Development" signing certificate so Input Monitoring and Accessibility permissions survive rebuilds (ad-hoc builds lose them every time).
- Put decisions (what to do, when) in `Sources/KeyHueCore` with unit tests in `Tests/KeyHueCoreTests`. Keep `Sources/KeyHueApp` (AppKit/Carbon glue) thin; inject OS access behind a protocol, like `InputSourceSwitching`, `Scheduling` and `PermissionGate`. When the menu and the settings window show the same thing, derive it once in a value type both use (`StatusMenuState`, `DefaultSourceMenu`, `InputMethodMenuState`) and test that instead of the views.
- For the input method, keep session, editing and correction policy in `KeyHueInputMethodSpikeCore` (`Tools/InputMethodSpike/Core`, tests in `Tests/KeyHueInputMethodSpikeCoreTests`) and IMK/client access in `Tools/InputMethodSpike/App`. Do not make it depend on the utility runtime (`KeyHueApp`); share code through `KeyHueCore` or `KeyHueSystemLexicon`.
- The current IMK service and session core live in `Tools/InputMethodSpike/`. `scripts/build-app.sh` embeds the service in KeyHue; `scripts/package.sh` ships one ZIP with shared version, architecture and signing identity. `scripts/install.sh` installs KeyHue; then use its input-method setup/removal actions. Component arguments and the standalone input-method installer have been removed; shared product metadata lives in `scripts/app-config.sh`. Input-method installation and registration belong to the app; users add and remove the two modes in System Settings, and the app never edits the input source list ([ADR 0055](docs/adr/0055-users-add-input-sources-manually.md)). Bundle checks and lifecycle tests must not modify the real user's input sources.
- Tests never wait on the real clock. Code with delays takes a `Scheduling` and tests drive it with `FakeScheduler`; a sleep-based test once broke a release on a slower CI runner.
- Code that needs real macOS APIs gets integration tests in `Tests/KeyHueAppTests`. Script changes need a case in `Tests/scripts/`. See [docs/TESTING.md](docs/TESTING.md) for every test type and the manual release checklist.
- Match the surrounding code style (4-space indent, see `.editorconfig`).
- `scripts/verify.sh` runs `scripts/swift-lint.sh` ([ADR 0080](docs/adr/0080-swift-lint-file-length-dead-code-and-cycles.md)): a source file over 400 lines, an unused declaration, a class closure that captures `self` strongly, or two types that depend on each other fails it. Install the tools with `brew install swiftlint periphery`; locally they are skipped when missing, CI requires them. Split a long file by responsibility, and break a type cycle with a protocol or closure.

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
