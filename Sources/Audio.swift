// Microphone switching: changes macOS's default input device, which voice input in most apps uses.
import CoreAudio
import Foundation

struct InputDevice { let id: AudioObjectID; let name: String; let transport: UInt32 }

enum Microphones {
    private static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr
    }

    /// Every device that can record.
    static func all() -> [InputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            var t: UInt32 = 0; _ = get(id, kAudioDevicePropertyTransportType, &t)
            return InputDevice(id: id, name: deviceName(id), transport: t)
        }
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    static func current() -> InputDevice? {
        var id: AudioObjectID = 0
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) else { return nil }
        return all().first { $0.id == id }
    }

    /// The devices to rotate through: config "micDevices" (names, in order) or every real microphone
    /// (built-in, USB, Bluetooth such as AirPods, and the iPhone), skipping virtual ones like Zoom and Teams.
    static func rotation() -> [InputDevice] {
        let devices = all()
        if let names = readConfig()["micDevices"] as? [String], !names.isEmpty {
            return names.compactMap { n in devices.first { $0.name == n } }
        }
        let skip: Set<UInt32> = [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                 kAudioDeviceTransportTypeAutoAggregate]
        return devices.filter { !skip.contains($0.transport) }
    }

    @discardableResult
    static func select(_ id: AudioObjectID) -> Bool {
        var v = id
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &v) == noErr
    }

    /// Switches to the next microphone and returns its name.
    static func next() -> String? {
        let list = rotation()
        guard !list.isEmpty else { return nil }
        let i = current().flatMap { c in list.firstIndex { $0.id == c.id } }
        let target = i.map { list[($0 + 1) % list.count] } ?? list[0]
        return select(target.id) ? target.name : nil
    }
}
