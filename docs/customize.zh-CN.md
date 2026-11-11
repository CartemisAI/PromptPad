# 改成你自己的习惯

[English](customize.md)

PromptPad 带的是一个人的使用习惯。这些习惯都写在数据文件里，不用改 Swift 代码就能改成你自己的。

| 改什么 | 写在哪里 | 怎么生效 |
|---|---|---|
| 每个键在各应用里做什么；支持哪些应用；键位图上写什么 | 个人布局：`~/Library/Application Support/PromptPad/layout.json` | 菜单 **自定义 → 重新加载布局** |
| 小设置（语音按钮的名字、滚动幅度等） | `~/Library/Application Support/PromptPad/config.json` | 立即生效 |
| VS Code 规则 | 你的副本：`~/Library/Application Support/PromptPad/vscode-keybindings.json` | 菜单 **自定义 → 更新 VS Code 规则** |
| 小键盘本身每个键发的码 | 个人布局（`keys.<键>.<层>.code`） | 菜单 **自定义 → 写入键盘布局**（用 USB 线连接、拨到有线档） |

菜单 **自定义 → 编辑个人布局…** 会建好个人布局文件并打开它。

## 个人布局文件

只写想改的部分。它会叠加在默认布局（`Resources/layout.json`）上：对象逐个键合并，`apps` 列表按 `id` 合并，其他内容直接替换。

```json
{
  "actions": {
    "shift+cmd+f19": { "claude": "say:继续。", "chatgpt": "say:继续。" },
    "shift+cmd+f18": { "chrome": "keys:cmd+shift+t" }
  },
  "keys": {
    "slash": { "fn": { "show": { "claude": ["继续", "text.bubble", "ai", "粘贴并发送“继续。”"] } } }
  }
}
```

改了默认布局或插件之后，跑一下 `python3 scripts/check-layout.py`。它会查出这些问题：键码带了 Option、两个键发同一个组合、VS Code 里写了 `pass` 却没有对应规则、写法不对的条目。

## 一次按键怎么变成一个动作

1. 小键盘的固件发出一个**组合**：F13 到 F20 加修饰键，比如 `ctrl+shift+cmd+f15`。按住 **Fn** 会加上 Shift，按住 **M4** 会加上 Command（它们是层键），所以每一层发的组合都不一样。组合里从不用 Option：连按两下 Option 会打开 Claude 的快速输入。
2. PromptPad 截住这个组合（别的应用收不到），去查 `actions[组合]`：可以是对所有应用都一样的一个动作，也可以按应用 id 分别写，再加一个可选的 `"default"`。
3. 在前台应用里执行这个动作。组合的名字按 `ctrl+opt+shift+cmd+键` 的顺序写。

发普通按键的键（方向键、上下翻页、Esc、按住 M4 时的数字）直接交给应用。

## 动作

| 动作 | 做什么 |
|---|---|
| `keys:cmd+shift+e` | 发一个快捷键；`keys:cmd+k,v` 依次发一串 |
| `type:,` | 直接打出文字，不受输入法影响 |
| `say:文字` / `paste:文字` | 把文字放进聊天应用的输入框并发送 / 只粘贴不发送 |
| `menu:View>Toggle Side Chat` | 点前台应用的菜单项 |
| `button:Voice Input` | 点名字以这段文字开头的按钮 |
| `app:claude` / `cycle:chrome,vscode` | 切到某个应用 / 在几个应用之间轮换（写应用 id 或程序标识） |
| `hold:rightoption` | 按住这个键时一直按着某个修饰键（`rightoption`、`leftoption`、`rightcommand`、`rightshift`、`fn`） |
| `voice` | 语音键：点按开关，按住说话（见“应用”） |
| `voice:/btw ` | 聊天应用：先在输入框最前面放上这段文字，再开始语音（Claude 的 `/btw` 顺便提问） |
| `send`、`forcesend`、`queue`、`focus`、`scroll:up`、`scroll:down` | 只在聊天应用里：回车、立即发送、稍后发送、回到输入框、滚动对话 |
| `toggledictation` | 让前台应用在自带语音输入和 macOS 听写之间切换 |
| `cheatsheet`、`nextmic` | 打开或关掉键位图；显示或切换麦克风 |
| `pass` | 把组合原样交给应用，由它自己处理（VS Code 用这个） |
| `none` | 故意什么都不做 |

按住一个键时，只有移动和编辑会连发：`keys:` 里是方向、删除、翻页、空格、Tab、回车、撤销的，以及 `type:` 和 `scroll:`。其他动作每按一次只做一次。

## 应用

```json
"apps": [
  { "id": "claude",  "name": "Claude",  "bundle": "com.anthropic.claudefordesktop", "ai": true, "voice": "shortcut", "voiceKeys": "cmd+d" },
  { "id": "cursor",  "name": "Cursor",  "bundle": "com.todesktop.230313mzl4w4u92", "voice": "system" }
]
```

- `id` 是动作和 `show` 里用的名字；`name` 显示在键位图上；`bundle` 是 macOS 的程序标识，可以用 `osascript -e 'id of app "Cursor"'` 查。
- `ai: true` 表示这是有输入框的聊天应用：`say:`、`focus`、`queue`、`forcesend`、`scroll:` 只在这类应用里起作用。
- `voice`：`shortcut`（发 `voiceKeys`，不行就点麦克风按钮）、`button`（按名字点语音按钮）、`toggleButton`（点名字以 `voiceButton` 开头的按钮，自己记开关次数）、`system`（macOS 听写）、`off`（不启用）。
- `realClick: true` 用于不认程序点击的应用，改为真实的鼠标点击。

加一个应用：在 `apps` 里写上它，再在 `actions` 里按它的 id 配动作，在 `show` 里写键位图上的说明。

## 键位图上写什么

每个键的每一层都有 `show`：`{ "*": [...], "<应用 id>": [...] }`。一条是 `[标题, SF Symbol 图标名, 类别, 说明]`，写 `null` 表示“这里没有功能”。类别决定键的颜色：`nav`、`edit`、`ai`、`app`、`voice`、`send`、`sys`、`num`、`none`。`layerNames` 是层标签上的名字。

## VS Code

VS Code 收到的小键盘组合是 `pass`，由快捷键规则来处理，所以不受输入法影响，也绝不会往文件里打字。PromptPad 把它的规则作为一段带标记的内容加进 VS Code 的 `keybindings.json`，你自己的快捷键不动（第一次改之前会备份成 `keybindings.json.before-promptpad`）。想改这些规则，把 `Resources/vscode-keybindings.json` 复制到 `~/Library/Application Support/PromptPad/` 再改。

## config.json

| 设置 | 默认 | |
|---|---|---|
| `voiceStartLabels`、`voiceStopLabels`、`voiceButtonLabels` | 中英文名字 | 应用改了语音按钮的名字时用（**自定义 → 列出当前应用的按钮** 会列出来） |
| `queueLabels`、`sendNowLabels` | `queue for later`、`send now` | |
| `holdSeconds` | 0.4 | 按住语音键超过这么多秒算按住说话 |
| `fineScrollPixels`、`invertFineScroll`、`scrollMethod` | 60、false、— | 聊天应用里的微调滚动；`"warp"` 改为把指针临时移过去再滚 |
| `realClickApps` | 来自 `apps` | 需要真实点击的程序标识 |
| `micDevices` | 所有真实麦克风 | 切换麦克风时用的名字和顺序 |
| `dictationEngine` | | 按程序标识：`"app"` 或 `"system"`（`toggledictation` 会写） |
| `addons` | 全部打开 | `{"headset": false}` 关掉一个插件（菜单里也能开关） |
| `maxLogKB`、`keepLogKB` | 512、128 | 日志大小 |
| `language` | 编译时的默认值 | `"auto"`（跟随系统）、`"en"`、`"zh-Hans"` 等（菜单 **语言** 里也能选） |
| `keyActions` | | 旧的改 `actions` 的方式，仍然最先读 |

## 语言

界面文字都用英文写：代码里是 `L("…")`，布局里直接写。每种其他语言是一个文件 `Resources/i18n/<语言代码>.json`，把每句英文对应到译文；其中 `"_language"` 是菜单里显示的语言名。带 `%@` 的是格式字符串，翻译时要保留 `%@`。布局文件也可以在 `"strings": {"<语言代码>": {...}}` 里带自己的翻译（插件就是这样做的）。快捷回复（`say:Continue.`）也会翻译，所以中文界面发出去的是“继续。”。

加一种语言：把 `Resources/i18n/zh-Hans.json` 复制成 `Resources/i18n/<语言代码>.json`（比如 `ja.json`），翻译每一条，写好 `"_language"`，重新编译。它会出现在菜单 **语言** 里，“跟随系统”也能自动选到它。

## 插件

插件就是一个文件夹：自己用的放 `personal/<名字>/`（不会发布，见 `.gitignore`），要分享的放 `addons/<名字>/`。`build.sh` 会把找到的每个模块都编进去。

- `<名字>/layout.json` 叠加在默认布局上（写一个 `"title"` 作为菜单里的名字）。只有布局的模块可以加一个应用、它的动作和键位图说明。
- `<名字>/*.swift` 会编进程序。启动时会启动其中的 `final class …: PadAddon`（见 `Sources/Addons.swift`）：它拿到一个 `AddonHost`（`isActive`、`automation`、`note`、`perform`），可以在菜单里加一行状态，在键位图上加一页。适合接其他设备，或者写某个应用专用的代码。

每个模块都能在菜单 **插件** 里开关。`./build.sh --public` 编译时不带 `personal/`。

## 换别的小键盘

PromptPad 只需要 F13 到 F20 加 Ctrl / Shift / Cmd 的组合，所以任何能发这些组合的小键盘都能用：

- **QMK / VIA 小键盘**：设置 `device`（`vendorID`、`productID`），以及每个键的 `pos`（矩阵的行、列）和 `code`。**写入键盘布局** 会通过 VIA 写进去，写之前先保存每个键原来的设置，所以 **还原键盘布局…** 能撤销。有出厂设置文件的话写在 `device.factory`。
- **其他小键盘**：用它自带的软件（或 Karabiner-Elements）让各个键发这些组合。

键位图画的是 K0 Max 的形状（`Sources/CheatSheet.swift` 里的 `padKeys`）；别的形状要写自己的 `padKeys`。
