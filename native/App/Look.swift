import SwiftUI
import UIKit

// The look and the small helpers shared with the recorder app (recorder/project.yml compiles this file too):
// glass capsules, chips, the notice at the foot of the screen, presenting and sharing.

extension View {
    /// iPadOS 26's Liquid Glass where there is one, a blurred pane before that.
    func glass() -> some View { glass(Capsule()) }

    @ViewBuilder func glass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape).overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// A word in a capsule that is on or off (16:9, F, Mic, Auto…).
struct Chip: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1).padding(.horizontal, 10).frame(minWidth: 36, minHeight: 34)
            .foregroundStyle(on ? Color.white : .primary)
            .background(on ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08), in: Capsule())
    }
}

/// A short message at the foot of the screen (the web app's #message).
@MainActor
final class Notice: ObservableObject {
    static let shared = Notice()
    @Published var text: String?
    private var timer: Timer?

    func say(_ s: String) {
        text = s
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.text = nil }
        }
    }
}

extension UIApplication {
    /// The view controller in front, to present a share sheet, the video editor or Studio from.
    static var top: UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    static var window: UIWindow? {
        shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    static func share(_ files: [URL]) {
        guard let top, !files.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}
