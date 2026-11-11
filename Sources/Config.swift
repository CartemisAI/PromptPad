// Settings, paths and the log.
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/PromptPad")
let configURL = supportDir.appendingPathComponent("config.json")
/// Optional personal layout, merged on top of the built-in one (same format, only the parts you change).
let userLayoutURL = supportDir.appendingPathComponent("layout.json")
/// Optional personal VS Code rules, used instead of the built-in ones.
let userVSCodeRulesURL = supportDir.appendingPathComponent("vscode-keybindings.json")
/// What the keyboard had before PromptPad first wrote each key (for keys not in the factory list).
let keyboardBackupURL = supportDir.appendingPathComponent("keyboard-backup.txt")
let logURL = home.appendingPathComponent("Library/Logs/PromptPad.log")
let dumpURL = home.appendingPathComponent("Library/Logs/PromptPad-dump.txt")
let menusDumpURL = home.appendingPathComponent("Library/Logs/PromptPad-menus.txt")

/// config.json, cached and re-read only when the file changes (it's consulted on every key press).
enum Config {
    private static let lock = NSLock()
    private static var cache: [String: Any] = [:]
    private static var stamp: Date?
    private static var broken = false

    static func read() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let mod = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        if mod != stamp || stamp == nil {
            stamp = mod
            if let data = try? Data(contentsOf: configURL) {
                if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { cache = obj; broken = false }
                else { cache = [:]; broken = true }
            } else { cache = [:]; broken = false }
        }
        return cache
    }

    /// Changes config.json. Refuses (returns false) when the file exists but can't be parsed, so a typo
    /// in a hand-edited file is never silently replaced.
    @discardableResult
    static func update(_ change: (inout [String: Any]) -> Void) -> Bool {
        var cfg = read()
        lock.lock(); let isBroken = broken; lock.unlock()
        guard !isBroken else { log("config.json has an error, not written"); return false }
        change(&cfg)
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return (try? data.write(to: configURL)) != nil
    }
}

func readConfig() -> [String: Any] { Config.read() }

func labelSet(_ key: String, _ defaults: [String]) -> Set<String> {
    let list = (readConfig()[key] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? defaults
    return Set(list.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
}
func voiceStartLabels() -> Set<String> {
    labelSet("voiceStartLabels", ["press and hold to record", "dictate", "start dictation", "voice", "听写", "开始听写"])
}
func voiceStopLabels() -> Set<String> {
    labelSet("voiceStopLabels", ["stop dictation", "finish dictating", "停止听写"])
}
func voiceLabels() -> Set<String> {
    labelSet("voiceButtonLabels", ["dictate", "start dictation", "stop dictation", "finish dictating", "dictation",
                                   "voice", "voice mode", "voice input", "use voice", "start voice", "stop voice",
                                   "听写", "开始听写", "停止听写", "语音", "语音输入"])
}
func queueLabels() -> Set<String> { labelSet("queueLabels", ["queue for later"]) }
/// The button that sends a queued message right away: Claude calls it "Send now", ChatGPT "Steer".
func sendNowLabels() -> Set<String> { labelSet("sendNowLabels", ["send now", "steer"]) }
/// Holding the voice key longer than this (seconds) is push-to-talk: letting go stops the recording.
func holdThreshold() -> Double { (readConfig()["holdSeconds"] as? Double) ?? 0.4 }

// MARK: - Log

private let logQueue = DispatchQueue(label: "PromptPad.log")
private let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
private var logWritesSinceTrim = 0
private var loggingEnabled = true

/// Appends a line to ~/Library/Logs/PromptPad.log. Safe from any thread.
func log(_ msg: String) {
    let date = Date()
    logQueue.async {
        guard loggingEnabled else { return }
        let line = Data("[\(logTime.string(from: date))] \(msg)\n".utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: logURL)
        }
        logWritesSinceTrim += 1
        if logWritesSinceTrim >= 200 { logWritesSinceTrim = 0; trimLogsNow() }
    }
}

/// Stops logging and waits for pending lines (used right before uninstall deletes the log).
func stopLogging() { logQueue.sync { loggingEnabled = false } }

func trimLogs() { logQueue.async { trimLogsNow() } }

/// Keeps the log small: above `maxLogKB` (default 512) only the newest `keepLogKB` (default 128) is kept.
/// The control dump file is deleted after 3 days.
private func trimLogsNow() {
    let fm = FileManager.default
    let maxBytes = ((readConfig()["maxLogKB"] as? Int) ?? 512) * 1024
    let keepBytes = ((readConfig()["keepLogKB"] as? Int) ?? 128) * 1024
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > maxBytes,
       let data = try? Data(contentsOf: logURL) {
        var tail = data.suffix(keepBytes)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }   // start on a whole line
        let header = "[\(logTime.string(from: Date()))] Log over \(maxBytes / 1024) KB: older lines removed\n"
        try? (Data(header.utf8) + tail).write(to: logURL)
    }
    if let mod = (try? fm.attributesOfItem(atPath: dumpURL.path))?[.modificationDate] as? Date,
       Date().timeIntervalSince(mod) > 3 * 24 * 3600 {
        try? fm.removeItem(at: dumpURL)
    }
}
