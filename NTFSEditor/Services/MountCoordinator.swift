import AppKit
import Observation

// Closure injection keeps all simulated actions inside tests, away from production disk handles.
struct VolumeOperations {
    var current: (UUID) throws -> NTFSVolume
    var openInFinder: (UUID) async throws -> Void
    var unmount: (UUID) async throws -> Void
    var enableReadWrite: (UUID) async throws -> Void = { _ in throw VolumeActionError.unavailable }
    var readWriteBlockReason: () -> String? = { "讀寫整合尚未可用" }

    static func live(monitor: DiskMonitor) -> Self {
        Self(current: { try monitor.current($0) }, openInFinder: { id in
            let volume = try monitor.current(id)
            guard let url = volume.mountURL else { throw VolumeActionError.notMounted }
            guard volume.state != .unknown else { throw VolumeActionError.stateNotConfirmed }
            guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) else {
                throw VolumeActionError.finderFailed
            }
        }, unmount: { try await monitor.unmount($0) }, enableReadWrite: { id in
            try await AdminMountClient.enable(monitor.current(id))
            _ = try monitor.current(id)
        }, readWriteBlockReason: { AdminMountClient.unavailableReason })
    }
}

@Observable @MainActor
final class MountCoordinator {
    enum Action { case finder, unmount, enableReadWrite }
    private(set) var busyIDs: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var lastError: String?
    @ObservationIgnored private let operations: VolumeOperations

    init(operations: VolumeOperations) { self.operations = operations }

    var readWriteBlockReason: String? { operations.readWriteBlockReason() }

    func perform(_ action: Action, on id: UUID) async {
        guard !busyIDs.contains(id) else { return }
        busyIDs.insert(id)
        errors[id] = nil
        lastError = nil
        defer { busyIDs.remove(id) }
        do {
            let volume = try operations.current(id)
            if action != .enableReadWrite, volume.mountURL == nil { throw VolumeActionError.notMounted }
            switch action {
            case .finder: try await operations.openInFinder(id)
            case .unmount: try await operations.unmount(id)
            case .enableReadWrite: try await operations.enableReadWrite(id)
            }
        } catch {
            let message = error.localizedDescription
            errors[id] = message
            // Survives row removal, so unplugging during an action does not hide the failure.
            lastError = message
        }
    }

    func dismissError() { lastError = nil; errors.removeAll() }

    func enableReadWrite(on id: UUID) async {
        await perform(.enableReadWrite, on: id)
    }
}
