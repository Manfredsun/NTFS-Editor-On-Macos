import SwiftUI

struct MenuBarView: View {
    let monitor: DiskMonitor
    let coordinator: MountCoordinator
    let drivers: DriverAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NTFS Editor").font(.headline).padding(14)
            Divider()
            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).padding(18)
            } else if monitor.volumes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                    Text("未偵測到 NTFS 硬碟")
                    Text("連接 NTFS 外置硬碟後，會喺呢度顯示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 14)
                .accessibilityIdentifier("empty-state")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.volumes) { volume in
                            VolumeRowView(volume: volume, coordinator: coordinator)
                            if volume.id != monitor.volumes.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(monitor.volumes.count) * 265, 470))
            }
            if let error = coordinator.lastError {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    Button("關閉提示") { coordinator.dismissError() }
                }.padding(14)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("macFUSE：\(drivers.macFUSE.text)")
                Text("NTFS-3G：\(drivers.ntfs3G.text)")
                Text(MountPolicy.kernelDriverLoaded ? "核心驅動已載入；讀寫仍需實際掛載確認" : "核心驅動未載入；請先完成系統允許設定")
                Text(coordinator.readWriteBlockReason ?? "讀寫掛載需管理員授權；會重新確認實際狀態")
            }
            .font(.caption).foregroundStyle(.secondary).padding(14)
            Divider()
            Button("結束 NTFS Editor") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q").padding(14)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
