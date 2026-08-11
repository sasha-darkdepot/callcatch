import CoreAudio
import AppKit

/// Слушает CoreAudio process objects (macOS 14.4+): какие процессы используют
/// микрофон. Событийно, без поллинга и без разрешений. Проверено пробником
/// 2026-08-11 на macOS 27: bundle id отдаются, helper-процессы видны.
final class MicMonitor {
    private let tracker: PIDTracker
    private var knownProcesses: [AudioObjectID: pid_t] = [:]
    private var listenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lastReportedInput: [AudioObjectID: Bool] = [:]
    private var seenUnwatched: Set<AudioObjectID> = []
    private var pollTimer: Timer?
    private let queue = DispatchQueue.main

    init(tracker: PIDTracker) {
        self.tracker = tracker
    }

    private static func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var listAddr = Self.addr(kAudioHardwarePropertyProcessObjectList)
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.refreshProcessList() }
        }
        let err = AudioObjectAddPropertyListenerBlock(systemObj, &listAddr, queue, listBlock)
        Log.info("MicMonitor: start, list listener err=\(err)")
        refreshProcessList()
        // Поллинг-фоллбэк: листенеры IsRunningInput на практике срабатывают не для
        // всех приложений — раз в 3 сек пересканируем список и опрашиваем состояние
        // наблюдаемых процессов сами (дёшево: несколько property-читов).
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshProcessList()
            for obj in self.knownProcesses.keys { self.inputStateChanged(obj) }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func refreshProcessList() {
        var listAddr = Self.addr(kAudioHardwarePropertyProcessObjectList)
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(systemObj, &listAddr, 0, nil, &size)
        guard sizeErr == noErr else { Log.info("MicMonitor: list size err=\(sizeErr)"); return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let dataErr = AudioObjectGetPropertyData(systemObj, &listAddr, 0, nil, &size, &ids)
        guard dataErr == noErr else { Log.info("MicMonitor: list data err=\(dataErr)"); return }

        let current = Set(ids)
        for (obj, pid) in knownProcesses where !current.contains(obj) {
            Log.info("MicMonitor: process gone obj=\(obj) pid=\(pid)")
            tracker.processTerminated(pid: pid)
            if let block = listenerBlocks.removeValue(forKey: obj) {
                var inputAddr = Self.addr(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(obj, &inputAddr, queue, block)
            }
            knownProcesses.removeValue(forKey: obj)
            lastReportedInput.removeValue(forKey: obj)
        }
        for obj in ids where knownProcesses[obj] == nil {
            let pid = readPID(obj)
            guard pid > 0 else { continue }
            guard let app = watchedApp(for: obj, pid: pid) else {
                // Диагностика (однократно на объект): чем приложение реально пользуется.
                if seenUnwatched.insert(obj).inserted {
                    Log.info("MicMonitor: new unwatched obj=\(obj) pid=\(pid) bundle=\(readBundleID(obj))")
                }
                continue
            }
            knownProcesses[obj] = pid
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.inputStateChanged(obj) }
            }
            listenerBlocks[obj] = block
            var inputAddr = Self.addr(kAudioProcessPropertyIsRunningInput)
            let err = AudioObjectAddPropertyListenerBlock(obj, &inputAddr, queue, block)
            Log.info("MicMonitor: watching \(app.rawValue) pid=\(pid) obj=\(obj) listenerErr=\(err)")
            inputStateChanged(obj)
        }
    }

    private func inputStateChanged(_ obj: AudioObjectID) {
        guard let pid = knownProcesses[obj], let app = watchedApp(for: obj, pid: pid) else { return }
        let running = readIsRunningInput(obj)
        if lastReportedInput[obj] != running {
            lastReportedInput[obj] = running
            Log.info("MicMonitor: \(app.rawValue) pid=\(pid) input=\(running)")
        }
        tracker.micStateChanged(pid: pid, app: app, isRunningInput: running)
    }

    private func watchedApp(for obj: AudioObjectID, pid: pid_t) -> WatchedApp? {
        var bundle = readBundleID(obj)
        if bundle.isEmpty, let app = NSRunningApplication(processIdentifier: pid) {
            bundle = app.bundleIdentifier ?? "" // fallback: пустой bundle у helper'а
        }
        return WatchedApps.match(bundleID: bundle)
    }

    private func readPID(_ obj: AudioObjectID) -> pid_t {
        var a = Self.addr(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var v: pid_t = -1
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : -1
    }

    private func readIsRunningInput(_ obj: AudioObjectID) -> Bool {
        var a = Self.addr(kAudioProcessPropertyIsRunningInput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var v: UInt32 = 0
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    private func readBundleID(_ obj: AudioObjectID) -> String {
        var a = Self.addr(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr,
              let s = v?.takeRetainedValue() else { return "" }
        return s as String
    }
}
