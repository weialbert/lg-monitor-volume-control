import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import ServiceManagement
import Darwin

private struct Monitor: Decodable, Identifiable {
    let id: String
    let name: String
    let audioUID: String?
    var volume: Int
    var maxVolume: Int
}

private struct CLIReply: Decodable {
    let ok: Bool
    var monitors: [Monitor]?
    var volume: Int?
    var maxVolume: Int?
    var muted: Bool?
    var error: String?
}

private final class CLIRunner {
    private let queue = DispatchQueue(label: "local.lg-monitor-volume.cli", qos: .userInitiated)
    private var process: Process?
    private let stateLock = NSLock()
    private var running = false
    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }

    func run(_ args: [String], completion: @escaping (Result<CLIReply, Error>) -> Void) {
        queue.async {
            self.stateLock.lock(); self.running = true; self.stateLock.unlock()
            defer { self.stateLock.lock(); self.running = false; self.stateLock.unlock() }
            let task = Process()
            task.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/lg-monitor-cli")
            task.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr
            self.process = task
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + 8)
            timer.setEventHandler {
                guard task.isRunning else { return }
                task.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    if task.isRunning { _ = kill(task.processIdentifier, SIGKILL) }
                }
            }
            timer.resume()
            do {
                try task.run()
                task.waitUntilExit()
                timer.cancel()
                self.process = nil
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if let reply = try? JSONDecoder().decode(CLIReply.self, from: data) {
                    DispatchQueue.main.async {
                        if reply.ok { completion(.success(reply)) }
                        else { completion(.failure(AppError.message(reply.error ?? "Monitor operation failed."))) }
                    }
                } else {
                    let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let message = detail.isEmpty ? "The monitor helper returned invalid data." : detail
                    DispatchQueue.main.async { completion(.failure(AppError.message(message))) }
                }
            } catch {
                timer.cancel()
                self.process = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

private enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@MainActor
private final class MenuController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let runner = CLIRunner()
    private var monitors: [Monitor] = []
    private var selected: Monitor? { didSet { if let selected { UserDefaults.standard.set(selected.id, forKey: "selectedMonitor") }; refreshMenu() } }
    private var currentVolume = 0
    private var controlError: String?
    private var volumeKnown = false
    private var muted: Bool?
    private var pendingKeyDelta = 0
    private var keyAdjustmentInFlight = false
    private var volumePercent: Int { guard let maximum = selected?.maxVolume, maximum > 0 else { return currentVolume }; return Int((Double(currentVolume) * 100 / Double(maximum)).rounded()) }
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refreshMenu()
        discover()
        installVolumeKeyTap()
        watchDefaultOutput()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.discover() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.discover() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.installVolumeKeyTap()
                self?.refreshVolume()
                self?.refreshMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let audioListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.main, audioListener) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        refreshTimer?.invalidate()
    }

    private func discover() {
        runner.run(["list"]) { [weak self] result in
            guard let self else { return }
            if case .success(let reply) = result, reply.ok, let found = reply.monitors {
                self.monitors = found
                let saved = UserDefaults.standard.string(forKey: "selectedMonitor")
                self.selected = found.first(where: { $0.id == saved }) ?? found.first
                self.currentVolume = self.selected?.volume ?? 0
                self.volumeKnown = self.selected != nil
                self.refreshMute()
            } else {
                self.monitors = []
                self.selected = nil
            }
            self.refreshMenu()
        }
    }

    private func refreshVolume() {
        guard !runner.isRunning, let monitor = selected else { return }
        runner.run(["get-volume", monitor.id]) { [weak self] result in
            guard let self, self.selected?.id == monitor.id,
                  case .success(let reply) = result, reply.ok, let value = reply.volume else { return }
            self.currentVolume = value
            self.volumeKnown = true
            if let max = reply.maxVolume, let index = self.monitors.firstIndex(where: { $0.id == monitor.id }) { self.monitors[index].maxVolume = max; self.monitors[index].volume = value }
            self.refreshMenu()
        }
    }

    private func refreshMute() {
        guard !runner.isRunning, let monitor = selected else { muted = nil; return }
        runner.run(["get-mute", monitor.id]) { [weak self] result in
            guard let self, self.selected?.id == monitor.id else { return }
            if case .success(let reply) = result, reply.ok { self.muted = reply.muted } else { self.muted = nil }
            self.refreshMenu()
        }
    }

    private func setVolume(_ percent: Int) {
        guard let monitor = selected else { return }
        runner.run(["set-volume", monitor.id, "\(percent)"]) { [weak self] result in
            guard let self, self.selected?.id == monitor.id else { return }
            if case .success(let reply) = result, reply.ok { self.currentVolume = reply.volume ?? percent } else if case .failure(let error) = result { self.showError(error.localizedDescription) }
            self.refreshMenu()
        }
    }

    private func adjustVolumeForKey(by delta: Int) {
        pendingKeyDelta = max(-100, min(100, pendingKeyDelta + delta))
        flushKeyAdjustment()
    }

    private func flushKeyAdjustment() {
        guard volumeKnown, controlError == nil, !keyAdjustmentInFlight, pendingKeyDelta != 0, let monitor = selected else { pendingKeyDelta = 0; return }
        let delta = pendingKeyDelta
        pendingKeyDelta = 0
        let target = max(0, min(monitor.maxVolume, currentVolume + delta))
        guard target != currentVolume else { return }
        keyAdjustmentInFlight = true
        runner.run(["set-volume", monitor.id, "\(target)"]) { [weak self] result in
            guard let self else { return }
            self.keyAdjustmentInFlight = false
            if self.selected?.id == monitor.id, case .success(let reply) = result, reply.ok {
                self.currentVolume = reply.volume ?? target
                self.refreshMenu()
            } else if case .failure(let error) = result {
                self.showError(error.localizedDescription)
            }
            self.flushKeyAdjustment()
        }
    }

    private func setMute(_ on: Bool) {
        guard let monitor = selected else { return }
        runner.run(["mute", monitor.id, on ? "true" : "false"]) { [weak self] result in
            guard let self, self.selected?.id == monitor.id else { return }
            if case .success(let reply) = result, reply.ok { self.muted = on } else if case .failure(let error) = result { self.showError(error.localizedDescription) }
            self.refreshMenu()
        }
    }

    private func refreshMenu() {
        statusItem.button?.title = selected == nil ? "🔊" : (muted == true ? "🔇" : "🔊 \(volumePercent)%")
        let menu = NSMenu()
        if let controlError {
            let errorItem = NSMenuItem(title: controlError, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        let header = NSMenuItem(title: selected?.name ?? "No LG monitor found", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let volumeItem = NSMenuItem(title: "Volume: \(volumePercent)%", action: nil, keyEquivalent: "")
        volumeItem.isEnabled = false
        menu.addItem(volumeItem)
        let slider = NSSlider(value: Double(currentVolume), minValue: 0, maxValue: Double(max(1, selected?.maxVolume ?? 100)), target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = false
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)
        let muteItem = NSMenuItem(title: muted == true ? "Unmute" : "Mute", action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        muteItem.isEnabled = selected != nil && muted != nil
        menu.addItem(muteItem)
        menu.addItem(.separator())
        let pairing = NSMenuItem(title: "Monitor", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for monitor in monitors {
            let item = NSMenuItem(title: monitor.name, action: #selector(selectMonitor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = monitor.id
            item.state = monitor.id == selected?.id ? .on : .off
            submenu.addItem(item)
        }
        pairing.submenu = submenu
        pairing.isEnabled = !monitors.isEmpty
        menu.addItem(pairing)
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        if !AXIsProcessTrusted() {
            let accessItem = NSMenuItem(title: "Enable Accessibility for Volume Keys…", action: #selector(openAccessibility), keyEquivalent: "")
            accessItem.target = self
            menu.addItem(accessItem)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func sliderChanged(_ sender: NSSlider) { setVolume(sender.integerValue) }
    @objc private func toggleMute() { if let muted { setMute(!muted) } }
    @objc private func selectMonitor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selected = monitors.first(where: { $0.id == id })
        currentVolume = selected?.volume ?? 0
        refreshVolume()
        refreshMute()
    }
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error.localizedDescription) }
        refreshMenu()
    }
    @objc private func openAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        controlError = message
        pendingKeyDelta = 0
        volumeKnown = false
        statusItem.button?.toolTip = message
        refreshMenu()
    }

    private func watchDefaultOutput() {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in DispatchQueue.main.async { self?.discover() } }
        audioListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func isSelectedMonitorDefaultOutput() -> Bool {
        guard volumeKnown, controlError == nil, let uid = selected?.audioUID else { return false }
        var address = Self.defaultOutputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, UnsafeMutableRawPointer(uidPointer))
        }
        guard uidStatus == noErr, let cfUID else { return false }
        return (cfUID as String) == uid
    }

    private func installVolumeKeyTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << 14
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon, let app = Unmanaged<MenuController>.fromOpaque(refcon).takeUnretainedValue() as MenuController? else { return Unmanaged.passRetained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passRetained(event)
            }
            guard app.isSelectedMonitorDefaultOutput() else { return Unmanaged.passRetained(event) }
            guard let nativeEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }
            let data = nativeEvent.data1
            guard (data & 0xff00) == 0x0a00 else { return Unmanaged.passRetained(event) }
            let code = (data >> 16) & 0xff
            switch code {
            case 0x48: DispatchQueue.main.async { app.adjustVolumeForKey(by: 1) }; return nil
            case 0x49: DispatchQueue.main.async { app.adjustVolumeForKey(by: -1) }; return nil
            case 0x4a:
                guard let muted = app.muted else { return Unmanaged.passRetained(event) }
                DispatchQueue.main.async { app.setMute(!muted) }; return nil
            default: return Unmanaged.passRetained(event)
            }
        }, userInfo: context)
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes); CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

@main
private struct MonitorVolumeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuController()
        app.delegate = delegate
        app.run()
    }
}
