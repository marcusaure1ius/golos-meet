import CoreAudio
import Foundation
import os

/// Опрашивает Core Audio раз в `pollInterval` секунд и проверяет, есть ли среди системных
/// аудио-процессов хотя бы один с bundle id, начинающимся на `bundlePrefix` (kontur.talk),
/// у которого `kAudioProcessPropertyIsRunning == true`. Результат передаётся в `onActive`.
final class AudioProcessMonitor {
    var onActive: ((Bool) -> Void)?
    private let bundlePrefix: String
    private let pollInterval: TimeInterval
    private var timer: Timer?

    init(bundlePrefix: String = "kontur.talk", pollInterval: TimeInterval = 1.5) {
        self.bundlePrefix = bundlePrefix
        self.pollInterval = pollInterval
    }

    /// Возвращает true, если bundleId не nil и начинается на prefix (без учёта регистра).
    static func matchesTargetBundle(_ bundleId: String?, prefix: String) -> Bool {
        guard let bundleId else { return false }
        return bundleId.lowercased().hasPrefix(prefix.lowercased())
    }

    /// Запускает периодический опрос; при каждом тике вызывает `onActive(isAnyActive)`.
    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer = t
        poll()
    }

    /// Останавливает опрос.
    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Private

    private func poll() {
        let active = isAnyTalkProcessRunning()
        Log.detector.debug("AudioProcessMonitor poll: active=\(active)")
        onActive?(active)
    }

    private func isAnyTalkProcessRunning() -> Bool {
        guard let objs = processObjects() else { return false }
        for obj in objs {
            let bundle = stringProp(obj, kAudioProcessPropertyBundleID)
            guard Self.matchesTargetBundle(bundle, prefix: bundlePrefix) else { continue }
            if (uint32Prop(obj, kAudioProcessPropertyIsRunning) ?? 0) != 0 { return true }
        }
        return false
    }

    private func processObjects() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &objs) == noErr else { return nil }
        return objs
    }

    private func uint32Prop(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var psize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &psize, &value) == noErr else { return nil }
        return value
    }

    private func stringProp(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: CFString? = nil
        var ssize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &ssize, &ref) == noErr else { return nil }
        return ref as String?
    }
}
