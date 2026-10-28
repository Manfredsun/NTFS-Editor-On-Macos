import Foundation
import Observation
import DiskArbitration
import IOKit
import Darwin

@Observable @MainActor
final class DiskMonitor {
    private(set) var volumes: [NTFSVolume] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private var session: DASession?
    @ObservationIgnored private(set) var observedFileSystems: [UInt64: String] = [:]
    @ObservationIgnored private var retiredRegistryIDs: Set<UInt64> = []

    init(startMonitoring: Bool = true) {
        if startMonitoring { start() }
    }

    func start() {
        guard session == nil else { return }
        guard let created = DASessionCreate(kCFAllocatorDefault) else {
            errorMessage = "無法連接系統磁碟監控服務。"
            return
        }
        session = created
        errorMessage = nil
        let context = Unmanaged.passUnretained(self).toOpaque()
        // DA sends existing disks through the appeared callback when scheduling starts.
        DARegisterDiskAppearedCallback(created, nil, diskAppeared, context)
        DARegisterDiskDisappearedCallback(created, nil, diskDisappeared, context)
        DARegisterDiskDescriptionChangedCallback(created, nil, nil, diskChanged, context)
        // All C callbacks use this main run loop; assumeIsolated below asserts that contract.
        DASessionScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stop() {
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(diskAppeared, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskDisappeared, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskChanged, to: UnsafeMutableRawPointer.self), context)
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.session = nil
        volumes.removeAll()
        observedFileSystems.removeAll()
        retiredRegistryIDs.removeAll()
    }

    // Shared reducer for real DA events and isolated test fixtures. No system operations here.
    func apply(_ snapshot: DiskSnapshot) {
        guard !retiredRegistryIDs.contains(snapshot.registryID) else { return }
        for previous in volumes where previous.bsdName == snapshot.bsdName && previous.registryID != snapshot.registryID {
            retiredRegistryIDs.insert(previous.registryID)
            observedFileSystems.removeValue(forKey: previous.registryID)
        }
        volumes.removeAll { $0.bsdName == snapshot.bsdName && $0.registryID != snapshot.registryID }
        if let kind = snapshot.fileSystem { observedFileSystems[snapshot.registryID] = kind }
        let previous = volumes.first { $0.registryID == snapshot.registryID && $0.bsdName == snapshot.bsdName }
        let kind = snapshot.fileSystem?.lowercased()
        let isDriverKind = kind == "macfuse" || kind == "fskit"
        let rememberedNTFS = snapshot.mountURL == nil && previous != nil && (kind == nil || isDriverKind)
        let transitionalManagedMount: Bool = {
            guard let previous, previous.mediaUUID == snapshot.mediaUUID, isDriverKind,
                  let path = snapshot.mountURL?.path, path.hasPrefix("/Volumes/NTFSEditor-"),
                  URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Volumes"
            else { return false }
            return true
        }()
        guard snapshot.isExternal, snapshot.isNTFS || rememberedNTFS || transitionalManagedMount else {
            volumes.removeAll { $0.registryID == snapshot.registryID }
            return
        }
        let effectiveVolumeUUID = snapshot.volumeUUID ?? ((rememberedNTFS || transitionalManagedMount) ? previous?.volumeUUID : nil)
        let sameIdentity = previous?.volumeUUID == effectiveVolumeUUID && previous?.mediaUUID == snapshot.mediaUUID
        let effectiveName: String = if isDriverKind {
            previous?.name ?? snapshot.name ?? snapshot.bsdName
        } else {
            snapshot.name ?? previous?.name ?? snapshot.bsdName
        }
        let volume = NTFSVolume(
            id: sameIdentity ? (previous?.id ?? UUID()) : UUID(),
            registryID: snapshot.registryID, bsdName: snapshot.bsdName,
            volumeUUID: effectiveVolumeUUID, mediaUUID: snapshot.mediaUUID,
            name: effectiveName,
            capacity: snapshot.capacity, mountURL: snapshot.mountURL,
            state: transitionalManagedMount ? .unknown : snapshot.state
        )
        volumes.removeAll { $0.registryID == snapshot.registryID || $0.bsdName == snapshot.bsdName }
        volumes.append(volume)
        volumes.sort { ($0.name, $0.bsdName) < ($1.name, $1.bsdName) }
    }

    func remove(registryID: UInt64) {
        retiredRegistryIDs.insert(registryID)
        observedFileSystems.removeValue(forKey: registryID)
        volumes.removeAll { $0.registryID == registryID }
    }

    func disappeared(snapshot: DiskSnapshot?, bsdName: String?) {
        if let snapshot {
            remove(registryID: snapshot.registryID)
            return
        }
        // IOMedia may already have gone by the time DA delivers disappearance.
        // Never remove a replacement with the same BSD name while its registry entry is live.
        guard let bsdName else { return }
        for volume in volumes where volume.bsdName == bsdName {
            let liveMedia = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(volume.registryID))
            if liveMedia == IO_OBJECT_NULL {
                remove(registryID: volume.registryID)
            } else {
                IOObjectRelease(liveMedia)
            }
        }
    }

    func current(_ id: UUID) throws -> NTFSVolume {
        guard let volume = volumes.first(where: { $0.id == id }),
              let session,
              let disk = DADiskCreateFromBSDName(nil, session, "/dev/" + volume.bsdName),
              let fresh = Self.snapshot(disk), fresh.registryID == volume.registryID,
              fresh.bsdName == volume.bsdName, fresh.isExternal,
              fresh.volumeUUID == volume.volumeUUID || (fresh.mountURL == nil && fresh.volumeUUID == nil),
              fresh.mediaUUID == volume.mediaUUID,
              fresh.isNTFS
                  || (fresh.mountURL == nil && (fresh.fileSystem == nil || ["macfuse", "fskit"].contains(fresh.fileSystem?.lowercased() ?? "")))
        else { throw VolumeActionError.removed }
        apply(fresh)
        guard let updated = volumes.first(where: { $0.id == id }) else { throw VolumeActionError.removed }
        return updated
    }

    func unmount(_ id: UUID) async throws {
        let volume = try current(id)
        guard let mountURL = volume.mountURL else { throw VolumeActionError.notMounted }
        guard let session else { throw VolumeActionError.removed }
        let disk = DADiskCreateFromVolumePath(nil, session, mountURL as CFURL)
            ?? (Self.mountSourceMatches(mountPath: mountURL.path, bsdName: volume.bsdName)
                ? DADiskCreateFromBSDName(nil, session, "/dev/" + volume.bsdName)
                : nil)
        guard let disk else { throw VolumeActionError.removed }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let request = UnmountRequest(continuation: continuation)
                // Only the selected volume; never Force, Whole, or DADiskEject.
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), unmountFinished,
                              Unmanaged.passRetained(request).toOpaque())
            }
        } catch VolumeActionError.permissionDenied where mountURL.path.hasPrefix("/Volumes/NTFSEditor-")
            && URL(fileURLWithPath: mountURL.path).deletingLastPathComponent().path == "/Volumes"
            && Self.mountSourceMatches(mountPath: mountURL.path, bsdName: volume.bsdName) {
            // Root-mounted macFUSE volumes omit MNT_LOCAL, causing raw DADiskUnmount to
            // return kDAReturnNotPrivileged; diskutil unmounts only this single volume.
            try await Self.diskutilSingleVolumeUnmount(mountPath: mountURL.path)
        }
        let updated = try current(id)
        guard updated.mountURL == nil else { throw VolumeActionError.stateNotConfirmed }
    }

    nonisolated private static func diskutilSingleVolumeUnmount(mountPath: String) async throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", mountPath]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard process.terminationStatus == 0 else {
            let combined = (
                String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) + "\n" +
                String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ).lowercased()
            if combined.contains("in use") || combined.contains("dissented") || combined.contains("busy") || combined.contains("failed to unmount") {
                throw VolumeActionError.busy
            }
            throw VolumeActionError.permissionDenied
        }
    }

    nonisolated private static func mountSourceMatches(mountPath: String, bsdName: String) -> Bool {
        var info = statfs()
        guard statfs(mountPath, &info) == 0 else { return false }
        let actualMount = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return actualMount == mountPath && (source == "/dev/" + bsdName || source == "/dev/r" + bsdName)
    }

    nonisolated static func snapshot(_ disk: DADisk) -> DiskSnapshot? {
        DiskMetadata.snapshot(disk).map { ManagedMountStore.enrich($0) }
    }

}

// Raw C objects stay inside each callback. Only copied Sendable values and main-actor
// owners enter assumeIsolated; scheduling above guarantees no actor hop is required.
private let diskAppeared: DADiskAppearedCallback = { disk, context in
    guard let context, let snapshot = DiskMonitor.snapshot(disk) else { return }
    let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.apply(snapshot) }
}
private let diskChanged: DADiskDescriptionChangedCallback = { disk, _, context in
    guard let context, let snapshot = DiskMonitor.snapshot(disk) else { return }
    let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.apply(snapshot) }
}
private let diskDisappeared: DADiskDisappearedCallback = { disk, context in
    guard let context else { return }
    let monitor = Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue()
    let snapshot = DiskMonitor.snapshot(disk)
    let bsdName = DADiskGetBSDName(disk).map { String(cString: $0) }
    MainActor.assumeIsolated { monitor.disappeared(snapshot: snapshot, bsdName: bsdName) }
}
private final class UnmountRequest {
    let continuation: CheckedContinuation<Void, any Error>
    init(continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
}
private let unmountFinished: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    let request = Unmanaged<UnmountRequest>.fromOpaque(context).takeRetainedValue()
    let status = dissenter.map { DADissenterGetStatus($0) }
    MainActor.assumeIsolated {
        guard let status else { request.continuation.resume(); return }
        let error: VolumeActionError = switch status {
        case DAReturn(kDAReturnBusy): .busy
        case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged): .permissionDenied
        case DAReturn(kDAReturnNotFound): .removed
        default: .system(status)
        }
        request.continuation.resume(throwing: error)
    }
}
