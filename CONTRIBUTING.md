# Contributing to PromptPad

Thanks for helping. PromptPad is small on purpose: a menu bar app built with `swiftc`, no dependencies, no Xcode project.

## Build and check

```bash
./build.sh --public --no-install      # what everyone else gets (leaves out personal/)
python3 scripts/check-layout.py --public
```

Install your build with `./build.sh`. `./scripts/make-signing-cert.sh` once keeps macOS permissions across rebuilds.

## What goes where

- **A habit** (what a key does, a quick reply, a new app): change `Resources/layout.json` only if it is a better default
  for everyone; otherwise it belongs in your own layout file (see docs/customize.md).
- **Something for one device or one app** that most people won't use: make it an add-on in `addons/<name>/`.
- **Your own extras**: `personal/<name>/`. It is git-ignored; keep it out of pull requests.

## Rules that keep it safe

- Keypad codes never contain Option (Claude opens its quick entry on a double Option). `check-layout.py` enforces it.
- Nothing may type into, or send text in, an app that isn't in front. Chat-app actions check `frontIsAI`.
- In VS Code the keypad must not be able to change a file by accident: editing keys are `none` there, and VS Code
  combos are `pass` with a matching rule in `Resources/vscode-keybindings.json`.
- Input devices are read, never seized. Nothing runs at login. Uninstall must undo everything PromptPad changed.
- Slow work (Accessibility scans) stays off the keypad thread (`KeypadTap`).

## Code and text

- Code, comments and logs are in English. Interface text goes through `L("…")` in English; add the translation to
  `Resources/i18n/zh-Hans.json` (and any other language file). Layout texts are English too.
- Write UI text plainly: short sentences, say what happens. Formats use `%@`.
- Keep functions small and comments about *why*.

## Pull requests

Describe what changes for the person pressing the keys, and how you tried it (which app, which keys).
If the layout changes, run `python3 scripts/make-keys-doc.py` to update docs/keys*.md, and include a key map screenshot.
CI checks the layout and that docs/keys*.md are up to date, then makes a public macOS build, on every push and pull request.

## Languages

Copy `Resources/i18n/zh-Hans.json` to `Resources/i18n/<code>.json`, translate the values, set `"_language"`.
