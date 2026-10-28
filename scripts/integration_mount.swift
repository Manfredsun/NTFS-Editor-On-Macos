// Build with the production Models, Shared sources and AdminMountClient.swift.
// This runner permits only an explicitly named, attached disposable disk image.
import Foundation
import DiskArbitration

@main @MainActor
struct IntegrationMount {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw MountSafetyError.reason("Expected BSD name and disposable image path.") }
            let bsd = CommandLine.arguments[1]
            let image = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
            let testRoot = FileManager.default.currentDirectoryPath + "/.build/ReadWriteTests/"
            guard image.hasPrefix(testRoot), image.hasSuffix("/disposable.ntfs") else { throw MountSafetyError.reason("Only this project's disposable test image is allowed.") }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print("hdiutil status: \(process.terminationStatus)")
            if let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, "/dev/" + bsd) { print("Snapshot: \(String(describing: DiskMetadata.snapshot(disk)))") }
            guard process.terminationStatus == 0,
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]],
                  images.contains(where: { item in
                      item["image-path"] as? String == image &&
                      (item["system-entities"] as? [[String: Any]])?.contains(where: { $0["dev-entry"] as? String == "/dev/" + bsd }) == true
                  }),
                  let session = DASessionCreate(nil),
                  let disk = DADiskCreateFromBSDName(nil, session, "/dev/" + bsd),
                  let snapshot = DiskMetadata.snapshot(disk), snapshot.isNTFS,
                  snapshot.isExternal, snapshot.capacity == 134_217_728, snapshot.name == "NTFSEditorTest"
            else { throw MountSafetyError.reason("Disposable virtual NTFS identity could not be verified.") }
            let volume = NTFSVolume(id: UUID(), registryID: snapshot.registryID, bsdName: snapshot.bsdName,
                                    volumeUUID: snapshot.volumeUUID, mediaUUID: snapshot.mediaUUID,
                                    name: snapshot.name ?? "", capacity: snapshot.capacity,
                                    mountURL: snapshot.mountURL, state: snapshot.state)
            print("Verified disposable image. Requesting the production administrator authorization flow.")
            try await AdminMountClient.enable(volume)
            guard let fresh = DiskMetadata.snapshot(disk), let managed = ManagedMountStore.record(for: fresh),
                  ManagedMountStore.mountedState(managed.mountPath)?.writable == true else {
                throw MountSafetyError.reason("Production mount record could not be verified.")
            }
            print(String(decoding: try JSONEncoder().encode(managed), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
