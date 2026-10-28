import SwiftUI

@main
struct NTFSEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("NTFS Editor", systemImage: "externaldrive") {
            MenuBarView(monitor: delegate.monitor, coordinator: delegate.coordinator, drivers: delegate.drivers)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = DiskMonitor()
    lazy var coordinator = MountCoordinator(operations: .live(monitor: monitor))
    let drivers = DriverAvailability.inspect()

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
}
