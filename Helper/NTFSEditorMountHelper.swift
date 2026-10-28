import Foundation
import DiskArbitration
import CryptoKit
import Darwin

@MainActor
private final class DAResult {
    var completed = false
    var status: Int32 = 0
}
private let operationFinished: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    let result = Unmanaged<DAResult>.fromOpaque(context).takeRetainedValue()
    let status = dissenter.map { DADissenterGetStatus($0) } ?? 0
    MainActor.assumeIsolated { result.status = status; result.completed = true }
}

@main @MainActor
struct NTFSEditorMountHelper {
    static func main() {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
                print("NTFS Editor Mount Helper \(MountPolicy.helperVersion)")
                return
            }
            if CommandLine.arguments == [CommandLine.arguments[0], "--check-driver"] {
                if let reason = MountPolicy.kernelDriverBlockReason(loaded: MountPolicy.kernelDriverLoaded) {
                    throw MountSafetyError.reason(reason)
                }
                print("macFUSE kernel driver loaded")
                return
            }
            guard geteuid() == 0, CommandLine.arguments.count == 3,
                  CommandLine.arguments[1] == "--request", CommandLine.arguments[2].utf8.count < 4096,
                  let data = Data(base64Encoded: CommandLine.arguments[2])
            else { throw MountSafetyError.reason("掛載 Helper 只接受經管理員授權嘅固定操作。") }
            let request = try JSONDecoder().decode(ReadWriteRequest.self, from: data)
            guard request.isValid else { throw MountSafetyError.reason("磁碟身份資料無效。") }
            let mount = try enable(request)
            print(String(decoding: try JSONEncoder().encode(mount), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func trusted(_ path: String, directory: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
        else { return false }
        return true
    }

    static func verifyEngine() throws {
        for directory in ["/Library", "/Library/PrivilegedHelperTools", MountPolicy.helperRoot,
                          MountPolicy.helperRoot + "/engine", MountPolicy.helperRoot + "/engine/bin",
                          MountPolicy.helperRoot + "/engine/lib"] {
            guard trusted(directory, directory: true) else { throw MountSafetyError.reason("Helper 安裝權限或目錄身份不安全。") }
        }
        let manifestPath = MountPolicy.helperRoot + "/engine-sha256.json"
        guard trusted(manifestPath) else { throw MountSafetyError.reason("引擎信任紀錄缺失。") }
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard manifest["bin/ntfs-3g"] != nil, manifest["bin/ntfs-3g.probe"] != nil else {
            throw MountSafetyError.reason("引擎信任紀錄不完整。")
        }
        for (relative, expected) in manifest {
            guard relative.range(of: #"^(bin|lib)/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw MountSafetyError.reason("引擎路徑無效。")
            }
            let path = MountPolicy.helperRoot + "/engine/" + relative
            guard trusted(path), SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
                .map({ String(format: "%02x", $0) }).joined() == expected else {
                throw MountSafetyError.reason("引擎完整性驗證失敗，已拒絕執行。")
            }
        }
    }

    static func enable(_ request: ReadWriteRequest) throws -> ManagedMount {
        // Fail before touching Disk Arbitration or unmounting anything.
        if let reason = MountPolicy.kernelDriverBlockReason(loaded: MountPolicy.kernelDriverLoaded) {
            throw MountSafetyError.reason(reason)
        }
        try verifyEngine()
        guard let session = DASessionCreate(nil) else { throw MountSafetyError.reason("系統磁碟服務不可用。") }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        defer { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid > 0, let user = getpwuid(console.st_uid) else {
            throw MountSafetyError.reason("未能確認目前登入使用者。")
        }
        let uid = console.st_uid
        let gid = user.pointee.pw_gid
        let disk = try validatedDisk(request, session: session, allowUnmountedUnknownKind: true)
        let initial = try snapshot(disk)
        guard initial.state != .readWrite, initial.state != .unknown else {
            throw MountSafetyError.reason("磁碟已可寫入，或者狀態無法確認；未改動原有掛載。")
        }
        let initialVolumeName = initial.name
        let wasMounted = initial.mountURL != nil
        if wasMounted { try performDA(disk, readOnlyMount: false) }
        var engine: Process?
        var mountedPath: String?
        do {
            _ = try validatedDisk(request, session: session, allowDriverKind: true)
            guard !sourceIsMounted(request.bsdName) else { throw MountSafetyError.reason("磁碟仍然掛載，未啟動第二套驅動。") }
            let probe = try runProbe(request)
            guard probe.status == 0 else { throw MountSafetyError.probeFailure(probe.status, detail: probe.detail) }
            _ = try validatedDisk(request, session: session, allowDriverKind: true)
            let path = "/Volumes/NTFSEditor-" + UUID().uuidString
            let arguments = try MountPolicy.arguments(request: request, mountPath: path, uid: uid, gid: gid)
            guard !FileManager.default.fileExists(atPath: path) else { throw MountSafetyError.reason("掛載位置已存在。") }
            guard mkdir(path, 0o755) == 0 else { throw MountSafetyError.reason("未能建立專用掛載位置。") }
            mountedPath = path
            let (process, engineLog) = try launch("ntfs-3g", arguments: arguments)
            engine = process
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                _ = try validatedDisk(request, session: session, allowDriverKind: true)
                if let fsid = mountedID(path, requireWritable: true) {
                    let result = ManagedMount(request: request, mountPath: path, fileSystemID: fsid, volumeName: initialVolumeName)
                    try writeRecord(result)
                    return result
                }
                if !process.isRunning {
                    let detail = readLogSnippet(engineLog, maxBytes: 2048)
                    throw MountSafetyError.reason("macFUSE 核心掛載失敗（\(process.terminationStatus)）。\n\(detail)")
                }
                pump()
            }
            throw MountSafetyError.reason("macFUSE 未能建立已確認嘅核心讀寫掛載。")
        } catch {
            var canRestore = true
            if let path = mountedPath, anyMountID(path) != nil {
                if let mountedDisk = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: path) as CFURL) {
                    do { try performDA(mountedDisk, readOnlyMount: false) }
                    catch { canRestore = false }
                } else { canRestore = false }
                if anyMountID(path) != nil { canRestore = false }
            }
            if canRestore, let engine, engine.isRunning {
                engine.terminate()
                let deadline = Date().addingTimeInterval(3)
                while engine.isRunning && Date() < deadline { pump() }
                if engine.isRunning { canRestore = false }
            }
            if canRestore, let path = mountedPath, anyMountID(path) == nil {
                // Only remove our newly created, empty directory. Never recurse.
                _ = rmdir(path)
            }
            if wasMounted, canRestore, let sameDisk = try? validatedDisk(request, session: session, allowDriverKind: true), !sourceIsMounted(request.bsdName) {
                do { try performDA(sameDisk, readOnlyMount: true) }
                catch { throw MountSafetyError.reason("讀寫掛載失敗，唯讀掛載亦未能恢復；磁碟目前未掛載，請用 Finder／磁碟工具檢查。") }
            }
            if !canRestore { throw MountSafetyError.reason("掛載狀態未能安全確認；未嘗試強制卸載或啟動其他驅動。") }
            throw error
        }
    }

    static func validatedDisk(_ request: ReadWriteRequest, session: DASession,
                              allowDriverKind: Bool = false,
                              allowUnmountedUnknownKind: Bool = false) throws -> DADisk {
        guard let disk = DADiskCreateFromBSDName(nil, session, "/dev/" + request.bsdName),
              let current = DiskMetadata.snapshot(disk), current.isExternal,
              current.registryID == request.registryID, current.bsdName == request.bsdName,
              current.capacity == request.capacity,
              current.volumeUUID == request.volumeUUID
                  || ((allowDriverKind || (allowUnmountedUnknownKind && current.mountURL == nil)) && current.volumeUUID == nil),
              current.mediaUUID == request.mediaUUID,
              current.isNTFS
                  || (allowUnmountedUnknownKind && current.mountURL == nil && (current.fileSystem == nil || ["macfuse", "fskit"].contains(current.fileSystem?.lowercased() ?? "")))
                  || (allowDriverKind && (current.fileSystem == nil || ["macfuse", "fskit"].contains(current.fileSystem ?? "")))
        else { throw MountSafetyError.reason("磁碟已移除或身份改變，已停止操作。") }
        return disk
    }

    static func snapshot(_ disk: DADisk) throws -> DiskSnapshot {
        guard let result = DiskMetadata.snapshot(disk) else { throw MountSafetyError.reason("無法確認磁碟資料。") }
        return result
    }

    static func pump() { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false) }

    static func performDA(_ disk: DADisk, readOnlyMount: Bool) throws {
        let result = DAResult()
        let context = Unmanaged.passRetained(result).toOpaque()
        if readOnlyMount {
            let option = Unmanaged.passRetained("rdonly" as CFString)
            defer { option.release() }
            var arguments: [Unmanaged<CFString>?] = [option, nil]
            arguments.withUnsafeMutableBufferPointer {
                DADiskMountWithArguments(disk, nil, 0, operationFinished, context, $0.baseAddress)
            }
        } else {
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), operationFinished, context)
        }
        let deadline = Date().addingTimeInterval(20)
        while !result.completed && Date() < deadline { pump() }
        guard result.completed else { throw MountSafetyError.reason("系統磁碟操作逾時，狀態未確認；未繼續掛載。") }
        guard result.status == 0 else {
            if result.status == DAReturn(kDAReturnBusy) { throw MountSafetyError.reason("磁碟正在使用中，未強制卸載。") }
            throw MountSafetyError.reason("系統磁碟操作失敗（\(result.status)）。")
        }
    }

    static func sourceIsMounted(_ bsd: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return true }
        for index in 0..<Int(count) {
            var item = mounts[index]
            let source = withUnsafePointer(to: &item.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if source == "/dev/" + bsd || source == "/dev/r" + bsd { return true }
        }
        return false
    }

    static func mountedID(_ path: String, requireWritable: Bool) -> [Int32]? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let actual = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let kind = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard actual == path, kind == "macfuse",
              !requireWritable || info.f_flags & UInt32(MNT_RDONLY) == 0 else { return nil }
        return [info.f_fsid.val.0, info.f_fsid.val.1]
    }

    // Cleanup must detect any filesystem at this exact path, including an unknown
    // driver kind. Otherwise a failed verification could start a second driver.
    static func anyMountID(_ path: String) -> [Int32]? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let actual = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard actual == path else { return nil }
        return [info.f_fsid.val.0, info.f_fsid.val.1]
    }

    static func launch(_ name: String, arguments: [String]) throws -> (Process, FileHandle) {
        let logs = MountPolicy.helperRoot + "/logs"
        guard trusted(logs, directory: true) else { throw MountSafetyError.reason("Helper 紀錄目錄權限無效。") }
        let logPath = logs + "/" + UUID().uuidString + ".log"
        let fd = open(logPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MountSafetyError.reason("無法建立操作紀錄。") }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MountPolicy.helperRoot + "/engine/bin/" + name)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "HOME": "/var/root"]
        process.currentDirectoryURL = URL(fileURLWithPath: MountPolicy.helperRoot)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return (process, log)
    }

    static func readLogSnippet(_ log: FileHandle, maxBytes: Int) -> String {
        try? log.seek(toOffset: 0)
        guard let data = try? log.read(upToCount: maxBytes) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runProbe(_ request: ReadWriteRequest) throws -> (status: Int32, detail: String) {
        let (process, log) = try launch("ntfs-3g.probe", arguments: ["--readwrite", "/dev/" + request.bsdName])
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { pump() }
        guard !process.isRunning else { process.terminate(); throw MountSafetyError.reason("NTFS 安全檢查逾時，已拒絕寫入。") }
        let detail = process.terminationStatus == 0 ? "" : readLogSnippet(log, maxBytes: 1024)
        return (process.terminationStatus, detail)
    }

    static func writeRecord(_ mount: ManagedMount) throws {
        guard trusted(MountPolicy.recordsPath, directory: true) else { throw MountSafetyError.reason("掛載紀錄目錄權限無效。") }
        let path = MountPolicy.recordsPath + "/\(mount.request.registryID).json"
        let data = try JSONEncoder().encode(mount)
        if FileManager.default.fileExists(atPath: path), !trusted(path) {
            throw MountSafetyError.reason("舊掛載紀錄權限不安全。")
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        guard chmod(path, 0o644) == 0 else { throw MountSafetyError.reason("無法設定掛載紀錄權限。") }
    }
}
