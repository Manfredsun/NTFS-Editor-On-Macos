# NTFS Editor for macOS

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B-brightgreen.svg)](#系統需求)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](#系統需求)
[![Swift](https://img.shields.io/badge/Swift-6.0-red.svg)](#專案建置)

**NTFS Editor** 是一套專為 macOS 設計的原生選單列（Menu Bar）輔助工具。透過 **macFUSE 5.5.0 核心 VFS 驅動** 與受 SHA-256 校驗保護的 **NTFS-3G** 引擎，一鍵將外接 NTFS 磁碟切換為讀寫模式。所有檔案瀏覽、拖曳複製、修改與刪除均由原生 **Finder** 負責，無需忍受第三方龐大且昂貴的商業軟體。

> 🌐 **介紹網站**：專案包含現代化的靜態介紹頁面，位於 [`docs/index.html`](docs/index.html)，可直接啟用 GitHub Pages 預覽。

---

## ✨ 功能特色

* ⚡️ **極簡原生選單列（SwiftUI Menu Bar）**：採用 `MenuBarExtra` 架構常駐頂部選單列（`LSUIElement = YES`，不佔用 Dock），一鍵快速檢視外接 NTFS 磁碟連線、容量與掛載狀態。
* 📁 **Finder 原生無縫整合**：啟用讀寫後，所有操作直接在 Finder 中進行。支援原生拖曳複製、命名、刪除，並完整相容 macOS 延伸屬性（`auto_xattr`）與 `ResourceFork` 檔案傳輸。
* 🛡️ **安全第一的掛載防護政策**：
  * 切換讀寫前先安全卸載系統預設唯讀掛載，並執行 NTFS 檔案系統健康 Probe。
  * 固定採用 `norecover,no_def_opts,no_detach,nodev,nosuid,windows_names,auto_xattr,silent` 安全旗標。
  * 嚴格驗證磁碟識別碼（BSD Name、UUID、FSID），防範磁碟代號重複或誤操作。
* ⏏️ **單一磁碟區安全卸載**：僅卸載所選之 NTFS Volume，不影響同硬碟上的其他分割區，確保資料快取安全寫入。
* 🔒 **特權隔離輔助程式（Helper）**：
  * 特權掛載程式安裝於 `/Library/PrivilegedHelperTools/local.NTFSEditor.mount/`，由 `root:wheel` 擁有，不設 `setuid`，無常駐背景守護行程（daemon）。
  * 每次執行皆嚴格校驗底層二進制二維 SHA-256 數位特徵清單（`engine-sha256.json`）。
* 🤝 **100% 自由開源**：遵循 GNU GPL v3.0，零廣告、無遙測收集、程式碼完全透明。

---

## 💻 系統需求

| 項目 | 規格要求 |
|---|---|
| **作業系統** | macOS 15.0 (Sequoia) 或更高版本（支援 macOS 15.4+ 及 macOS 27） |
| **處理器架構** | Apple Silicon 原生架構（`arm64`，M1 / M2 / M3 / M4 系列） |
| **核心依賴** | [macFUSE 5.5.0+](https://osxfuse.github.io/)（需啟用 Kernel VFS Extension） |
| **權限需求** | 輔助程式需具備「完全磁碟取用權（Full Disk Access）」 |

---

## 🚀 下載與快速安裝

1. 前往 [Releases](https://github.com/Manfredsun/NTFS-Editor-On-Macos/releases) 下載最新發布的 **`NTFS Editor-0.2.5.dmg`**。
2. 開啟 DMG：
   * 將 **`NTFS Editor.app`** 拖移至 **`/Applications`**。
   * 雙擊安裝 **`Install NTFS Editor Mount Helper 0.2.5.pkg`**。
3. **系統安全性與核心擴充授權**：
   * 詳細圖文步驟請參閱完整的 [**核心驅動與完全磁碟取用權設定指南 (INSTALL-KERNEL.md)**](INSTALL-KERNEL.md)。
   * *簡要說明*：Apple Silicon 需在「開機選項 → 啟動安全性工具程式」中將安全性調整為「降低安全性」並勾選「允許使用者管理核心延伸功能」（**不需要**停用 SIP），重啟後在「系統設定 → 隱私權與安全性」允許 macFUSE，並將 `NTFSEditorMountHelper` 加入「完全磁碟取用權」。
4. 啟動 `NTFS Editor.app`，插入 NTFS 硬碟，點擊頂部選單列圖示並點選 **「切換讀寫」** 即可！

---

## 🛠️ 從原始碼建置 (Build from Source)

本專案使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 產生 Xcode 專案結構。

### 1. 準備建置工具
```sh
# 安裝 XcodeGen
brew install xcodegen

# 複製倉庫
git clone https://github.com/Manfredsun/NTFS-Editor-On-Macos.git
cd NTFS-Editor-On-Macos
```

### 2. 下載並驗證私有引擎二進制依賴
建置輔助工具需要準備經過 SHA-256 驗證的 `NTFS-3G` 及官方 `macFUSE 5.5.0` 支援函式庫：
```sh
python3 scripts/prepare_engine.py
```

### 3. 編譯 Release 版本 App 與 Helper
```sh
# 若有修改 project.yml 可先重新生成專案
xcodegen generate

# 編譯 Release 產物
xcodebuild -project NTFSEditor.xcodeproj -scheme NTFSEditor -configuration Release -derivedDataPath .build/Kernel025 ONLY_ACTIVE_ARCH=NO build
```

### 4. 打包 Helper PKG 與發布版 DMG
```sh
# 打包本機安裝用 Helper PKG
python3 scripts/package_helper.py

# 打包正式發布用 DMG 映像檔
python3 scripts/package_dmg.py
```
打包完成後，產物將存放於 `Build/NTFS Editor-0.2.5.dmg`。

---

## 🧪 測試驗證

本專案包含完整的 Swift Testing 單元測試，透過操作替身（Test Doubles）隔離實體磁碟：

```sh
xcodebuild -project NTFSEditor.xcodeproj -scheme NTFSEditor -configuration Debug -derivedDataPath .build -destination 'platform=macOS,arch=arm64' test
```

---

## 📂 專案結構

```
NTFS-Editor-On-Macos/
├── NTFSEditor/              # 主應用程式原始碼 (SwiftUI)
│   ├── App/                 # App 生命週期與入口
│   ├── UI/                  # 選單列 UI (MenuBarView, VolumeRowView)
│   ├── Models/              # NTFS 磁碟模型 (NTFSVolume)
│   ├── Services/            # 磁碟監控 (DiskMonitor)、掛載協調 (MountCoordinator)
│   ├── Shared/              # App 與 Helper 共用之磁碟識別與掛載政策
│   ├── Resources/           # AppIcon 與資源
│   └── Tests/               # Swift Testing 單元測試
├── Helper/                  # 特權掛載輔助程式 (NTFSEditorMountHelper.swift)
├── scripts/                 # 自動化依賴準備、打包與測試腳本
├── docs/                    # 專案介紹官方靜態網頁 (GitHub Pages)
├── INSTALL-KERNEL.md        # 核心驅動與系統安全性詳細設定說明
├── project.yml              # XcodeGen 設定檔
├── LICENSE                  # GNU GPL v3.0 授權條款
└── README.md                # 專案說明文件
```

---

## ⚠️ 免責聲明 (Disclaimer)

* 對 NTFS 檔案系統進行寫入涉及底層檔案系統結構的修改。使用本軟體前，**請務必確保重要資料已建立獨立備份**。
* 開發團隊不對因硬體損毀、異常斷電、驅動相容性問題或未正常卸載所造成的資料損失承擔法律責任。

---

## 📄 開源授權 (License)

本專案採用 **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)** 授權。
所使用的底層工具元件：
- `NTFS-3G` 採用 GPL-2.0-or-later 授權。
- `macFUSE` 核心延伸及函式庫依其個別官方授權條款發布。
