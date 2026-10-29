# Factory Telemetry Bridge

Factorio 2.1 的工廠資料介面，提供產消、玩家、研究、列車、已探索地圖與藍圖資料，並提供管理員暫停／恢復／存檔控制。需要 Factorio **2.1.23+**，內部模組名稱為 `factory-telemetry-bridge`。

這個專案只包含遊戲模組與開發／發布工具。網頁監控台、HTTP 伺服器、RCON 客戶端和歷史資料庫需要由外部程式提供。

## 安裝與讀取資料

把發行 ZIP 放到 Factorio 的 mods 目錄，啟用後載入世界。多人遊戲的伺服器與所有玩家必須使用相同模組版本。

預設每 **300 個遊戲 ticks** 取樣，將 JSON 寫到 Factorio write-data 目錄下：

```text
script-output/factory-telemetry-bridge/state.json
```

這是遊戲運行時約每 5 秒一次，暫停或 UPS 下降時會更慢。檔案／UDP 輸出限定伺服器端；Lua 採集運算仍會在所有 multiplayer peers 執行。

全域模組設定可選陣營（預設 `player`）、地表（預設 `nauvis`）、觀察物品與傳輸方式。陣營／地表必須已存在。UDP 模式嘗試送到本機設定埠，失敗時退回檔案，消費端需自行處理這個備援。

伺服器 console／RCON 可以用 `/ftb-snapshot` 按需取得 JSON。完整命令、設定與界線見 [docs/API.md](docs/API.md)。

## 資料與效能界線

- 產消是最近一分鐘的統計值；電力資料依賴已掃描的已探索區塊電桿快取，可能不完整。
- 詳細地圖與配方目錄按需查詢，應分批讀取並降低頻率。
- 目前保留 0.5.100 的採集方式，尚未優化每 300 ticks 的採樣尖峰。改用 RCON 或嵌入存檔不會自動移除客戶端運算。
- 資料包含玩家名稱、位置、管理員狀態、地圖 seed 與模組清單。對外提供資料前請自行決定可見範圍。
- 遊戲內查詢通常唯讀；暫停／恢復會改變世界暫停狀態，存檔命令會要求伺服器保存。
- 設定選單提供英文與繁體中文；部分既有控制訊息仍使用中文。

## 開發與檢查

需要 Python 3.11+ 與 Lua 編譯器 `luac`。發布／打包使用 Python 標準函式庫。

```bash
python3 scripts/build.py --check
python3 -m unittest discover -s tests -v
find mod -name '*.lua' -print0 | xargs -0 -r -n1 luac -p
python3 scripts/build.py --output dist
```

真實引擎的基本載入與週期輸出測試使用獨立新世界，不會連線正式伺服器。這不等同大型 Space Age／Py 世界的完整 API 相容性測試：

```bash
python3 scripts/smoke_test.py --factorio /path/to/factorio/bin/x64/factorio
```

打包只納入 mod 原始碼、locale、changelog、README 和 LICENSE。機器上的存檔、伺服器設定、監控網站、RCON 密碼和 API key 不屬於本專案。

## CI/CD

- `main` 的 push 和 pull request：檢查 metadata、Lua 語法、發布工具測試，使用真實 headless 引擎建立新世界、啟動 localhost 臨時伺服器並驗證輸出，最後產生 ZIP artifact。
- `vX.Y.Z` 標籤的 push：重跑相同檢查，要求標籤與 `mod/info.json` 的版本完全一致，然後上傳到官方 Mod Portal。
- 第一次建立 Portal 項目：手動啟動 `Publish mod` workflow，選擇 `first`；其後標籤發布只使用 `update`。
- 一般 commit 不會發布，也不會部署到任何遊戲伺服器。

首次設定與發布步驟見 [docs/PUBLISHING.md](docs/PUBLISHING.md)。

## 來源與授權

本專案由 kpoier 維護，採用 [MIT 授權](LICENSE)。來源及版本銜接紀錄見 [docs/PROVENANCE.md](docs/PROVENANCE.md)。
