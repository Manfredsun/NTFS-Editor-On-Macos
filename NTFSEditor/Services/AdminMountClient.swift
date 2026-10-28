import Foundation
import Darwin

@MainActor
enum AdminMountClient {
    static var unavailableReason: String? {
        #if !arch(arm64)
        return "讀寫引擎目前只支援 Apple Silicon 原生模式。"
        #else
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 4, patchVersion: 0)) else {
            return "讀寫模式需要 macOS 15.4 或以上。"
        }
        guard FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs") else { return "請先安裝 macFUSE 5。" }
        guard ManagedMountStore.trustedPath(MountPolicy.helperRoot, directory: true),
              ManagedMountStore.trustedPath(MountPolicy.helperPath),
              FileManager.default.isExecutableFile(atPath: MountPolicy.helperPath) else {
            return "請先安裝 NTFS Editor Mount Helper。"
        }
        let versionPath = MountPolicy.helperRoot + "/helper-version.txt"
        guard ManagedMountStore.trustedPath(versionPath),
              let version = try? String(contentsOfFile: versionPath, encoding: .utf8),
              version.trimmingCharacters(in: .whitespacesAndNewlines) == MountPolicy.helperVersion else {
            return "請更新 NTFS Editor Mount Helper 至 \(MountPolicy.helperVersion)。"
        }
        return MountPolicy.kernelDriverBlockReason(loaded: MountPolicy.kernelDriverLoaded)
        #endif
    }

    static func enable(_ volume: NTFSVolume) async throws {
        if let reason = unavailableReason { throw MountSafetyError.reason(reason) }
        let request = ReadWriteRequest(bsdName: volume.bsdName, registryID: volume.registryID,
                                      volumeUUID: volume.volumeUUID, mediaUUID: volume.mediaUUID,
                                      capacity: volume.capacity ?? 0)
        guard request.isValid else { throw MountSafetyError.reason("磁碟身份未能完整確認。") }
        var console = stat()
        let userID = geteuid()
        guard userID > 0, stat("/dev/console", &console) == 0, console.st_uid == userID else {
            throw MountSafetyError.reason("請由目前登入桌面嘅使用者執行掛載。")
        }
        let encoded = try JSONEncoder().encode(request).base64EncodedString()
        // Only the fixed helper and a JSON payload encoded with the Base64 alphabet
        // enter the system's administrator authorization flow. No UI shell commands.
        let script = """
        on run argv
            return do shell script "\(MountPolicy.helperPath) --request " & quoted form of (item 1 of argv) with administrator privileges with prompt "NTFS Editor 需要管理員授權，安全切換所選 NTFS Volume 至讀寫模式。"
        end run
        """
        let process = Process()
        let input = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.arguments = ["-", encoded]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        } catch {
            process.terminate()
            throw MountSafetyError.reason("授權或掛載要求已中斷，請重新核對磁碟狀態。")
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MountSafetyError.reason(failureMessage(errorText))
        }
        guard let managed = try? JSONDecoder().decode(ManagedMount.self, from: outputData), managed.request == request,
              let actual = ManagedMountStore.mountedState(managed.mountPath), actual.writable,
              actual.id == managed.fileSystemID else { throw MountSafetyError.reason("未能確認讀寫掛載結果。") }
        guard MountPolicy.currentUserCanAccess(managed.mountPath) else {
            throw MountSafetyError.reason("未能確認目前登入帳戶可以存取掛載位置。請先安全卸載，再檢查掛載權限。")
        }
    }

    static func failureMessage(_ text: String) -> String {
        if text.contains("(-128)") { return "你已取消管理員授權，未啟用讀寫。" }
        if text.contains("File system extension not enabled") || text.contains("File system extension not found") {
            return "macFUSE 回報檔案系統延伸功能未能使用。此版本使用核心驅動，請確認 App 同 Helper 均已更新。讀寫掛載未獲確認，請檢查目前 Volume 狀態。"
        }
        return text.isEmpty ? "管理員掛載要求失敗。" : String(text.prefix(1024))
    }
}
