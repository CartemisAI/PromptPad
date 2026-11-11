// PromptPad key map window: the keypad drawn to scale, one view per layer and per app.
import SwiftUI
import AppKit

enum KeyCat: CaseIterable {
    case nav, edit, ai, app, voice, send, sys, num, none
    var color: Color {
        switch self {
        case .nav: return Color(red: 0.25, green: 0.52, blue: 0.96)
        case .edit: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .ai: return Color(red: 0.58, green: 0.38, blue: 0.95)
        case .app: return Color(red: 0.20, green: 0.70, blue: 0.45)
        case .voice: return Color(red: 0.92, green: 0.30, blue: 0.40)
        case .send: return Color(red: 0.10, green: 0.65, blue: 0.70)
        case .sys: return Color(white: 0.55)
        case .num: return Color(white: 0.45)
        case .none: return Color(white: 0.6)
        }
    }
    var name: String {
        switch self {
        case .nav: return L("Navigate"); case .edit: return L("Edit"); case .ai: return L("AI"); case .app: return L("Apps")
        case .voice: return L("Voice"); case .send: return L("Send"); case .sys: return L("System"); case .num: return L("Digits"); case .none: return ""
        }
    }
}

struct KeyFn { let title: String; let symbol: String?; let cat: KeyCat; let detail: String }

/// A page of the map: one of the keypad's layers, or an add-on's own page.
enum PadLayer: Hashable, Identifiable {
    case base, fn, m3, addon(String)
    var id: String { title }
    var title: String {
        switch self {
        case .base: return L(PadLayout.current.layerNames["base"] ?? "Base")
        case .fn: return L(PadLayout.current.layerNames["fn"] ?? "Hold Fn")
        case .m3: return L(PadLayout.current.layerNames["m3"] ?? "Hold M4")
        case .addon(let name): return Addons.title(name)
        }
    }
    var layoutName: String? {
        switch self { case .base: return "base"; case .fn: return "fn"; case .m3: return "m3"; case .addon: return nil }
    }
    /// The keypad layers, then a page for each enabled add-on that has one.
    static func all() -> [PadLayer] {
        [.base, .fn, .m3] + installedAddons.filter { Addons.isEnabled($0.id) && $0.mapPage() != nil }.map { .addon($0.id) }
    }
}

private var iconCache: [String: NSImage] = [:]
/// An app's icon, by bundle identifier.
func appIcon(_ bundle: String) -> NSImage? {
    if let i = iconCache[bundle] { return i }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    let i = NSWorkspace.shared.icon(forFile: url.path); iconCache[bundle] = i; return i
}

/// Physical keys of the keypad (Keychron K0 Max), in grid units (x, y, w, h).
struct PadKey: Identifiable { let id: String; let legend: String; let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat }

let padKeys: [PadKey] = [
    PadKey(id: "knob", legend: "Knob", x: 0, y: 0, w: 1, h: 1),
    PadKey(id: "esc", legend: "Esc", x: 1, y: 0, w: 1, h: 1), PadKey(id: "del", legend: "Del", x: 2, y: 0, w: 1, h: 1),
    PadKey(id: "tab", legend: "Tab", x: 3, y: 0, w: 1, h: 1), PadKey(id: "bksp", legend: "Bksp", x: 4, y: 0, w: 1, h: 1),
    PadKey(id: "m1", legend: "M1", x: 0, y: 1, w: 1, h: 1), PadKey(id: "numlock", legend: "Num", x: 1, y: 1, w: 1, h: 1),
    PadKey(id: "slash", legend: "/", x: 2, y: 1, w: 1, h: 1), PadKey(id: "star", legend: "*", x: 3, y: 1, w: 1, h: 1),
    PadKey(id: "minus", legend: "−", x: 4, y: 1, w: 1, h: 1),
    PadKey(id: "m2", legend: "M2", x: 0, y: 2, w: 1, h: 1), PadKey(id: "7", legend: "7", x: 1, y: 2, w: 1, h: 1),
    PadKey(id: "8", legend: "8", x: 2, y: 2, w: 1, h: 1), PadKey(id: "9", legend: "9", x: 3, y: 2, w: 1, h: 1),
    PadKey(id: "plus", legend: "+", x: 4, y: 2, w: 1, h: 2),
    PadKey(id: "m3", legend: "M3", x: 0, y: 3, w: 1, h: 1), PadKey(id: "4", legend: "4", x: 1, y: 3, w: 1, h: 1),
    PadKey(id: "5", legend: "5", x: 2, y: 3, w: 1, h: 1), PadKey(id: "6", legend: "6", x: 3, y: 3, w: 1, h: 1),
    PadKey(id: "m4", legend: "M4", x: 0, y: 4, w: 1, h: 1), PadKey(id: "1", legend: "1", x: 1, y: 4, w: 1, h: 1),
    PadKey(id: "2", legend: "2", x: 2, y: 4, w: 1, h: 1), PadKey(id: "3", legend: "3", x: 3, y: 4, w: 1, h: 1),
    PadKey(id: "enter", legend: "Enter", x: 4, y: 4, w: 1, h: 2),
    PadKey(id: "fn", legend: "Fn", x: 0, y: 5, w: 1, h: 1), PadKey(id: "0", legend: "0", x: 1, y: 5, w: 2, h: 1),
    PadKey(id: "dot", legend: ".", x: 3, y: 5, w: 1, h: 1),
]

extension KeyCat {
    init(code: String?) {
        switch code {
        case "nav": self = .nav; case "edit": self = .edit; case "ai": self = .ai; case "app": self = .app
        case "voice": self = .voice; case "send": self = .send; case "sys": self = .sys; case "num": self = .num
        default: self = .none
        }
    }
}

/// What a key does on a layer in an app, read from layout.json. nil = nothing here.
func keyFunction(_ id: String, _ layer: PadLayer, _ app: String) -> KeyFn? {
    guard let layerName = layer.layoutName, let key = PadLayout.current.keys[id], let l = key[layerName] as? [String: Any],
          let show = l["show"] as? [String: Any] else { return nil }
    let entry = show.keys.contains(app) ? show[app] : show["*"]
    guard let a = entry as? [Any], a.count == 4 else { return nil }
    return KeyFn(title: L((a[0] as? String) ?? ""), symbol: a[1] as? String, cat: KeyCat(code: a[2] as? String),
                 detail: L((a[3] as? String) ?? ""))
}

func keyLegend(_ id: String, fallback: String) -> String {
    L((PadLayout.current.keys[id]?["legend"] as? String) ?? fallback)
}

// MARK: - Views

private func hint(_ key: String, _ what: String) -> some View {
    HStack(spacing: 4) {
        Text(key).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        Text(what).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

struct KeyCapView: View {
    let key: PadKey
    let fn: KeyFn?
    let isLayerKey: Bool
    var focused = false
    var body: some View {
        let cat = fn?.cat ?? .none
        let active = fn != nil
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: key.id == "knob" ? 100 : 10, style: .continuous)
                .fill(active ? cat.color.opacity(isLayerKey ? 0.35 : 0.13) : Color.primary.opacity(0.035))
            RoundedRectangle(cornerRadius: key.id == "knob" ? 100 : 10, style: .continuous)
                .strokeBorder(active ? cat.color.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: isLayerKey ? 2 : 1)
            VStack(spacing: 4) {
                if let sym = fn?.symbol {
                    Image(systemName: sym).font(.system(size: 17, weight: .semibold)).foregroundStyle(cat.color)
                }
                Text(fn?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            if key.id != "knob" {
                Text(keyLegend(key.id, fallback: key.legend)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.leading, 7).padding(.top, 5)
            }
            if focused {
                RoundedRectangle(cornerRadius: key.id == "knob" ? 100 : 11, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
            }
        }
    }
}

/// Shared state so the keyboard (via PromptPad) can drive the map.
final class CheatModel: ObservableObject {
    /// The app shown, by its id in the layout's "apps" list.
    @Published var app: String
    @Published var layer: PadLayer
    private var layerBeforeHold: PadLayer?
    /// Keyboard focus: 0 = app row, 1 = layer row, 2 = the keys.
    @Published var focusRow = 0
    @Published var focusCell = (r: 0, c: 0)
    init(app: String, layer: PadLayer = .base) { self.app = app; self.layer = layer }

    /// Which key sits in each grid cell (wide and tall keys fill several cells).
    static let grid: [[String]] = {
        var g = Array(repeating: Array(repeating: "", count: 5), count: 6)
        for k in padKeys {
            for r in Int(k.y)..<Int(k.y + k.h) { for c in Int(k.x)..<Int(k.x + k.w) { g[r][c] = k.id } }
        }
        return g
    }()
    var focusedKey: String? { focusRow == 2 ? CheatModel.grid[focusCell.r][focusCell.c] : nil }

    /// Arrow keys (8 4 6 2 and the knob). On the app and layer rows, moving sideways switches right away.
    func move(dx: Int, dy: Int) {
        if dy != 0 {
            if focusRow < 2 {
                if dy > 0 { focusRow += 1; if focusRow == 2 { focusCell = (0, 1) } }
                else if focusRow > 0 { focusRow -= 1 }
                return
            }
            let here = CheatModel.grid[focusCell.r][focusCell.c]
            var r = focusCell.r
            repeat { r += dy } while r >= 0 && r < 6 && CheatModel.grid[r][focusCell.c] == here
            if r < 0 { focusRow = 1 } else if r < 6 { focusCell = (r, focusCell.c) }
            return
        }
        switch focusRow {
        case 0: stepApp(dx)
        case 1: stepLayer(dx)
        default:
            let here = CheatModel.grid[focusCell.r][focusCell.c]
            var c = focusCell.c
            repeat { c += dx } while c >= 0 && c < 5 && CheatModel.grid[focusCell.r][c] == here
            if c >= 0 && c < 5 { focusCell = (focusCell.r, c) }
        }
    }

    /// Enter: from the app or layer row, go down into the keys.
    func activate() { if focusRow < 2 { focusRow = 2; focusCell = (0, 1) } }
    func stepLayer(_ d: Int) {
        let all = PadLayer.all(); let i = all.firstIndex(of: layer) ?? 0
        layer = all[(i + d + all.count) % all.count]; layerBeforeHold = nil
    }
    func stepApp(_ d: Int) {
        let all = PadLayout.current.apps.map(\.id); guard !all.isEmpty else { return }
        let i = all.firstIndex(of: app) ?? 0
        app = all[(i + d + all.count) % all.count]
    }
    /// While Fn (which holds Shift) or M4 (which holds Command) is held, show that layer; letting go goes back.
    func preview(_ held: PadLayer?) {
        if let l = held {
            if layer != l { if layerBeforeHold == nil { layerBeforeHold = layer }; layer = l }
        } else if let prev = layerBeforeHold {
            layer = prev; layerBeforeHold = nil
        }
    }
}

struct CheatSheetView: View {
    @ObservedObject var model: CheatModel
    @State private var hovered: String?
    private var app: String { model.app }
    private var appName: String { PadLayout.current.app(id: app)?.name ?? app }
    private var layer: PadLayer { model.layer }

    private let unit: CGFloat = 96, rowH: CGFloat = 62, gap: CGFloat = 8, macroGap: CGFloat = 14

    private func frame(_ k: PadKey) -> CGRect {
        let x = k.x * (unit + gap) + (k.x >= 1 ? macroGap : 0)
        let y = k.y * (rowH + gap) + (k.y >= 1 ? 10 : 0)
        return CGRect(x: x, y: y, width: k.w * unit + (k.w - 1) * gap, height: k.h * rowH + (k.h - 1) * gap)
    }

    private func fnShown(_ id: String) -> (KeyFn?, Bool) {
        if layer == .fn && id == "fn" { return (keyFunction(id, .fn, app), true) }
        if layer == .m3 && id == "m3" { return (keyFunction(id, .m3, app), true) }
        return (keyFunction(id, layer, app), false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // App picker
            HStack(spacing: 6) {
                ForEach(PadLayout.current.apps.map(\.id), id: \.self) { a in
                    let info = PadLayout.current.app(id: a)
                    Button { model.app = a } label: {
                        HStack(spacing: 6) {
                            if let icon = info.flatMap({ appIcon($0.bundle) }) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(L(info?.name ?? a)).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(app == a ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(app == a ? Color.accentColor.opacity(0.6) : .clear))
                        .overlay(Capsule().strokeBorder(model.focusRow == 0 && app == a ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 0) {
                ForEach(PadLayer.all()) { l in
                    Button { model.layer = l } label: {
                        Text(l.title).font(.system(size: 12, weight: layer == l ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(layer == l ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: .black.opacity(layer == l ? 0.12 : 0), radius: 2, y: 1))
                    }.buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.focusRow == 1 ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
            .frame(width: 440)

            if case .addon(let name) = layer {
                installedAddons.first { $0.id == name }?.mapPage() ?? AnyView(EmptyView())
            } else {
                let size = CGSize(width: 5 * unit + 4 * gap + macroGap, height: 6 * rowH + 5 * gap + 10)
                ZStack(alignment: .topLeading) {
                    ForEach(padKeys) { key in
                        let f = frame(key)
                        let (fn, isLayerKey) = fnShown(key.id)
                        KeyCapView(key: key, fn: fn, isLayerKey: isLayerKey, focused: model.focusedKey == key.id)
                            .frame(width: f.width, height: f.height)
                            .offset(x: f.minX, y: f.minY)
                            .onHover { inside in hovered = inside ? key.id : (hovered == key.id ? nil : hovered) }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)

                // Detail line
                Group {
                    if let id = hovered ?? model.focusedKey, let key = padKeys.first(where: { $0.id == id }) {
                        let (fn, _) = fnShown(id)
                        HStack(spacing: 8) {
                            Text(keyLegend(key.id, fallback: key.legend)).font(.system(size: 11, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                            Text(fn?.detail ?? (layer == .base ? L("This key does nothing in %@.", appName) : L("Nothing set on this layer: the key does what it does on the base layer.")))
                                .font(.system(size: 12)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L("Move onto a key with 8 4 6 2, or point at it, to read what it does")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.frame(height: 50, alignment: .topLeading)

                // Legend
                HStack(spacing: 12) {
                    ForEach([KeyCat.nav, .edit, .ai, .app, .voice, .send, .sys], id: \.self) { c in
                        HStack(spacing: 4) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Text(c.name).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                hint(L("8 4 6 2 / knob"), L("move")); hint(L("Enter"), L("into the keys")); hint(L("hold Fn / M4"), L("see that layer")); hint("Esc", L("close"))
            }
        }
        .padding(22)
        .frame(width: 5 * unit + 4 * gap + macroGap + 44, alignment: .topLeading)
    }
}
