import AppKit
import SwiftUI
import CoreAudio

final class AudioModel: ObservableObject {
    @Published var sources: [AudioSource] = []
    @Published var devices: [OutputDevice] = []
    @Published var selections: [String: String] = [:]
    @Published var busy: Set<String> = []
    @Published var waiting: Set<String> = []
    @Published var message: String?
    @Published var showInactive = false
    @Published var defaultName = "System output"
    @Published var quitting = false
    private let queue = DispatchQueue(label: "local.audioroute.control", qos: .userInitiated)
    private var routes: [String: Route] = [:] // control queue only
    private var routeProcesses: [String: [AudioObjectID]] = [:] // main queue only
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var scheduled: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?

    var visibleSources: [AudioSource] { sources.filter { showInactive || $0.active || selections[$0.id] != nil || busy.contains($0.id) } }
    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetAll(note: "Routing stopped for sleep. Choose outputs again after waking.")
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkHealth() }
        healthTimer?.tolerance = 1
    }
    func refresh() {
        guard !quitting else { return }
        let fresh = AudioSource.discover()
        let outputs = OutputDevice.discover()
        let defaultID = HAL.defaultOutput()
        defaultName = outputs.first(where: { $0.id == defaultID })?.name ?? "System output"
        // Keep a routed row visible if its source temporarily disappears.
        let retained = sources.filter { old in selections[old.id] != nil && !fresh.contains(where: { $0.id == old.id }) }
        sources = fresh + retained
        devices = outputs
        if outputs.isEmpty && message == nil {
            message = "No audio outputs are visible. Launch AudioRoute.app directly on your Mac and connect an output device."
        }
        for (id, uid) in selections where !busy.contains(id) {
            guard let source = fresh.first(where: { $0.id == id }), let output = outputs.first(where: { $0.uid == uid }) else {
                stop(id, note: "A source or output disconnected. Its route was released; macOS controls its playback again.")
                continue
            }
            if routeProcesses[id]?.sorted() != source.processes.sorted() { choose(source, uid: output.uid) }
        }
        installListeners()
    }
    private func scheduleRefresh() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func installListeners() {
        removeListeners()
        func watch(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, reset: Bool = false) {
            var address = HAL.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.quitting else { return }
                if reset && (!self.selections.isEmpty || !self.busy.isEmpty) { self.resetAll(note: "The audio configuration changed. Choose outputs again to resume routing.") }
                self.scheduleRefresh()
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { listeners.append((id, address, block)) }
        }
        watch(HAL.system, kAudioHardwarePropertyProcessObjectList)
        watch(HAL.system, kAudioHardwarePropertyDevices)
        watch(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, reset: true)
        for source in sources { for id in source.processes { watch(id, kAudioProcessPropertyIsRunningOutput) } }
        for device in devices { watch(device.id, kAudioDevicePropertyNominalSampleRate, reset: true) }
    }
    private func removeListeners() {
        for (id, property, block) in listeners {
            var address = property
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        listeners.removeAll()
    }
    func choose(_ source: AudioSource, uid: String) {
        guard !busy.contains(source.id), !quitting else { return }
        if uid.isEmpty { stop(source.id); return }
        guard let output = devices.first(where: { $0.uid == uid }) else { return }
        message = nil
        busy.insert(source.id)
        queue.async { [self] in
            routes.removeValue(forKey: source.id)?.stop()
            var failure: String?
            do { routes[source.id] = try Route(source: source, output: output) }
            catch { failure = error.localizedDescription }
            let result = failure
            DispatchQueue.main.async { [self] in
                guard !quitting else { return }
                busy.remove(source.id)
                if let result {
                    selections.removeValue(forKey: source.id)
                    routeProcesses.removeValue(forKey: source.id)
                    waiting.remove(source.id)
                    message = result
                } else {
                    selections[source.id] = output.uid
                    routeProcesses[source.id] = source.processes
                    waiting.insert(source.id)
                }
            }
        }
    }
    func stop(_ id: String, note: String? = nil) {
        guard !busy.contains(id), !quitting else { return }
        busy.insert(id)
        queue.async { [self] in
            routes.removeValue(forKey: id)?.stop()
            DispatchQueue.main.async { [self] in
                selections.removeValue(forKey: id)
                routeProcesses.removeValue(forKey: id)
                busy.remove(id)
                waiting.remove(id)
                if let note { message = note }
                scheduleRefresh()
            }
        }
    }
    func resetAll(note: String? = nil) {
        // Serialize behind any in-flight start; its completion precedes this completion.
        queue.async { [self] in
            for route in routes.values { route.stop() }
            routes.removeAll()
            DispatchQueue.main.async { [self] in
                selections.removeAll(); routeProcesses.removeAll(); busy.removeAll(); waiting.removeAll()
                message = note
            }
        }
    }
    private func checkHealth() {
        guard !quitting, !selections.isEmpty else { return }
        queue.async { [self] in
            let silent = routes.values.filter { route in
                guard let state = route.render else { return true }
                return ARAudibleCount(state) == 0
            }
            let waitingIDs = Set(silent.map { $0.source.id })
            let names = silent.filter { Date().timeIntervalSince($0.createdAt) > 9 }.map { $0.source.name }
            DispatchQueue.main.async { [self] in
                guard !quitting else { return }
                waiting = waitingIDs.intersection(Set(selections.keys))
                if !names.isEmpty && message == nil { message = "No audio received from \(names.joined(separator: ", ")) yet. If playback is already running, check System Audio Recording permission, or select System Default to release the route." }
            }
        }
    }
    func shutdown(_ completion: @escaping () -> Void) {
        quitting = true
        scheduled?.cancel()
        healthTimer?.invalidate()
        removeListeners()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        queue.async { [self] in
            for route in routes.values { route.stop() }
            routes.removeAll()
            DispatchQueue.main.async(execute: completion)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AudioModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio Outputs").font(.headline)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh apps and outputs")
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2")
                Text(model.defaultName).lineLimit(1)
                Spacer()
                Text("System default").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    if model.visibleSources.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(.secondary)
                            Text("No active audio apps").font(.system(size: 13, weight: .medium))
                            Text("Play something in Safari, a game, or another app to choose its output.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 40)
                    } else {
                        ForEach(model.visibleSources) { source in
                            HStack(spacing: 10) {
                                if let icon = source.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                                else { Image(systemName: "app.dashed").font(.system(size: 25)).frame(width: 28, height: 28).foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(model.busy.contains(source.id) ? "Connecting…" : (model.selections[source.id] != nil ? (model.waiting.contains(source.id) ? "Waiting for audio" : "Routed") : (source.active ? "Audio active" : "Idle")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                Picker("Output for \(source.name)", selection: Binding(get: { model.selections[source.id] ?? "" }, set: { model.choose(source, uid: $0) })) {
                                    Text("System Default").tag("")
                                    Divider()
                                    ForEach(model.devices) { device in
                                        Text(device.name + (device.channels < 2 ? " (mono unsupported)" : "")).tag(device.uid).disabled(device.channels < 2)
                                    }
                                }.labelsHidden().frame(width: 162).disabled(model.busy.contains(source.id) || model.quitting)
                            }.padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }.padding(.vertical, 6)
            }.frame(height: 246)
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.foregroundStyle(.secondary).padding(12).background(.quaternary.opacity(0.3))
            }
            Divider()
            HStack {
                Toggle("Show idle apps", isOn: $model.showInactive).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Menu {
                    Button("Reset All Outputs") { model.resetAll() }.disabled(model.selections.isEmpty)
                    Button("Audio Permission Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Divider()
                    Text("AudioRoute · Proof of concept")
                    Text("Stereo audio · Session-only routes")
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 23).help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").disabled(model.quitting)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: 400)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var status: NSStatusItem!
    var popover: NSPopover!
    var model: AudioModel!
    var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AudioModel()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "AudioRoute")
        status.button?.image?.isTemplate = true
        status.button?.toolTip = "AudioRoute — app audio outputs"
        status.button?.target = self
        status.button?.action = #selector(toggle)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))
        popover.delegate = self
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.toggle() } }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }
    @objc func toggle() {
        guard let button = status.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let show = menu.addItem(withTitle: "Audio Outputs", action: #selector(showPanel), keyEquivalent: "")
            show.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit AudioRoute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            status.menu = menu
            button.performClick(nil)
            status.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }
    @objc func showPanel() {
        guard let button = status.button else { return }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        popover?.performClose(nil)
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct AudioRouteMain {
    static func main() {
        if CommandLine.arguments.contains("--inventory") {
            let devices = OutputDevice.discover()
            if devices.isEmpty { print("No output devices are visible to this process. Sandboxed development tools may not have access to Core Audio; launch AudioRoute.app directly.") }
            for device in devices { print("OUTPUT \(device.id) | \(device.name) | \(device.channels) channels | \(device.uid)") }
            for source in AudioSource.discover() { print("SOURCE \(source.id) | \(source.name) | active=\(source.active) | objects=\(source.processes)") }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
