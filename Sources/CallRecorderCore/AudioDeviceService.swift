@preconcurrency import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var isInUse: Bool

    public init(id: AudioObjectID, uid: String, name: String, isInUse: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isInUse = isInUse
    }
}

public enum AudioDeviceService {
    public static func inputDevices() -> [AudioInputDevice] {
        let activeInputDeviceIDs = activeInputDeviceIDs()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var identifiers = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &identifiers
        ) == noErr else { return [] }

        return identifiers.compactMap { identifier in
            guard hasInputStreams(identifier),
                  let uid = stringProperty(identifier, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(identifier, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(
                id: identifier,
                uid: uid,
                name: name,
                isInUse: activeInputDeviceIDs.contains(identifier)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var identifier = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &identifier
        ) == noErr, identifier != kAudioObjectUnknown else { return nil }
        return identifier
    }

    public static func preferredInputDevice(
        from devices: [AudioInputDevice],
        defaultDeviceID: AudioObjectID? = defaultInputDeviceID()
    ) -> AudioInputDevice? {
        let devicesInUse = devices.filter(\.isInUse)
        if let defaultDeviceID,
           let runningDefault = devicesInUse.first(where: { $0.id == defaultDeviceID }) {
            return runningDefault
        }
        if devicesInUse.count == 1 {
            return devicesInUse[0]
        }
        if let defaultDeviceID,
           let defaultDevice = devices.first(where: { $0.id == defaultDeviceID }) {
            return defaultDevice
        }
        return devices.first
    }

    private static func hasInputStreams(_ identifier: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(identifier, &address, 0, nil, &size) == noErr &&
            size >= MemoryLayout<AudioStreamID>.stride
    }

    private static func activeInputDeviceIDs() -> Set<AudioObjectID> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processIDs = objectIDArray(
            from: system,
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )
        return processIDs.reduce(into: Set<AudioObjectID>()) { activeDevices, processID in
            guard uint32Property(
                from: processID,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal
            ) != 0 else { return }
            activeDevices.formUnion(
                objectIDArray(
                    from: processID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                )
            )
        }
    }

    private static func objectIDArray(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var values = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &values
        ) == noErr else { return [] }
        return values
    }

    private static func uint32Property(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func stringProperty(
        _ identifier: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        guard withUnsafeMutablePointer(to: &value, { pointer in
            AudioObjectGetPropertyData(identifier, &address, 0, nil, &size, pointer)
        }) == noErr else { return nil }
        return value as String
    }
}
