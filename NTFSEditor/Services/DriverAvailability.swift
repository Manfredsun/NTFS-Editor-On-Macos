import Foundation

struct DriverAvailability {
    enum Status: Equatable {
        case installed(version: String?)
        case notDetected
        case unknown

        var text: String {
            switch self {
            case .installed(let version): version.map { "已安裝（\($0)）" } ?? "已安裝，版本未確認"
            case .notDetected: "未偵測到"
            case .unknown: "無法確認"
            }
        }
    }

    let macFUSE: Status
    let ntfs3G: Status
    let fsKitSystemAvailable: Bool

    static func inspect() -> Self {
        let fm = FileManager.default
        var inspectionFailed = false
        var fuseVersion: String?
        var fuseReceipt = false
        var ntfsReceipt = false
        var ntfsVersion: String?
        // Read receipts; never launch discovered binaries or change extension registration.
        do {
            for file in try fm.contentsOfDirectory(atPath: "/var/db/receipts") where file.hasSuffix(".plist") {
                let lower = file.lowercased()
                guard lower.contains("macfuse") || lower.contains("osxfuse") || lower.contains("ntfs-3g") else { continue }
                let url = URL(fileURLWithPath: "/var/db/receipts").appendingPathComponent(file)
                guard let data = try? Data(contentsOf: url),
                      let receipt = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { inspectionFailed = true; continue }
                let version = receipt["PackageVersion"] as? String
                if lower.contains("fuse") { fuseReceipt = true; fuseVersion = version ?? fuseVersion }
                if lower.contains("ntfs-3g") { ntfsReceipt = true; ntfsVersion = version ?? ntfsVersion }
            }
        } catch { inspectionFailed = true }

        let fusePaths = ["/Library/Filesystems/macfuse.fs", "/Library/Filesystems/osxfuse.fs",
                         "/Library/Frameworks/macFUSE.framework"]
        let fusePresent = fusePaths.contains { fm.fileExists(atPath: $0) }
        for path in fusePaths {
            if let bundle = Bundle(path: path), let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                fuseVersion = version
                break
            }
        }
        let searchDirectories = Set((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [MountPolicy.helperRoot + "/engine/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/usr/sbin"])
        let binary = searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent("ntfs-3g") }
            .first { fm.isExecutableFile(atPath: $0.path) }
        if binary?.path.hasPrefix(MountPolicy.helperRoot + "/") == true,
           ManagedMountStore.trustedPath(MountPolicy.helperRoot + "/engine-version.txt"),
           let version = try? String(contentsOfFile: MountPolicy.helperRoot + "/engine-version.txt", encoding: .utf8) {
            ntfsVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let binary, let resolved = URLComponents(url: binary.resolvingSymlinksInPath(), resolvingAgainstBaseURL: false)?.path {
            let components = resolved.split(separator: "/").map(String.init)
            if let cellar = components.firstIndex(of: "Cellar"), components.count > cellar + 2 {
                ntfsVersion = components[cellar + 2]
            }
        }
        return Self(
            macFUSE: fusePresent ? .installed(version: fuseVersion) : (fuseReceipt || inspectionFailed ? .unknown : .notDetected),
            ntfs3G: binary != nil ? .installed(version: ntfsVersion) : (ntfsReceipt || inspectionFailed ? .unknown : .notDetected),
            fsKitSystemAvailable: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))
                && fm.fileExists(atPath: "/System/Library/Frameworks/FSKit.framework")
        )
    }
}
