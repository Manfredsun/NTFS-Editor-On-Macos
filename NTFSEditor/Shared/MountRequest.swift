import Foundation
import Darwin

nonisolated struct ReadWriteRequest: Codable, Equatable, Sendable {
    let bsdName: String
    let registryID: UInt64
    let volumeUUID: String?
    let mediaUUID: String?
    let capacity: Int64

    var isValid: Bool {
        bsdName.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil
            && registryID != 0 && capacity > 0
            && [volumeUUID, mediaUUID].compactMap { $0 }.allSatisfy { UUID(uuidString: $0) != nil }
    }
}

nonisolated struct ManagedMount: Codable, Equatable, Sendable {
    let request: ReadWriteRequest
    let mountPath: String
    let fileSystemID: [Int32]
    let volumeName: String?

    init(request: ReadWriteRequest, mountPath: String, fileSystemID: [Int32], volumeName: String? = nil) {
        self.request = request
        self.mountPath = mountPath
        self.fileSystemID = fileSystemID
        self.volumeName = volumeName
    }
}

nonisolated enum MountSafetyError: LocalizedError, Sendable {
    case reason(String)
    var errorDescription: String? { if case .reason(let message) = self { message } else { nil } }

    static func probeFailure(_ code: Int32, detail: String = "") -> Self {
        let lower = detail.lowercased()
        if (lower.contains("operation not permitted") || lower.contains("permission denied")),
           (lower.contains("error opening") || lower.contains("failed to access") || lower.contains("/dev/disk")) {
            return .reason("macOS 拒絕存取實體磁碟（Operation not permitted），未啟用讀寫。請到「系統設定 → 隱私權與安全性 → 完整磁碟存取權」允許 NTFSEditorMountHelper 後再試。")
        }
        let reason = switch code {
        case 12: "未能確認係有效 NTFS，已拒絕寫入。"
        case 13: "NTFS 結構或硬件狀態異常，請先喺 Windows 檢查磁碟。"
        case 14: "Windows 處於休眠／Fast Startup 狀態，已拒絕寫入；請返 Windows 完整關機。"
        case 15: "磁碟未正常卸載（dirty），已拒絕寫入；請先喺 Windows 檢查。"
        case 16: "磁碟正被其他程式或驅動佔用，已停止操作。"
        case 19: "未獲足夠磁碟存取權限。"
        default: "未能確認 NTFS 可安全寫入（probe 代碼：\(code)），已停止操作。"
        }
        return .reason(reason)
    }
}

nonisolated enum MountPolicy {
    static let helperVersion = "0.2.5"
    static let helperRoot = "/Library/PrivilegedHelperTools/local.NTFSEditor.mount"
    static let helperPath = helperRoot + "/NTFSEditorMountHelper"
    static let recordsPath = helperRoot + "/records"

    // Query the registered VFS directly; a package receipt or FSKit module does
    // not prove that the kernel driver is loaded. This never loads a driver.
    static var kernelDriverLoaded: Bool {
        var configuration = vfsconf()
        return getvfsbyname("macfuse", &configuration) == 0
    }

    static func kernelDriverBlockReason(loaded: Bool) -> String? {
        loaded ? nil : "macFUSE 核心驅動未載入。請先完成復原模式嘅第三方核心延伸功能設定，再喺系統設定允許 macFUSE。未切換磁碟模式。"
    }

    static func currentUserCanAccess(_ path: String) -> Bool {
        access(path, R_OK | W_OK | X_OK) == 0
    }

    static func arguments(request: ReadWriteRequest, mountPath: String, uid: UInt32, gid: UInt32) throws -> [String] {
        guard request.isValid, uid > 0, mountPath.hasPrefix("/Volumes/NTFSEditor-"),
              URL(fileURLWithPath: mountPath).deletingLastPathComponent().path == "/Volumes"
        else { throw MountSafetyError.reason("掛載要求或目的地無效。") }
        // Omitting backend selects macFUSE's documented default kernel/VFS
        // backend. Never fall back to FSKit after a failed mount.
        // The privileged mounter and console user are different identities.
        // allow_other removes only the FUSE mounter-only gate; mandatory kernel
        // permission checks plus fixed console ownership and umask 077 keep
        // other non-root accounts out. The helper derives uid/gid from console.
        // no_def_opts still prevents NTFS-3G's nonempty/recovery defaults, while
        // silent restores chmod/chown compatibility that no_def_opts cancels and
        // auto_xattr handles Finder extended attributes via AppleDouble without
        // relaxing windows_names.
        return ["/dev/" + request.bsdName, mountPath, "-o",
                "norecover,no_def_opts,silent,no_detach,nodev,nosuid,windows_names,auto_xattr,allow_other,default_permissions,uid=\(uid),gid=\(gid),umask=077"]
    }
}
