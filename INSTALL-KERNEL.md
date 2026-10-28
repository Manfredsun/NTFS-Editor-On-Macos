# NTFS Editor 安裝與核心驅動設定指南

本文檔說明 **NTFS Editor (v0.2.5)** 的安裝步驟、macFUSE 核心擴充功能授權，以及輔助程式（Helper）的「完全磁碟取用權」設定。

---

## 快速安裝步驟

1. **安裝主程式**：將 DMG 映像檔中的 `NTFS Editor.app` 拖曳至 `/Applications`（應用程式）資料夾。
2. **安裝掛載輔助程式**：雙擊執行 DMG 內的 `Install NTFS Editor Mount Helper 0.2.5.pkg`，並輸入管理者密碼完成安裝。
3. **安裝 macFUSE**：本軟體底層依賴 [macFUSE 5.5.0+](https://osxfuse.github.io/) 的核心 VFS 驅動。若系統尚未安裝，請先至官網下載並安裝最新版本。

---

## 系統安全性與核心延伸功能（Kernel Extension）設定

由於 macOS 對於第三方檔案系統驅動的高安全性限制，在 Apple Silicon (M1/M2/M3/M4) 機型上使用 macFUSE 核心驅動需進行一次性安全性原則設定：

### 步驟 1：允許使用者管理核心延伸功能（一次性設定）
1. 將 Mac 徹底關機。
2. 長按電源按鈕不放，直到螢幕顯示「正在載入開機選項（Loading startup options）」，點選「選項」並點擊「繼續」。
3. 登入管理者帳號後，於頂部選單列點選 **「工具程式（Utilities）」** → **「啟動安全性工具程式（Startup Security Utility）」**。
4. 選擇系統開機磁碟，點選右下角的 **「安全性政策...（Security Policy...）」**。
5. 將安全性由「完整安全性」切換為 **「降低安全性（Reduced Security）」**，並勾選 **「允許使用者管理來自已識別開發者的核心延伸功能（Allow user management of kernel extensions from identified developers）」**。
   > **注意**：此操作**不需要**關閉系統完整性保護（SIP, System Integrity Protection）。
6. 點擊「好」，輸入管理者密碼確認後重新開機。

### 步驟 2：於系統設定中允許 macFUSE 延伸功能
1. 進入系統後，開啟 **「系統設定」** → **「隱私權與安全性」**。
2. 向下捲動至安全性區塊，系統會提示「來自開發者 "Benjamin Fleischer" 的系統延伸功能已遭到阻擋」。
3. 點選 **「允許（Allow）」** 並依系統指示輸入密碼，完成後按提示重新開機以正式載入核心驅動。

---

## 賦予輔助程式「完全磁碟取用權（Full Disk Access）」

NTFS Editor 透過特權掛載輔助程式直接對磁碟分割區（如 `/dev/rdisk*`）進行讀寫掛載，macOS 要求此程式需具備磁碟存取權限：

1. 開啟 **「系統設定」** → **「隱私權與安全性」** → **「完全磁碟取用權（Full Disk Access）」**。
2. 點擊底部的 `+` 按鈕。
3. 在彈出的檔案選取視窗中，按下鍵盤快速鍵 `Command + Shift + G`，輸入路徑：
   ```
   /Library/PrivilegedHelperTools/local.NTFSEditor.mount/NTFSEditorMountHelper
   ```
4. 選取 `NTFSEditorMountHelper` 並確認加入，確保其開關處於**開啟（允許）**狀態。

---

## 開始使用

1. 由 `/Applications` 啟動 **NTFS Editor.app**。
2. App 會在頂部選單列（Menu Bar）常駐顯示磁碟圖示。
3. 插入 NTFS 格式之外接硬碟，點擊選單列圖示查看磁碟狀態。
4. 點選 **「切換讀寫」**，系統將提示確認資料備份並進行一次管理員密碼驗證，完成後即可直接在 **Finder** 中對該 NTFS 磁碟自由進行檔案讀取、寫入、修改、拖曳複製與刪除。
5. 使用完畢請點選 **「安全卸載」**，以確保檔案快取完整寫入硬碟。

---

## 參考文件
- [macFUSE 官方安裝與故障排除指南](https://github.com/macfuse/macfuse/wiki/Getting-Started)
