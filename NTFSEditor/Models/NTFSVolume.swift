import Foundation

struct NTFSVolume: Identifiable, Equatable {
    nonisolated enum MountState: String, CaseIterable, Sendable {
        case readOnly = "唯讀"
        case readWrite = "讀寫"
        case unmounted = "未掛載"
        case unknown = "無法確認"
    }

    // A new token is assigned on every new IOMedia connection, including BSD-name reuse.
    let id: UUID
    let registryID: UInt64
    let bsdName: String
    let volumeUUID: String?
    let mediaUUID: String?
    var name: String
    var capacity: Int64?
    var mountURL: URL?
    var state: MountState

    var capacityText: String {
        capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) } ?? "容量未知"
    }
}

nonisolated struct DiskSnapshot: Sendable {
    let registryID: UInt64
    let bsdName: String
    var fileSystem: String?
    var isExternal: Bool
    var volumeUUID: String?
    var mediaUUID: String?
    var name: String?
    var capacity: Int64?
    var mountURL: URL?
    var state: NTFSVolume.MountState

    var isNTFS: Bool { fileSystem?.lowercased() == "ntfs" }
}

enum VolumeActionError: LocalizedError, Equatable {
    case removed, notMounted, busy, permissionDenied, unavailable, finderFailed, stateNotConfirmed
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .removed: "磁碟已移除或連線已改變，請重新選擇。"
        case .notMounted: "呢個 Volume 尚未掛載。"
        case .busy: "磁碟正在使用中，請關閉相關檔案或 App 後再試。"
        case .permissionDenied: "系統拒絕卸載要求，請檢查存取權限。"
        case .unavailable: "讀寫整合尚未可用。"
        case .finderFailed: "Finder 無法開啟呢個 Volume。"
        case .stateNotConfirmed: "未能確認卸載結果，請檢查目前掛載狀態。"
        case .system(let code): "系統操作失敗（代碼：\(code)）。"
        }
    }
}
