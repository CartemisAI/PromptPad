# Customizing PromptPad

PromptPad ships with one person's habits. Everything about them lives in data files, so you can make it yours
without touching the Swift code.

| What | Where | How to apply |
|---|---|---|
| What each key does, per app; which apps exist; what the map shows | your layout: `~/Library/Application Support/PromptPad/layout.json` | menu **Customize → Reload Layout** |
| Small settings (voice button names, scroll speed, …) | `~/Library/Application Support/PromptPad/config.json` | immediately |
| VS Code rules | your copy: `~/Library/Application Support/PromptPad/vscode-keybindings.json` | menu **Customize → Update VS Code Rules** |
| Key codes on the keypad itself | your layout (`keys.<id>.<layer>.code`) | menu **Customize → Write Layout to Keypad** (USB cable, wired mode) |

Menu **Customize → Edit My Layout…** creates your layout file and opens it.

[中文版](customize.zh-CN.md)

## Your layout file

Write only what you change. It is merged on top of the default layout (`Resources/layout.json`):
objects merge key by key, the `apps` list merges by `id`, anything else replaces.

```json
{
  "actions": {
    "shift+cmd+f19": { "claude": "say:Continue.", "chatgpt": "say:Continue." },
    "shift+cmd+f18": { "chrome": "keys:cmd+shift+t" }
  },
  "keys": {
    "slash": { "fn": { "show": { "claude": ["Continue", "text.bubble", "ai", "Pastes and sends “Continue.”"] } } }
  }
}
```

Run `python3 scripts/check-layout.py` after editing the default layout or an add-on: it catches key codes that
use Option, two keys sending the same combo, VS Code "pass" combos without a VS Code rule, and malformed entries.

## How a key press becomes an action

1. The keypad's firmware sends a **combo**: F13–F20 plus modifiers, e.g. `ctrl+shift+cmd+f15`.
   Holding **Fn** adds Shift, holding **M4** adds Command (they are layer keys), so every layer sends different combos.
   Combos never use Option: Claude opens its quick entry when Option is tapped twice.
2. PromptPad catches the combo (it never reaches other apps) and looks up `actions[combo]`:
   either one action for every app, or an object per app id with an optional `"default"`.
3. It runs the action in the front app. Combos are named in the order `ctrl+opt+shift+cmd+key`.

Keys that send ordinary keys (arrows, Page Up/Down, Esc, digits under M4) go straight to the app.

## Actions

| Action | Does |
|---|---|
| `keys:cmd+shift+e` | posts a shortcut; `keys:cmd+k,v` posts a sequence |
| `type:,` | types text directly, whatever input method is on |
| `say:text` / `paste:text` | puts text in the chat app's message box and sends it / just pastes it |
| `menu:View>Toggle Side Chat` | presses a menu item of the front app |
| `button:Voice Input` | presses a button whose name starts with this |
| `app:claude` / `cycle:chrome,vscode` | switches to an app / rotates through apps (app ids or bundle ids) |
| `hold:rightoption` | holds a modifier while the key is held (`rightoption`, `leftoption`, `rightcommand`, `rightshift`, `fn`) |
| `voice` | the voice key: tap to start / stop, hold to talk (see Apps) |
| `voice:/btw ` | chat apps: puts the text at the start of the message box, then starts voice (Claude’s `/btw` side question) |
| `send`, `forcesend`, `queue`, `focus`, `scroll:up`, `scroll:down` | chat apps only: Enter, "Send now", "Queue for later", back to the message box, scroll the conversation |
| `toggledictation` | switch the front app between its own voice input and macOS dictation |
| `cheatsheet`, `nextmic` | open / close the key map; show / switch microphones |
| `pass` | let the combo through to the app, which handles it itself (used for VS Code) |
| `none` | do nothing on purpose |

Holding a key repeats only movement and editing (`keys:` with arrows, delete, page keys, space, tab, return, undo;
`type:`; `scroll:`). Everything else happens once per press.

## Apps

```json
"apps": [
  { "id": "claude",  "name": "Claude",  "bundle": "com.anthropic.claudefordesktop", "ai": true, "voice": "shortcut", "voiceKeys": "cmd+d" },
  { "id": "cursor",  "name": "Cursor",  "bundle": "com.todesktop.230313mzl4w4u92", "voice": "system" }
]
```

- `id` is what actions and `show` use; `name` is shown on the map; `bundle` is the macOS bundle identifier
  (`osascript -e 'id of app "Cursor"'`).
- `ai: true` marks a chat app with a message box: `say:`, `focus`, `queue`, `forcesend`, `scroll:` only work in these.
- `voice`: `shortcut` (posts `voiceKeys`, falls back to the mic button), `button` (presses the voice button by name),
  `toggleButton` (presses a button starting with `voiceButton` and counts presses), `system` (macOS dictation), `off`.
- `realClick: true` for apps that ignore Accessibility presses (a real mouse click is sent instead).

To add an app: add it to `apps`, then give it entries in `actions` under its id, and `show` entries for the map.

## What the map shows

Each key and layer has `show`: `{ "*": [...], "<app id>": [...] }`, where an entry is
`[title, SF Symbol name, category, detail]` or `null` for "nothing here". Categories color the key:
`nav`, `edit`, `ai`, `app`, `voice`, `send`, `sys`, `num`, `none`. `layerNames` names the layer tabs.

## VS Code

VS Code gets its keypad combos as `pass` and handles them with keybinding rules, so they work with any input method
and can never type into a file. PromptPad adds its rules to VS Code's `keybindings.json` as one marked block and leaves
your own shortcuts alone (the file is backed up once as `keybindings.json.before-promptpad`).
To change them, copy `Resources/vscode-keybindings.json` to `~/Library/Application Support/PromptPad/` and edit it.

## config.json

| Key | Default | |
|---|---|---|
| `voiceStartLabels`, `voiceStopLabels`, `voiceButtonLabels` | English and Chinese names | voice button names, if an app renames them (**Customize → List the Front App’s Buttons** lists them) |
| `queueLabels`, `sendNowLabels` | `queue for later`, `send now` | |
| `holdSeconds` | 0.4 | holding the voice key longer than this is push-to-talk |
| `fineScrollPixels`, `invertFineScroll`, `scrollMethod` | 60, false, — | fine scrolling in chat apps; `"warp"` moves the pointer briefly instead of posting to the app |
| `realClickApps` | from `apps` | bundle ids that need real clicks |
| `micDevices` | all real microphones | names, in order, for microphone switching |
| `dictationEngine` | | per bundle id: `"app"` or `"system"` (set by `toggledictation`) |
| `addons` | all on | `{"headset": false}` switches an add-on off (also from the menu) |
| `maxLogKB`, `keepLogKB` | 512, 128 | log size |
| `language` | build default | `"auto"` (follow macOS), `"en"`, `"zh-Hans"`, … (also menu **Language**) |
| `keyActions` | | older way to override `actions`; still read first |

## Languages

All interface text is written in English, in the code (`L("…")`) and in the layouts. Each other language is one file,
`Resources/i18n/<code>.json`, mapping each English text to its translation; its `"_language"` entry is the name shown
in the menu. Texts with `%@` are formats: keep the `%@` in the translation. Layout files can carry their own
translations under `"strings": {"<code>": {...}}` (add-ons do this), and quick replies (`say:Continue.`) are
translated too, so a Chinese interface sends “继续。”.

To add a language: copy `Resources/i18n/zh-Hans.json` to `Resources/i18n/<code>.json` (e.g. `ja.json`), translate
the values, set `"_language"`, rebuild. It appears in the **Language** menu, and "same as macOS" picks it up.

## Add-ons

An add-on is a folder: `personal/<name>/` for your own (never published, see `.gitignore`) or `addons/<name>/` for
shared ones. `build.sh` builds in every add-on folder it finds.

- `<name>/layout.json` is merged on top of the default layout (add `"title"` for the menu). A layout-only add-on can
  add an app, its actions and its map entries.
- `<name>/*.swift` is compiled into the app. A `final class …: PadAddon` is started at launch (see `Sources/Addons.swift`):
  it gets an `AddonHost` (`isActive`, `automation`, `note`, `perform`) and can add a status line to the menu and a page
  to the map. Use it for extra devices or app-specific code.

Every add-on can be switched on and off in the menu (**Add-ons**). `./build.sh --public` builds without `personal/`.

## Other keypads

PromptPad only needs combos of F13–F20 with Ctrl / Shift / Cmd, so any keypad that can send them works:

- **QMK / VIA keypads**: set `device` (`vendorID`, `productID`) and each key's `pos` (matrix row, column) and `code`;
  **Write Layout to Keypad** writes them over VIA and saves each key's previous value first, so **Restore Keypad Layout…** can undo it.
  Add a factory file (`device.factory`) if you have one.
- **Anything else**: use the keypad's own software (or Karabiner-Elements) to make its keys send the combos.

The map window draws the K0 Max (`padKeys` in `Sources/CheatSheet.swift`); another shape needs its own `padKeys`.
