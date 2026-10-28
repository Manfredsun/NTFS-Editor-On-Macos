import Testing
import Foundation
import SwiftUI
import AppKit
import DiskArbitration
@testable import NTFSEditor

@MainActor
private func sample(_ registry: UInt64 = 1, bsd: String = "disk91s1", kind: String? = "ntfs",
                    state: NTFSVolume.MountState = .readOnly, name: String = "Test SSD") -> DiskSnapshot {
    DiskSnapshot(registryID: registry, bsdName: bsd, fileSystem: kind, isExternal: true,
                 volumeUUID: "volume-\(registry)", mediaUUID: "media-\(registry)", name: name,
                 capacity: 1_000_000_000_000,
                 mountURL: state == .unmounted ? nil : URL(fileURLWithPath: "/Volumes/Test-\(registry)"), state: state)
}

@Suite @MainActor
struct DiskMonitorTests {
    @Test func excludesExFATAndPartitionTypeGuessing() {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample(kind: "exfat", name: "NTFS SSD"))
        monitor.apply(sample(2, bsd: "disk92s1", kind: nil))
        monitor.apply(sample(3, bsd: "disk93s1", kind: "fuse"))
        #expect(monitor.volumes.isEmpty)
    }

    @Test func excludesInternalVolumes() {
        let monitor = DiskMonitor(startMonitoring: false)
        var disk = sample()
        disk.isExternal = false
        monitor.apply(disk)
        #expect(monitor.volumes.isEmpty)
    }

    @Test(arguments: NTFSVolume.MountState.allCases)
    func preservesActualState(_ state: NTFSVolume.MountState) throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample(state: state))
        let volume = try #require(monitor.volumes.first)
        #expect(volume.state == state)
        #expect((volume.mountURL == nil) == (state == .unmounted))
    }

    @Test func multipleSameNameVolumesRemainIndependent() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        monitor.apply(sample(2, bsd: "disk92s1"))
        #expect(monitor.volumes.count == 2)
        #expect(Set(monitor.volumes.map(\.id)).count == 2)
        monitor.remove(registryID: 1)
        #expect(monitor.volumes.map(\.bsdName) == ["disk92s1"])
    }

    @Test func mountChangesKeepConnectionIdentity() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        let id = try #require(monitor.volumes.first?.id)
        monitor.apply(sample(state: .readWrite))
        #expect(monitor.volumes.first?.id == id)
        #expect(monitor.volumes.first?.state == .readWrite)
        monitor.apply(sample(kind: nil, state: .unmounted))
        #expect(monitor.volumes.first?.state == .unmounted)
        #expect(monitor.volumes.first?.id == id)
    }

    @Test func transitionalManagedMountPreservesIdentityAndNameBeforeRecordEnrichment() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample(name: "新增磁碟區"))
        let id = try #require(monitor.volumes.first?.id)

        var unmounted = sample(kind: nil, state: .unmounted, name: "新增磁碟區")
        unmounted.volumeUUID = nil
        monitor.apply(unmounted)
        #expect(monitor.volumes.first?.id == id)
        #expect(monitor.volumes.first?.state == .unmounted)

        var transitional = sample(kind: "macfuse", state: .readWrite, name: "macFUSE Volume 0 (ntfs-3g)")
        transitional.volumeUUID = nil
        transitional.mountURL = URL(fileURLWithPath: "/Volumes/NTFSEditor-test")
        monitor.apply(transitional)
        #expect(monitor.volumes.count == 1)
        #expect(monitor.volumes.first?.id == id)
        #expect(monitor.volumes.first?.name == "新增磁碟區")
        #expect(monitor.volumes.first?.state == .unknown)

        var enriched = sample(kind: "ntfs", state: .readWrite, name: "新增磁碟區")
        enriched.mountURL = URL(fileURLWithPath: "/Volumes/NTFSEditor-test")
        monitor.apply(enriched)
        #expect(monitor.volumes.first?.id == id)
        #expect(monitor.volumes.first?.name == "新增磁碟區")
        #expect(monitor.volumes.first?.state == .readWrite)
    }

    @Test func bsdReuseAndLateRemovalCannotRemoveReplacement() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        let oldID = try #require(monitor.volumes.first?.id)
        monitor.apply(sample(2)) // same BSD name, different IOMedia instance
        let newID = try #require(monitor.volumes.first?.id)
        #expect(newID != oldID)
        monitor.remove(registryID: 1) // late disappearance of old instance
        monitor.apply(sample(state: .readWrite)) // late description from retired instance
        #expect(monitor.volumes.first?.id == newID)
        #expect(monitor.volumes.first?.state == .readOnly)
    }

    @Test func removedAndReinsertedSameMediaGetsNewToken() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        let oldID = try #require(monitor.volumes.first?.id)
        monitor.remove(registryID: 1)
        var reinserted = sample(2)
        reinserted.volumeUUID = "volume-1"
        reinserted.mediaUUID = "media-1"
        monitor.apply(reinserted)
        #expect(monitor.volumes.first?.id != oldID)
    }

    @Test func exfatReplacementClearsOldNTFSRow() {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        monitor.apply(sample(2, kind: "exfat"))
        monitor.apply(sample())
        #expect(monitor.volumes.isEmpty)
    }

    @Test func changedUUIDInvalidatesOldSelection() throws {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        let oldID = try #require(monitor.volumes.first?.id)
        var changed = sample()
        changed.volumeUUID = "replacement"
        monitor.apply(changed)
        #expect(monitor.volumes.first?.id != oldID)
    }

    @Test func unknownUnmountedFilesystemIsNotInvented() {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample(kind: nil, state: .unmounted))
        #expect(monitor.volumes.isEmpty)
    }

    @Test func staleMockCannotReachLiveOperations() {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        #expect(throws: VolumeActionError.removed) { try monitor.current(monitor.volumes[0].id) }
    }

    @Test func liveEnumerationIsReadOnlyAndExcludesKnownExFAT() async throws {
        let monitor = DiskMonitor()
        defer { monitor.stop() }
        try await Task.sleep(for: .seconds(1))
        #expect(monitor.errorMessage == nil)
        #expect(!monitor.observedFileSystems.isEmpty)
        if FileManager.default.fileExists(atPath: "/Volumes/Xd Drive") {
            #expect(monitor.observedFileSystems.values.contains("exfat"))
        }
        #expect(!monitor.volumes.contains { $0.name == "Xd Drive" })
        print("LIVE_DA_FILESYSTEMS=\(Set(monitor.observedFileSystems.values).sorted())")
        print("LIVE_DA_NTFS_COUNT=\(monitor.volumes.count)")
    }
}

@MainActor
private final class FakeDiskOperations {
    var volumes: [UUID: NTFSVolume] = [:]
    var opened: [UUID] = []
    var unmounted: [UUID] = []
    var failure: VolumeActionError?
    var gate: CheckedContinuation<Void, Never>?
    var suspend = false

    init(_ values: [NTFSVolume]) { volumes = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }) }
    func current(_ id: UUID) throws -> NTFSVolume {
        guard let volume = volumes[id] else { throw VolumeActionError.removed }
        return volume
    }
    var operations: VolumeOperations {
        VolumeOperations(current: { try self.current($0) }, openInFinder: { id in
            _ = try self.current(id)
            self.opened.append(id)
            if let failure = self.failure { throw failure }
        }, unmount: { id in
            _ = try self.current(id)
            self.unmounted.append(id)
            if self.suspend { await withCheckedContinuation { self.gate = $0 } }
            _ = try self.current(id)
            if let failure = self.failure { throw failure }
            self.volumes[id]?.mountURL = nil
            self.volumes[id]?.state = .unmounted
        })
    }
}

@Suite @MainActor
struct MountCoordinatorTests {
    private func fixture() -> (FakeDiskOperations, MountCoordinator, [NTFSVolume]) {
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(sample())
        monitor.apply(sample(2, bsd: "disk91s2")) // sibling volume on same whole disk
        let fake = FakeDiskOperations(monitor.volumes)
        return (fake, MountCoordinator(operations: fake.operations), monitor.volumes)
    }

    @Test func unmountOnlySelectedSibling() async {
        let (fake, coordinator, volumes) = fixture()
        await coordinator.perform(.unmount, on: volumes[0].id)
        #expect(fake.unmounted == [volumes[0].id])
        #expect(fake.volumes[volumes[0].id]?.state == .unmounted)
        #expect(fake.volumes[volumes[1].id]?.state == .readOnly)
        #expect(coordinator.lastError == nil)
    }

    @Test func finderOnlyOpensSelectedVolume() async {
        let (fake, coordinator, volumes) = fixture()
        await coordinator.perform(.finder, on: volumes[1].id)
        #expect(fake.opened == [volumes[1].id])
        #expect(fake.unmounted.isEmpty)
    }

    @Test(arguments: [VolumeActionError.busy, .permissionDenied, .system(-1)])
    func failedUnmountDoesNotInventSuccess(_ failure: VolumeActionError) async {
        let (fake, coordinator, volumes) = fixture()
        fake.failure = failure
        await coordinator.perform(.unmount, on: volumes[0].id)
        #expect(fake.volumes[volumes[0].id]?.state == .readOnly)
        #expect(coordinator.lastError == failure.localizedDescription)
        #expect(coordinator.busyIDs.isEmpty)
    }

    @Test func finderFailureIsVisible() async {
        let (fake, coordinator, volumes) = fixture()
        fake.failure = .finderFailed
        await coordinator.perform(.finder, on: volumes[0].id)
        #expect(coordinator.lastError == VolumeActionError.finderFailed.localizedDescription)
    }

    @Test func removedSelectionNeverInvokesSystemAction() async {
        let (fake, coordinator, volumes) = fixture()
        fake.volumes[volumes[0].id] = nil
        await coordinator.perform(.unmount, on: volumes[0].id)
        #expect(fake.unmounted.isEmpty)
        #expect(coordinator.lastError == VolumeActionError.removed.localizedDescription)
    }

    @Test func unmountedSelectionCannotOpenFinder() async {
        let (fake, coordinator, volumes) = fixture()
        fake.volumes[volumes[0].id]?.mountURL = nil
        await coordinator.perform(.finder, on: volumes[0].id)
        #expect(fake.opened.isEmpty)
        #expect(coordinator.lastError == VolumeActionError.notMounted.localizedDescription)
    }

    @Test func duplicateActionAndRemovalDuringAction() async throws {
        let (fake, coordinator, volumes) = fixture()
        fake.suspend = true
        let first = Task { await coordinator.perform(.unmount, on: volumes[0].id) }
        for _ in 0..<100 where fake.gate == nil { await Task.yield() }
        let gate = try #require(fake.gate)
        #expect(coordinator.busyIDs.contains(volumes[0].id))
        await coordinator.perform(.unmount, on: volumes[0].id)
        #expect(fake.unmounted.count == 1)
        fake.volumes[volumes[0].id] = nil
        gate.resume()
        await first.value
        #expect(coordinator.lastError == VolumeActionError.removed.localizedDescription)
        #expect(coordinator.busyIDs.isEmpty)
    }

    @Test func lateCompletionCannotModifyNewConnection() async throws {
        let (fake, coordinator, volumes) = fixture()
        fake.suspend = true
        let task = Task { await coordinator.perform(.unmount, on: volumes[0].id) }
        for _ in 0..<100 where fake.gate == nil { await Task.yield() }
        let gate = try #require(fake.gate)
        fake.volumes[volumes[0].id] = nil
        let replacement = sample(3, bsd: volumes[0].bsdName)
        let monitor = DiskMonitor(startMonitoring: false)
        monitor.apply(replacement)
        let reinserted = try #require(monitor.volumes.first)
        fake.volumes[reinserted.id] = reinserted
        gate.resume()
        await task.value
        #expect(fake.volumes[reinserted.id]?.state == .readOnly)
        #expect(!coordinator.busyIDs.contains(reinserted.id))
    }

    @Test func readWriteInterfaceDefaultsToUnavailable() async {
        let (fake, coordinator, volumes) = fixture()
        await coordinator.enableReadWrite(on: volumes[0].id)
        #expect(coordinator.lastError == VolumeActionError.unavailable.localizedDescription)
        #expect(fake.unmounted.isEmpty)
        #expect(fake.opened.isEmpty)
    }
}

@Suite @MainActor
struct MenuBarRenderingTests {
    private func render(_ view: some View, name: String) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: name.hasSuffix("light") ? .aqua : .darkAqua)
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Evidence")
        try png.write(to: evidence.appendingPathComponent(name + ".png"))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func emptyAndMultipleVolumePanelsRender(_ scheme: ColorScheme) throws {
        let monitor = DiskMonitor(startMonitoring: false)
        let unavailable = DriverAvailability(macFUSE: .notDetected, ntfs3G: .notDetected, fsKitSystemAvailable: true)
        let fake = FakeDiskOperations([])
        let coordinator = MountCoordinator(operations: fake.operations)
        let suffix = scheme == .light ? "light" : "dark"
        try render(MenuBarView(monitor: monitor, coordinator: coordinator, drivers: unavailable)
            .environment(\.colorScheme, scheme), name: "empty-" + suffix)
        for (offset, state) in NTFSVolume.MountState.allCases.enumerated() {
            monitor.apply(sample(UInt64(offset + 1), bsd: "disk9\(offset)s1", state: state))
        }
        try render(VStack(spacing: 0) {
            Text("模擬測試資料 · 系統操作已隔離").font(.caption).padding(8)
            MenuBarView(monitor: monitor, coordinator: coordinator, drivers: unavailable)
        }.environment(\.colorScheme, scheme), name: "multiple-mock-" + suffix)
        #expect(monitor.volumes.count == 4)
    }
}
