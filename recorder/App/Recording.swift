import AVFoundation
import ReplayKit
import SwiftUI

/// Recording the whole iPad: Record opens iPadOS's broadcast sheet; once Start Broadcast is tapped the extension
/// records the screen, this app the voice; Stop (here, the red pill at the top of the screen or Control Center) ends
/// it, and the two halves are joined into one movie, then given the intro and outro and shrunk if those are on.
@MainActor
final class Recording: ObservableObject {
    static let shared = Recording()
    let recorder = Recorder()
    let bubble = Bubble()

    enum State { case idle, arming, live, paused, saving }
    @Published var state = State.idle
    @Published var seconds = 0.0
    @Published var levels: [Double] = []
    @Published var checking = false
    @Published var introAt: Double?
    @Published var saving = ""
    @Published var list = 0 // changes when the recordings do: the list is drawn again

    static let defaults: [String: Any] = [
        "recMic": true, "recEnhance": false, "recQuality": "standard", "recWrap": false,
        "recAppSound": true, "recWide": false, "recShrink": false, "recBubble": "clock",
    ]

    weak var picker: RPSystemBroadcastPickerView?
    private var id: String?
    private var startedAt = 0.0
    private var pauses = Pauses()
    private var ticker: Timer?
    private var sweeping = false
    private var d: UserDefaults { .standard }
    private var enhance: Bool { d.bool(forKey: "recEnhance") }

    private init() {
        UserDefaults.standard.register(defaults: Recording.defaults)
        recorder.onLevels = { [weak self] heard in
            MainActor.assumeIsolated { if let self { self.levels = Array((self.levels + heard).suffix(24)) } }
        }
        bubble.setPaused = { [weak self] p in MainActor.assumeIsolated { if let self, p != (self.state == .paused) { self.pauseTapped() } } }
        bubble.onProblem = { why in MainActor.assumeIsolated { Notice.shared.say(why) } }
        Shared.observe("started") { [weak self] in MainActor.assumeIsolated { self?.started() } }
        Shared.observe("ended") { [weak self] in MainActor.assumeIsolated { self?.ended() } }
        // The extension may die without saying so: when the screen stops being recorded, end ours too.
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStillRecorded() }
        }
        // Opened while a recording is running (the app was closed, or it was started from Control Center).
        if UIScreen.main.isCaptured, Shared.defaults?.string(forKey: "live") != nil { started() }
        Task { await sweep() }
    }

    // MARK: record, pause, stop

    func record() {
        guard state == .idle else { return }
        guard Shared.group != nil else {
            return Notice.shared.say("The recorder's shared folder is missing, so it cannot record. Install it again with the updater.")
        }
        let shared = Shared.defaults
        shared?.set(d.string(forKey: "recQuality"), forKey: "quality")
        shared?.set(d.bool(forKey: "recWide"), forKey: "wide")
        shared?.set(d.bool(forKey: "recAppSound"), forKey: "appSound")
        state = .arming
        Task {
            var mic = d.bool(forKey: "recMic")
            if mic, !(await AVAudioApplication.requestRecordPermission()) {
                mic = false
                Notice.shared.say("The microphone is not allowed (Settings > EngiNote Recorder): recording without your voice.")
            }
            do {
                try recorder.listen(mic: mic, enhanced: enhance)
            } catch {
                Notice.shared.say("The microphone could not be started (\(error.localizedDescription)). Switch it on in the broadcast sheet instead.")
                try? recorder.listen(mic: false, enhanced: false)
            }
            let look = d.string(forKey: "recBubble") ?? "off"
            bubble.enable(look != "off")
            bubble.camera(look == "camera")
            startTicking()
            openSheet()
        }
    }

    /// iPadOS's broadcast sheet, with this app's extension chosen: the user taps Start Broadcast there.
    private func openSheet() {
        func buttons(_ v: UIView) -> [UIButton] { v.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons($0) } }
        guard let picker, let button = buttons(picker).first else {
            return Notice.shared.say("The broadcast sheet could not be opened. Start from Control Center: hold Screen Recording and choose EngiNote Recorder.")
        }
        button.sendActions(for: .touchUpInside)
    }

    func cancel() {
        guard state == .arming else { return }
        state = .idle
        quiet()
    }

    /// The extension has begun.
    private func started() {
        guard state == .idle || state == .arming else { return }
        id = Shared.defaults?.string(forKey: "live")
        startedAt = CACurrentMediaTime()
        pauses = Pauses()
        introAt = nil
        seconds = 0
        state = .live
        UIApplication.shared.isIdleTimerDisabled = true
        if recorder.hearing, let id {
            do { try recorder.open(id) } catch { Notice.shared.say("Your voice could not be recorded: \(error.localizedDescription).") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.state == .live, self.recorder.hearing, !self.recorder.heardSomething else { return }
                Notice.shared.say("Warning: no sound is being recorded. Stop and start again; if it stays silent, switch Enhance the other way.")
            }
        }
        startTicking()
        bubble.refresh()
    }

    func pauseTapped() {
        let now = CACurrentMediaTime()
        if state == .live {
            pauses.since = now
            state = .paused
        } else if state == .paused, let since = pauses.since {
            pauses.spans.append([since, now])
            pauses.since = nil
            state = .live
        } else { return }
        pauses.save(Shared.defaults)
        recorder.setPauses(pauses)
        Shared.post("pause")
        tick()
        bubble.refresh()
    }

    /// While paused: the intro goes into the video at this point.
    func introHere() { introAt = introAt == nil ? seconds : nil }

    func stop() {
        guard state == .live || state == .paused else { return }
        Shared.post("stop")
        // No answer (the extension is gone): end here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.checkStillRecorded() }
    }

    private func checkStillRecorded() {
        guard state == .live || state == .paused, !UIScreen.main.isCaptured else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in   // give the extension's own "ended" time to come
            guard let self, self.state == .live || self.state == .paused, !UIScreen.main.isCaptured else { return }
            self.ended()
        }
    }

    /// The extension has finished its movie: finish the voice, join them.
    private func ended() {
        guard state == .live || state == .paused else { return }
        state = .saving
        saving = "Saving…"
        UIApplication.shared.isIdleTimerDisabled = false
        let id = self.id, wrap = introAt != nil || d.bool(forKey: "recWrap"), at = introAt, shrink = d.bool(forKey: "recShrink")
        Task {
            var part = await recorder.close() ?? Part()
            part.introAt = at
            part.wrap = wrap
            part.shrink = shrink
            if let id { part.save(id, "voice") }
            state = .idle   // so the sweep below is allowed to run; the app keeps playing until it is done
            await sweep()
            if state == .idle { quiet() }
        }
    }

    /// Let go of the microphone (unless the mic check wants it), the camera and the bubble.
    private func quiet() {
        ticker?.invalidate()
        ticker = nil
        Shared.defaults?.removeObject(forKey: "voiceBeat")
        if !checking { recorder.stopListening() }
        bubble.camera(false)
        bubble.enable(false)
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        tick()
    }

    private func tick() {
        if recorder.hearing { Shared.defaults?.set(Date().timeIntervalSince1970, forKey: "voiceBeat") }
        if state == .live || state == .paused {
            let now = CACurrentMediaTime()
            seconds = max(0, now - startedAt - pauses.total(at: now))
        }
        bubble.paused = state == .paused
        bubble.clockText = Recording.clock(seconds)
    }

    // MARK: joining

    /// Join every recording whose halves are waiting: the one just ended, and any a crash or a closed app left behind.
    func sweep() async {
        guard !sweeping, let raw = Shared.folder else { return }
        sweeping = true
        defer { sweeping = false }
        while true {
            let running = UIScreen.main.isCaptured ? Shared.defaults?.string(forKey: "live") : nil
            let names = (try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []
            let waiting = names.filter { $0.hasSuffix(".screen.mov") }.map { String($0.dropLast(".screen.mov".count)) }.filter { $0 != running && $0 != (state == .idle ? nil : id) }
            guard let next = waiting.sorted().first else { break }
            await finish(next)
        }
    }

    private func finish(_ id: String) async {
        guard let raw = Shared.folder, let docs = try? Recorder.folder() else { return }
        let movie = docs.appendingPathComponent("\(id).mov")
        let part = Part.load(id, "voice") ?? Part()
        let halves = ["screen.mov", "voice.mov", "screen.json", "voice.json"].map { raw.appendingPathComponent("\(id).\($0)") }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        recorder.activeFile = movie
        saving = "Saving \(id)…"
        list += 1
        do {
            try await Joiner.join(id, into: movie)
            halves.forEach { try? FileManager.default.removeItem(at: $0) }
            recorder.activeFile = nil
            list += 1
            var said = "Saved \(id). It is in Recordings, and in Files."
            if part.wrap {
                saving = "Adding the intro and outro…"
                said = await Recording.wrap(movie, add: true, introAt: part.introAt ?? 0)
            }
            if part.shrink {
                saving = "Shrinking…"
                said = await Task.detached(priority: .userInitiated) { () -> String in
                    guard let o = try? await StudioShrink.shrink(movie) else { return "Saved; it could not be shrunk." }
                    return o.shrunk ? "Saved and shrunk, \(100 - o.after * 100 / max(1, o.before))% smaller." : "Saved; not shrunk: \(o.why ?? "nothing to gain")."
                }.value
            }
            Notice.shared.say(said)
        } catch {
            // Never lose a recording to a join that fails: put both halves where the user can reach them, as they are.
            try? FileManager.default.removeItem(at: movie)
            try? FileManager.default.moveItem(at: halves[0], to: docs.appendingPathComponent("\(id) (screen).mov"))
            try? FileManager.default.moveItem(at: halves[1], to: docs.appendingPathComponent("\(id) (voice).mov"))
            halves.forEach { try? FileManager.default.removeItem(at: $0) }
            Notice.shared.say("The voice and the screen could not be joined (\(error.localizedDescription)). Both are in Recordings as they were recorded.")
        }
        recorder.activeFile = nil
        saving = ""
        list += 1
    }

    /// Put the intro and outro on a recording, or take them off (StudioWrap: a copy of the file, so it is quick).
    /// The same as the EngiNote Native app's (native/App/Recording.swift), which the recordings list calls by this name.
    static func wrap(_ file: URL, add: Bool, introAt: Double = 0) async -> String {
        let intro = Bundle.main.url(forResource: "studio-intro", withExtension: "mp4")
        let outro = Bundle.main.url(forResource: "studio-outro", withExtension: "mp4")
        return await Task.detached(priority: .userInitiated) {
            do {
                if add { try await StudioWrap.add(to: file, intro: intro, outro: outro, introAt: introAt) } else { try await StudioWrap.remove(from: file) }
                return add ? "Intro and outro added." : "Intro and outro removed."
            } catch {
                return "The intro and outro could not be \(add ? "added" : "removed"): \(error.localizedDescription). The recording is as it was."
            }
        }.value
    }

    // MARK: mic check, room

    func toggleCheck() {
        checking.toggle()
        levels = []
        recorder.checking = checking
        if checking {
            Task {
                guard await AVAudioApplication.requestRecordPermission() else {
                    checking = false
                    return Notice.shared.say("The microphone is not allowed: Settings > EngiNote Recorder > Microphone.")
                }
                if state == .idle { try? recorder.listen(mic: true, enhanced: enhance) }
            }
        } else if state == .idle {
            recorder.stopListening()
        }
    }

    /// Hours of room at the chosen quality, and the battery.
    var room: (hours: Double, battery: Float, charging: Bool) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let rate = Shared.qualities[d.string(forKey: "recQuality") ?? "standard"]?.bitRate ?? 7_000_000
        // Twice the room while recording: the two halves, then the joined movie, until the halves are deleted.
        let hours = free.map { Double($0) / (Double(rate) / 8 * 3600) / 2 } ?? -1
        return (hours, device.batteryLevel, device.batteryState == .charging || device.batteryState == .full)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
