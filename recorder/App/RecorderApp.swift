import ReplayKit
import SwiftUI

@main
struct RecorderApp: App {
    var body: some Scene {
        WindowGroup { Home() }
    }
}

/// The record panel over the recordings (the EngiNote Native app's own list: play, trim and cut, Studio, intro and
/// outro, shrink, share, the bin).
struct Home: View {
    @ObservedObject private var rec = Recording.shared
    @ObservedObject private var notice = Notice.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            RecordingsView()
                .id(rec.list)
                .safeAreaInset(edge: .top) { Panel().padding(.horizontal, 20).padding(.top, 6) }
        }
        .overlay(alignment: .bottom) {
            if let text = notice.text {
                Text(text).font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glass(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 30).padding(.bottom, 80)
                    .onTapGesture { notice.text = nil }
            }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await rec.sweep() } }
        }
    }
}

struct Panel: View {
    @ObservedObject private var rec = Recording.shared
    @AppStorage("recMic") private var mic = true
    @AppStorage("recEnhance") private var enhance = false
    @AppStorage("recAppSound") private var appSound = true
    @AppStorage("recWide") private var wide = false
    @AppStorage("recWrap") private var wrap = false
    @AppStorage("recShrink") private var shrink = false
    @AppStorage("recBubble") private var bubble = "clock"
    @AppStorage("recQuality") private var quality = "standard"

    private let qualities = [("high", "High 1080p · 6.3 GB/h"), ("standard", "Standard 1080p · 3.2 GB/h"), ("small", "Small 720p · 1.4 GB/h")]
    private let bubbles = [("off", "No bubble"), ("clock", "Bubble: clock"), ("camera", "Bubble: camera")]
    private var live: Bool { rec.state == .live || rec.state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                controls
                Spacer(minLength: 0)
                if bubble != "off" {
                    BubbleView().frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("The bubble: it floats over other apps while recording; its pause button pauses the recording")
                }
                PickerHost().frame(width: 1, height: 1).opacity(0.02)
            }
            if rec.state == .idle, rec.saving.isEmpty { settings }
            Text(help).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .glass(RoundedRectangle(cornerRadius: 24))
        .tint(.primary)
    }

    @ViewBuilder private var controls: some View {
        if !rec.saving.isEmpty {
            ProgressView()
            Text(rec.saving).font(.callout)
        } else {
            switch rec.state {
            case .idle:
                Button { rec.record() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 14, height: 14)
                        Text("Record the iPad").font(.headline)
                    }
                    .padding(.horizontal, 8).frame(height: 40)
                }
                .buttonStyle(Chip())
            case .arming:
                Text("Tap Start Broadcast, then go to any app.").font(.callout)
                Button("Cancel") { rec.cancel() }.buttonStyle(Chip())
            case .live, .paused:
                Text(Recording.clock(rec.seconds)).monospacedDigit().font(.title3.weight(.semibold))
                    .foregroundStyle(rec.state == .live ? Color.red : .primary)
                Button(rec.state == .paused ? "Resume" : "Pause") { rec.pauseTapped() }.buttonStyle(Chip(on: rec.state == .paused))
                if rec.state == .paused {
                    Button(rec.introAt.map { "Intro at " + Recording.clock($0) } ?? "Intro here") { rec.introHere() }.buttonStyle(Chip(on: rec.introAt != nil))
                }
                Button { rec.stop() } label: {
                    HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 10, height: 10); Text("Stop") }
                }
                .buttonStyle(Chip(on: true))
            case .saving:
                ProgressView()
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Mic") { mic.toggle() }.buttonStyle(Chip(on: mic))
                    Button("Enhance") { enhance.toggle() }.buttonStyle(Chip(on: enhance && mic)).disabled(!mic)
                        .accessibilityLabel("Enhance: take the background noise out of your voice")
                    Button("App sound") { appSound.toggle() }.buttonStyle(Chip(on: appSound))
                        .accessibilityLabel("Record the sound apps play")
                    Button("16:9") { wide.toggle() }.buttonStyle(Chip(on: wide))
                        .accessibilityLabel("Keep only the 16:9 band across the middle of the screen")
                    Button("Intro") { wrap.toggle() }.buttonStyle(Chip(on: wrap))
                    Button("Shrink") { shrink.toggle() }.buttonStyle(Chip(on: shrink))
                        .accessibilityLabel("Shrink: make the recording again as HEVC, about half the size")
                    menu(bubbles, $bubble)
                    menu(qualities, $quality)
                    Button { rec.toggleCheck() } label: { Image(systemName: "waveform").frame(width: 36, height: 34) }
                        .buttonStyle(Chip(on: rec.checking)).accessibilityLabel("Mic check")
                    if rec.checking { Waves(levels: rec.levels) }
                }
            }
            let room = rec.room
            Text("Room for \(room.hours < 0 ? "?" : String(format: "%.1f", room.hours)) hours · battery \(room.battery < 0 ? "?" : "\(Int(room.battery * 100))%")\(room.charging ? ", charging" : "")")
                .font(.footnote)
                .foregroundStyle((room.hours >= 0 && room.hours < 1.5) || (room.battery >= 0 && room.battery < 0.3 && !room.charging) ? Color.red : .secondary)
        }
    }

    private func menu(_ choices: [(String, String)], _ value: Binding<String>) -> some View {
        Menu {
            Picker("", selection: value) { ForEach(choices, id: \.0) { Text($0.1).tag($0.0) } }
        } label: {
            HStack(spacing: 4) {
                Text(choices.first { $0.0 == value.wrappedValue }?.1.components(separatedBy: " ·").first ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.callout.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 34)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
    }

    private var help: String {
        switch rec.state {
        case .live, .paused:
            return "Stop here, with the red pill at the top of the screen, or in Control Center. The bubble's pause button pauses."
        default:
            return "Records everything on the iPad: any app, with your voice. iPadOS counts down 3, 2, 1 before it starts."
        }
    }
}

/// The mic check's picture: a row of bars that move with what the microphone hears (as in EngiNote).
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

/// iPadOS's broadcast button, with this app's extension chosen; Record presses it (Recording.openSheet).
struct PickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Shared.appID + ".broadcast"
        picker.showsMicrophoneButton = false // the app records the voice itself
        Recording.shared.picker = picker
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

/// The bubble's own view: the Picture-in-Picture window comes out of it, so it must be on the screen.
struct BubbleView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = Recording.shared.bubble.view
        DispatchQueue.main.async { Recording.shared.bubble.prepare() }
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
