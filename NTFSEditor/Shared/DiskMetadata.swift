import Foundation
import DiskArbitration
import IOKit
import Darwin

nonisolated enum DiskMetadata {
    static func eligibleDevice(internalFlag: Bool?, removable: Bool, vendor: String?, model: String?, protocolName: String?) -> Bool {
        if let internalFlag { return !internalFlag }
        // Apple disk images omit DeviceInternal. Recognize this explicit virtual
        // device identity; missing flags on physical devices remain ineligible.
        return removable && vendor == "Apple" && model == "Disk Image" && protocolName == "Virtual Interface"
    }

    static func snapshot(_ disk: DADisk) -> DiskSnapshot? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS,
              let bsd = DADiskGetBSDName(disk),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        func uuid(_ key: CFString) -> String? {
            guard let value = description[key as String] else { return nil }
            guard CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
            return CFUUIDCreateString(nil, (value as! CFUUID)) as String?
        }
        let mountURL = description[kDADiskDescriptionVolumePathKey as String] as? URL
        var state: NTFSVolume.MountState = mountURL == nil ? .unmounted : .unknown
        if let mountURL {
            var info = statfs()
            if statfs(mountURL.path, &info) == 0 {
                let actualMount = withUnsafePointer(to: &info.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                // statfs on a stale path can describe the parent filesystem. Do not trust it.
                if actualMount == mountURL.path {
                    state = (info.f_flags & UInt32(MNT_RDONLY)) != 0 ? .readOnly : .readWrite
                }
            }
        }
        return DiskSnapshot(
            registryID: registryID, bsdName: String(cString: bsd),
            fileSystem: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            isExternal: eligibleDevice(
                internalFlag: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
                removable: (description[kDADiskDescriptionMediaRemovableKey as String] as? Bool) == true,
                vendor: description[kDADiskDescriptionDeviceVendorKey as String] as? String,
                model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
                protocolName: description[kDADiskDescriptionDeviceProtocolKey as String] as? String),
            volumeUUID: uuid(kDADiskDescriptionVolumeUUIDKey), mediaUUID: uuid(kDADiskDescriptionMediaUUIDKey),
            name: description[kDADiskDescriptionVolumeNameKey as String] as? String,
            capacity: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value,
            mountURL: mountURL, state: state
        )
    }
}
