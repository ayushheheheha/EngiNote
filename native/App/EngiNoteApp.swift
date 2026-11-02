import SwiftUI

@main
struct EngiNoteApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
        }
    }
}
