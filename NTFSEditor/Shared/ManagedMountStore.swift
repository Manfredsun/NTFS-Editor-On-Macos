import Foundation
import Darwin

nonisolated enum ManagedMountStore {
    static func trustedPath(_ path: String, directory: Bool = false) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0
            && info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
    }

    static func record(for snapshot: DiskSnapshot) -> ManagedMount? {
        guard trustedPath(MountPolicy.helperRoot, directory: true),
              trustedPath(MountPolicy.recordsPath, directory: true) else { return nil }
        let file = MountPolicy.recordsPath + "/\(snapshot.registryID).json"
        guard trustedPath(file), let data = try? Data(contentsOf: URL(fileURLWithPath: file)), data.count < 4096,
              let record = try? JSONDecoder().decode(ManagedMount.self, from: data),
              record.request.isValid, record.request.registryID == snapshot.registryID,
              record.request.bsdName == snapshot.bsdName,
              record.request.volumeUUID == snapshot.volumeUUID || snapshot.volumeUUID == nil,
              record.request.mediaUUID == snapshot.mediaUUID, record.request.capacity == snapshot.capacity,
              record.mountPath.hasPrefix("/Volumes/NTFSEditor-"),
              URL(fileURLWithPath: record.mountPath).deletingLastPathComponent().path == "/Volumes",
              let current = mountedState(record.mountPath), current.id == record.fileSystemID
        else { return nil }
        return record
    }

    static func mountedState(_ path: String) -> (id: [Int32], writable: Bool)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let actual = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let kind = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard actual == path, ["macfuse", "fskit"].contains(kind) else { return nil }
        return ([info.f_fsid.val.0, info.f_fsid.val.1], info.f_flags & UInt32(MNT_RDONLY) == 0)
    }

    static func enrich(_ snapshot: DiskSnapshot) -> DiskSnapshot {
        guard let record = record(for: snapshot), let state = mountedState(record.mountPath) else { return snapshot }
        var result = snapshot
        result.fileSystem = "ntfs"
        result.volumeUUID = snapshot.volumeUUID ?? record.request.volumeUUID
        if let volumeName = record.volumeName, !volumeName.isEmpty {
            result.name = volumeName
        }
        result.mountURL = URL(fileURLWithPath: record.mountPath)
        result.state = state.writable ? (MountPolicy.currentUserCanAccess(record.mountPath) ? .readWrite : .unknown) : .readOnly
        return result
    }
}
