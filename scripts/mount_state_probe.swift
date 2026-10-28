import Foundation
import Darwin
let path = CommandLine.arguments[1]
var mounts: UnsafeMutablePointer<statfs>?
let count = getmntinfo(&mounts, MNT_NOWAIT)
var result: [[String: Any]] = []
if count > 0, let mounts {
    for index in 0..<Int(count) {
        var item = mounts[index]
        let destination = withUnsafePointer(to: &item.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard destination == path else { continue }
        let source = withUnsafePointer(to: &item.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let kind = withUnsafePointer(to: &item.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        result.append(["target": destination, "source": source, "type": kind, "read_only": item.f_flags & UInt32(MNT_RDONLY) != 0, "fsid": [item.f_fsid.val.0,item.f_fsid.val.1]])
    }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
