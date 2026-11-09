import CoreAudio
import Foundation

/// Errors thrown by `SystemAudioBeatSource.start`.
public enum AudioCaptureError: Error, LocalizedError {
    /// macOS is older than 14.2 (no system-audio taps).
    case unsupported
    /// The user hasn't granted (or has revoked) System Audio Recording access.
    case denied
    /// A Core Audio call failed for another reason.
    case coreAudio(step: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "System audio capture needs macOS 14.2 or later."
        case .denied:
            return "Lidlight isn't allowed to record system audio. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording."
        case let .coreAudio(step, status):
            return "Core Audio failed while trying to \(step) (\(fourCharacterCode(status)))."
        }
    }
}

/// Renders an `OSStatus` as its four-character code when printable, else as a number.
func fourCharacterCode(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

/// Thin typed wrappers over the Core Audio property API.
enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type, initial: T) -> (OSStatus, T) {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return (status, value)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputDeviceUID() -> String? {
        let (status, device) = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                   as: AudioObjectID.self, initial: kAudioObjectUnknown)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}
