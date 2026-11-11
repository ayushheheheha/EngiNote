import AVFoundation
import SwiftUI

/// Screen recording, the camera bubble and the mic check: the web-based app's own Recorder and CameraBubble,
/// driven from here instead of from a page.
@MainActor
final class Recording: ObservableObject {
    static let shared = Recording()
    let recorder = Recorder()
    let camera = CameraBubble()

    enum State { case idle, counting, recording, paused }
    @Published var state = State.idle
    @Published var count = 0                 // the countdown's number
    @Published var seconds = 0.0             // recorded so far
    @Published var levels: [Double] = []     // the mic check's waves
    @Published var checking = false
    @Published var cameraOn = false
    @Published var introAt: Double?          // "Intro here": where in the movie the intro goes
    @Published var asking = false            // the check before recording is showing
    @Published var busy = false

    /// Set by the editor: is the 16:9 window on, and the note's name (the movie's file name starts with it).
    var wide = false
    var title = ""

    private var ticker: Timer?
    private var counter: Timer?
    private var trace: [[Double]] = []
    private var ticks = 0

    private init() {
        recorder.onLevels = { [weak self] heard in
            MainActor.assumeIsolated { if let self { self.levels = Array((self.levels + heard).suffix(24)) } }
        }
        recorder.onFailure = { [weak self] why in MainActor.assumeIsolated { self?.stop(because: why) } }
        recorder.onCheckFailed = { [weak self] why in
            MainActor.assumeIsolated {
                self?.checking = false
                Notice.shared.say("Mic check: \(why)")
            }
        }
        camera.onNews = { [weak self] on, problem in
            MainActor.assumeIsolated {
                self?.cameraOn = on
                if let problem { Notice.shared.say(problem) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.camera.place() }
        }
    }

    private var d: UserDefaults { .standard }
    private var micOn: Bool { d.bool(forKey: "recMic") }
    private var enhance: Bool { micOn && d.bool(forKey: "recEnhance") }

    // MARK: record, pause, stop

    func recordTapped() {
        switch state {
        case .idle:
            if d.bool(forKey: "precheck") {
                asking = true
                if micOn, !checking { recorder.check(on: true, enhance: enhance) }
            } else { begin() }
        case .counting:
            counter?.invalidate()
            state = .idle
        default:
            stop(because: nil)
        }
    }

    func cancelAsking() {
        asking = false
        if !checking { recorder.check(on: false, enhance: enhance) }
    }

    /// The countdown (3, 2, 1: so the video does not begin with a hand leaving the screen), then the recording.
    func begin() {
        asking = false
        guard d.bool(forKey: "recCount") else { return start() }
        state = .counting
        count = 3
        counter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.state == .counting else { return t.invalidate() }
                self.count -= 1
                if self.count == 0 {
                    t.invalidate()
                    self.start()
                }
            }
        }
    }

    private func start() {
        state = .idle
        busy = true
        introAt = nil
        trace = []
        let mic = micOn
        recorder.start(quality: d.string(forKey: "recQuality") ?? "standard", wide: wide, microphone: mic, enhance: enhance, title: title) { [weak self] error, note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.busy = false
                if let error { return Notice.shared.say("Recording did not start: \(error)") }
                UIApplication.shared.isIdleTimerDisabled = true   // the screen must not lock in the middle of a lecture
                self.state = .recording
                self.seconds = 0
                if let note { Notice.shared.say(note) }
                self.ticker?.invalidate()
                self.ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
                guard mic else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.recorder.isActive, !self.recorder.isPaused, !self.recorder.hasSound else { return }
                    Notice.shared.say("Warning: no sound is being recorded. Stop and start again; if it stays silent, switch Enhance the other way.")
                }
            }
        }
    }

    private func tick() {
        seconds = recorder.writtenSeconds
        ticks += 1
        if ticks % 2 == 0 {   // Studio keeps the bubble still when it zooms: where it was, once a second
            if camera.isHidden { recorder.bubbleGone() } else { recorder.addBubble(camera.frame, radius: Double(camera.layer.cornerRadius)) }
            camera.superview?.bringSubviewToFront(camera)
        }
        if ticks % 8 == 0 { flushTrace() }
    }

    func pauseTapped() {
        guard recorder.isActive else { return }
        if state == .paused {
            recorder.resume()
            state = .recording
        } else {
            recorder.pause()
            state = .paused
            seconds = recorder.writtenSeconds
        }
    }

    /// While paused: the intro goes into the video at this very point.
    func introHere() { introAt = introAt == nil ? recorder.writtenSeconds : nil }

    private func stop(because problem: String?) {
        ticker?.invalidate()
        guard recorder.isActive else { state = .idle; return }
        flushTrace()
        busy = true
        let wrap = introAt != nil || d.bool(forKey: "recWrap"), at = introAt ?? 0
        var task = UIBackgroundTaskIdentifier.invalid   // finishing the file may outlast the app being in front
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        recorder.stop { [weak self] file, error in
            MainActor.assumeIsolated {
                UIApplication.shared.isIdleTimerDisabled = false
                guard let self else { return }
                self.state = .idle
                self.busy = false
                self.introAt = nil
                let trouble = problem ?? error
                if file == nil {
                    Notice.shared.say("Recording failed: \(trouble ?? "nothing was recorded").")
                } else if let trouble {
                    Notice.shared.say("Recording stopped: \(trouble). What was recorded is in Recordings.")
                } else {
                    Notice.shared.say(wrap ? "Recording saved. Adding the intro and outro: keep EngiNote open for a moment." : "Recording saved. It is in Recordings, and in Files.")
                }
                Task {
                    if wrap, let file { Notice.shared.say(await Recording.wrap(file, add: true, introAt: at)) }
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    if let file, UIApplication.shared.applicationState == .active { UIApplication.share([file]) }
                }
            }
        }
    }

    /// Put the intro and outro on a recording, or take them off (StudioWrap: a copy of the file, so it is quick).
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

    // MARK: the pen's path, for Studio's auto-zoom

    /// The part of the screen the video is a picture of: the 16:9 band across the middle if lecture mode is on, else all of it.
    private var box: CGRect {
        let all = UIApplication.window?.bounds ?? .zero
        guard wide else { return all }
        let h = all.width * 9 / 16
        return CGRect(x: 0, y: (all.height - h) / 2, width: all.width, height: h)
    }

    func pen(at p: CGPoint, down: Bool) {
        guard state == .recording else { return }
        let b = box
        guard b.width > 0, b.height > 0 else { return }
        let u = min(1, max(0, (p.x - b.minX) / b.width)), v = min(1, max(0, (p.y - b.minY) / b.height))
        trace.append([Sidecar.now(), (u * 1000).rounded() / 1000, (v * 1000).rounded() / 1000, down ? 1 : 0])
    }

    private func flushTrace() {
        let b = box
        recorder.addTrace(points: trace, window: [b.minX, b.minY, b.width, b.height])
        trace = []
    }

    // MARK: camera bubble, mic check

    func setCamera(_ on: Bool) {
        if camera.superview == nil, let w = UIApplication.window {
            w.addSubview(camera)
            camera.place()
        }
        camera.superview?.bringSubviewToFront(camera)
        if on { camera.turnOn() } else { camera.turnOff() }
    }

    func nextShape() {
        let all = CameraBubble.shapes
        camera.reshape(all[((all.firstIndex(of: camera.shape) ?? 0) + 1) % all.count])
        objectWillChange.send()
    }

    func toggleCheck() {
        checking.toggle()
        levels = []
        recorder.check(on: checking, enhance: enhance)
    }

    /// The app left the screen, or came back.
    func away(_ gone: Bool) {
        recorder.leftScreen(gone)
        if !gone { camera.wake(); camera.place() }
    }

    /// For the check before recording: hours of room at the chosen quality, and the battery.
    var room: (hours: Double, battery: Float, charging: Bool) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let rate = Recorder.qualities[d.string(forKey: "recQuality") ?? "standard"]?.bitRate ?? 7_000_000
        let hours = free.map { Double($0) / (Double(rate) / 8 * 3600) } ?? -1
        return (hours, device.batteryLevel, device.batteryState == .charging || device.batteryState == .full)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// The mic check's picture: a row of bars that move with what the microphone hears.
struct Waves: View {
    let levels: [Double]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<24, id: \.self) { i in
                let v = i < levels.count ? levels[i] : 0
                Capsule().fill(Color.green).frame(width: 2.5, height: max(2, 26 * min(1, v * 3)))
            }
        }
        .frame(width: 110, height: 28)
    }
}

/// The recording bar. With the 16:9 window on it sits in the black band under it, never in the picture.
struct RecBar: View {
    @ObservedObject var rec = Recording.shared
    @AppStorage("recMin") private var small = false
    @AppStorage("recCount") private var countdown = true
    @AppStorage("recMic") private var mic = true
    @AppStorage("recEnhance") private var enhance = false
    @AppStorage("recWrap") private var wrap = false
    @AppStorage("recQuality") private var quality = "standard"

    private let qualities = [("high", "High 1080p 60 · 6.3 GB/h"), ("standard", "Standard 1080p 60 · 3.2 GB/h"), ("small", "Small 720p 60 · 1.4 GB/h")]
    private var live: Bool { rec.state == .recording || rec.state == .paused }

    var body: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.spring(duration: 0.35)) { small.toggle() } } label: {
                if small { Circle().fill(.red).frame(width: 14, height: 14).frame(width: 36, height: 36) } else { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
            }
            .accessibilityLabel(small ? "Open the recording bar" : "Put the recording bar away")
            if live || !small {
                Text(Recording.clock(rec.seconds)).monospacedDigit().font(.callout)
                    .foregroundStyle(rec.state == .recording ? Color.red : .primary)
            }
            if !small {
                Button { rec.recordTapped() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(rec.state == .idle ? "Record" : rec.state == .counting ? "Cancel" : "Stop")
                    }
                }
                .buttonStyle(Chip(on: live))
                .disabled(rec.busy)
                if live {
                    Button(rec.state == .paused ? "Resume" : "Pause") { rec.pauseTapped() }.buttonStyle(Chip(on: rec.state == .paused))
                }
                if rec.state == .paused {
                    Button(rec.introAt.map { "Intro at " + Recording.clock($0) } ?? "Intro here") { rec.introHere() }.buttonStyle(Chip(on: rec.introAt != nil))
                }
                if !live {
                    Button("3s") { countdown.toggle() }.buttonStyle(Chip(on: countdown)).accessibilityLabel("Count down before recording")
                    Button("Mic") { mic.toggle() }.buttonStyle(Chip(on: mic))
                    Button("Enhance") { enhance.toggle() }.buttonStyle(Chip(on: enhance && mic)).disabled(!mic)
                    Button("Intro") { wrap.toggle() }.buttonStyle(Chip(on: wrap))
                }
                Button { rec.toggleCheck() } label: { Image(systemName: "waveform").frame(width: 36, height: 36) }
                    .foregroundStyle(rec.checking ? Color.accentColor : .primary)
                    .accessibilityLabel("Mic check")
                if rec.checking { Waves(levels: rec.levels) }
                Button { rec.setCamera(!rec.cameraOn) } label: { Image(systemName: rec.cameraOn ? "video.fill" : "video").frame(width: 36, height: 36) }
                    .foregroundStyle(rec.cameraOn ? Color.accentColor : .primary)
                    .accessibilityLabel("Camera bubble")
                if rec.cameraOn {
                    Button { rec.nextShape() } label: {
                        Image(systemName: ["circle": "circle", "square": "square", "wide": "rectangle", "tall": "rectangle.portrait"][rec.camera.shape] ?? "circle").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Change the shape of the camera bubble")
                }
                if !live {
                    Menu {
                        Picker("Quality", selection: $quality) { ForEach(qualities, id: \.0) { Text($0.1).tag($0.0) } }
                    } label: {
                        Text(qualities.first { $0.0 == quality }?.1.components(separatedBy: " ").first ?? "Standard").font(.callout)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .tint(.primary)
        .padding(.horizontal, 8)
        .frame(height: 52)
        .glass()
    }
}

/// The check before recording: the microphone, the room left on the iPad and the battery, then Start.
struct Precheck: View {
    @ObservedObject var rec = Recording.shared
    @AppStorage("recMic") private var mic = true

    var body: some View {
        let room = rec.room
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { rec.cancelAsking() }
            VStack(alignment: .leading, spacing: 14) {
                Text("Ready to record?").font(.title3.bold())
                row("Microphone") { if mic { Waves(levels: rec.levels) } else { Text("Off").bold() } }
                row("Room") {
                    Text(room.hours < 0 ? "Not known" : String(format: "%.1f hours at this quality", room.hours)).bold()
                        .foregroundStyle(room.hours >= 0 && room.hours < 1.5 ? Color.red : .primary)
                }
                row("Battery") {
                    Text(room.battery < 0 ? "Not known" : "\(Int(room.battery * 100))%\(room.charging ? ", charging" : "")").bold()
                        .foregroundStyle(room.battery >= 0 && room.battery < 0.3 && !room.charging ? Color.red : .primary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { rec.cancelAsking() }.buttonStyle(.bordered)
                    Button("Start") { rec.begin() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func row(_ name: String, @ViewBuilder _ value: () -> some View) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            value()
        }
    }
}
