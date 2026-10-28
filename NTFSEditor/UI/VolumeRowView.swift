import SwiftUI

struct VolumeRowView: View {
    let volume: NTFSVolume
    let coordinator: MountCoordinator

    @State private var confirmingReadWrite = false

    private var busy: Bool { coordinator.busyIDs.contains(volume.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(volume.name, systemImage: "externaldrive").font(.headline)
            Text("NTFS · \(volume.capacityText)").foregroundStyle(.secondary)
            Text(volume.bsdName).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("狀態：\(volume.state.rawValue)")
            if let url = volume.mountURL {
                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("啟用讀寫", systemImage: "lock.open") { confirmingReadWrite = true }
                .disabled(busy || volume.state == .readWrite || volume.state == .unknown || coordinator.readWriteBlockReason != nil)
                .alert("啟用讀寫？", isPresented: $confirmingReadWrite) {
                    Button("我已備份，啟用讀寫") {
                        Task { await coordinator.perform(.enableReadWrite, on: volume.id) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("只會處理「\(volume.name)」（\(volume.bsdName)）。請先確認已做好獨立備份；系統會要求管理員授權。Windows 休眠或 dirty 狀態會拒絕寫入。")
                }
            Text(coordinator.readWriteBlockReason ?? "切換讀寫需要管理員授權")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("在 Finder 開啟", systemImage: "folder") {
                    Task { await coordinator.perform(.finder, on: volume.id) }
                }
                .disabled(busy || volume.mountURL == nil || volume.state == .unknown)
                Button("安全卸載", systemImage: "eject") {
                    Task { await coordinator.perform(.unmount, on: volume.id) }
                }
                .disabled(busy || volume.mountURL == nil)
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在操作") }
            }
            Text("只卸載呢個 Volume，唔代表整部硬碟已可拔除。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("volume-\(volume.bsdName)")
    }
}
