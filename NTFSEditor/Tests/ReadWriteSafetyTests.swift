import Foundation
import Testing
@testable import NTFSEditor

@Suite @MainActor
struct ReadWriteSafetyTests {
    @Test func authorizationFailuresExplainNextStepWithoutEngineCommandLines() {
        let message = AdminMountClient.failureMessage("FSKit: File system extension not enabled\nCmdline options: backend=fskit")
        #expect(message.contains("未能使用"))
        #expect(message.contains("未獲確認"))
        #expect(!message.contains("Cmdline"))
        #expect(AdminMountClient.failureMessage("User canceled. (-128)").contains("取消"))
        #expect(AdminMountClient.failureMessage("").contains("失敗"))
    }

    @Test func missingInternalFlagOnlyAllowsExplicitAppleRemovableImage() {
        #expect(DiskMetadata.eligibleDevice(internalFlag: nil, removable: true, vendor: "Apple", model: "Disk Image", protocolName: "Virtual Interface"))
        #expect(!DiskMetadata.eligibleDevice(internalFlag: true, removable: true, vendor: "Apple", model: "Disk Image", protocolName: "Virtual Interface"))
        #expect(!DiskMetadata.eligibleDevice(internalFlag: nil, removable: true, vendor: "Other", model: "Disk Image", protocolName: "USB"))
        #expect(!DiskMetadata.eligibleDevice(internalFlag: nil, removable: false, vendor: nil, model: nil, protocolName: nil))
        #expect(DiskMetadata.eligibleDevice(internalFlag: false, removable: false, vendor: nil, model: nil, protocolName: nil))
    }

    private var request: ReadWriteRequest {
        ReadWriteRequest(bsdName: "disk91s2", registryID: 12345, volumeUUID: nil,
                         mediaUUID: "C87AC95B-BD31-4931-9B27-B5BF30E5F930", capacity: 128 * 1024 * 1024)
    }

    @Test(arguments: ["disk1;touch /tmp/test", "../disk1", "/dev/disk1", "disk1\n", "disk-1", ""])
    func rejectsDeviceInjection(_ input: String) {
        let altered = ReadWriteRequest(bsdName: input, registryID: 1, volumeUUID: nil, mediaUUID: nil, capacity: 128)
        #expect(!altered.isValid)
    }

    @Test func invalidUUIDAndMissingIdentityAreRejected() {
        #expect(!ReadWriteRequest(bsdName: "disk3", registryID: 0, volumeUUID: nil, mediaUUID: nil, capacity: 1).isValid)
        #expect(!ReadWriteRequest(bsdName: "disk3", registryID: 1, volumeUUID: "invalid", mediaUUID: nil, capacity: 1).isValid)
        #expect(!ReadWriteRequest(bsdName: "disk3", registryID: 1, volumeUUID: nil, mediaUUID: nil, capacity: 0).isValid)
        #expect(request.isValid)
    }

    @Test func fixedMountPolicyProhibitsRecoveryAndUnsafeDefaults() throws {
        let args = try MountPolicy.arguments(request: request, mountPath: "/Volumes/NTFSEditor-test", uid: 501, gid: 20)
        #expect(args[0] == "/dev/disk91s2")
        let options = Set(args[3].split(separator: ",").map(String.init))
        #expect(!options.contains { $0.hasPrefix("backend=") })
        #expect(options.contains("norecover"))
        #expect(options.contains("no_def_opts"))
        #expect(options.contains("silent"))
        #expect(options.contains("windows_names"))
        #expect(options.contains("auto_xattr"))
        #expect(!options.contains("recover"))
        #expect(!options.contains("force"))
        #expect(!options.contains("remove_hiberfile"))
        #expect(options.contains("allow_other"))
        #expect(options.contains("default_permissions"))
        #expect(options.contains("uid=501"))
        #expect(options.contains("gid=20"))
        #expect(options.contains("umask=077"))
        #expect(!options.contains("nonempty"))
    }

    @Test func missingKernelDriverBlocksBeforeMounting() {
        #expect(MountPolicy.kernelDriverBlockReason(loaded: false)?.contains("未切換磁碟模式") == true)
        #expect(MountPolicy.kernelDriverBlockReason(loaded: true) == nil)
    }

    @Test(arguments: ["/", "/Volumes/UserDisk", "/Volumes/NTFSEditor-test/../../tmp", "/tmp/NTFSEditor-test"])
    func arbitraryDestinationsAreRejected(_ path: String) {
        #expect(throws: (any Error).self) {
            try MountPolicy.arguments(request: request, mountPath: path, uid: 501, gid: 20)
        }
    }

    @Test func privilegedProcessCannotAssignFilesToRootUser() {
        #expect(throws: (any Error).self) {
            try MountPolicy.arguments(request: request, mountPath: "/Volumes/NTFSEditor-test", uid: 0, gid: 0)
        }
    }

    @Test(arguments: [12, 13, 14, 15, 16, 19, 99] as [Int32])
    func everyUnsafeProbeResultHasAnExplicitFailure(_ code: Int32) {
        #expect(MountSafetyError.probeFailure(code).localizedDescription.count > 10)
    }

    @Test func probeDistinguishesRawDevicePermissionDeniedFromHibernation() {
        let eperm = MountSafetyError.probeFailure(14, detail: "Error opening '/dev/disk7s1': Operation not permitted").localizedDescription
        #expect(eperm.contains("完整磁碟存取權"))
        #expect(eperm.contains("NTFSEditorMountHelper"))
        #expect(!eperm.contains("休眠"))

        let hibernated = MountSafetyError.probeFailure(14, detail: "Windows is hibernated, refused to mount.").localizedDescription
        #expect(hibernated.contains("休眠"))
        #expect(MountSafetyError.probeFailure(14).localizedDescription.contains("休眠"))
    }

    @Test func actualParentFilesystemIsNotMistakenForManagedMount() {
        #expect(ManagedMountStore.mountedState("/") == nil)
        #expect(ManagedMountStore.mountedState("/Volumes/NTFSEditor-nonexistent-test") == nil)
    }

    @Test func newActionKeepsErrorsWithoutInventingWriteState() async {
        let volume = NTFSVolume(id: UUID(), registryID: 1, bsdName: "disk91s2", volumeUUID: nil,
                                mediaUUID: nil, name: "Test", capacity: 1_000_000,
                                mountURL: nil, state: .unmounted)
        var requests: [UUID] = []
        let operations = VolumeOperations(current: { _ in volume }, openInFinder: { _ in }, unmount: { _ in },
            enableReadWrite: { id in requests.append(id); throw MountSafetyError.probeFailure(14) },
            readWriteBlockReason: { nil })
        let coordinator = MountCoordinator(operations: operations)
        await coordinator.perform(.enableReadWrite, on: volume.id)
        #expect(requests == [volume.id])
        #expect(coordinator.lastError?.contains("休眠") == true)
        #expect(volume.state == .unmounted)
        #expect(coordinator.busyIDs.isEmpty)
    }
}
