// The microphone list shown when switching mics: every microphone with an icon, the one in use highlighted.
import SwiftUI
import CoreAudio

struct MicItem: Identifiable { let id: String; let name: String; let symbol: String; let current: Bool }

enum MicIcon {
    static func symbol(name: String, transport: UInt32) -> String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return n.contains("airpods") ? "airpodspro" : "headphones"
        default:
            if n.contains("cam") || n.contains("webcam") { return "web.camera" }
            if n.contains("iphone") { return "iphone" }
            return "headphones"
        }
    }
}

struct MicListView: View {
    let items: [MicItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                Text(L("Microphone")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L("Press again for the next one")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(items) { m in
                HStack(spacing: 10) {
                    Image(systemName: m.symbol).font(.system(size: 15)).frame(width: 22)
                        .foregroundStyle(m.current ? Color.white : Color.secondary)
                    Text(m.name).font(.system(size: 14, weight: m.current ? .semibold : .regular))
                        .foregroundStyle(m.current ? Color.white : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if m.current { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(m.current ? Color.accentColor : Color.clear))
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
