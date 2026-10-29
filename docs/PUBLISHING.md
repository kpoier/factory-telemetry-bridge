# GitHub 與 Factorio Mod Portal 發布

## 目前狀態

第一個整理版本為 `0.6.0`，來源是已在私人世界驗證的 0.5.100。專案擁有人已確認原始碼的發布權，選用 **MIT** 授權與 **Public** repository。

GitHub 名稱：`kpoier/factory-telemetry-bridge`。Mod Portal 的 mod 名稱也為 `factory-telemetry-bridge`。

## 1. 授權設定

根目錄 LICENSE 是 MIT 授權，`portal-license.txt` 的值為 `default_mit`。未來若調整授權，兩者必須一致。

## 2. 建立 GitHub repository

在 GitHub 登入後開啟 https://github.com/new ，owner 選自己的帳號，名稱填 `factory-telemetry-bridge`。選擇 Public；不要勾選初始化 README、.gitignore 或 license，因為本機已準備好。

本機可使用 GitHub CLI 完成登入與推送。發佈 workflow 檔案需要相應 GitHub token 權限；OAuth 登入可額外要求 `workflow` scope。

```bash
gh auth login --hostname github.com --git-protocol https --web --scopes workflow
gh auth setup-git --hostname github.com
git init --initial-branch=main
git add .
git commit -m "Prepare Factory Telemetry Bridge 0.6.0"
git remote add origin https://github.com/kpoier/factory-telemetry-bridge.git
git push -u origin main
```

若本機已初始化，不要重複 `git init`；若已有 origin，先確認其 URL。repository 可透過瀏覽器或 `gh repo create` 建立。檢查 GitHub Actions 的 CI 成功後才進行首次發布。

## 3. 設定 Factorio API key

到 https://factorio.com/profile 建立專用 API key。首次建立 mod 需要 **ModPortal: Publish Mods**，後續版本上傳需要 **ModPortal: Upload Mods**。不要使用遊戲下載用 token 代替發布 key。

在 repository 的 **Settings → Secrets and variables → Actions → New repository secret** 新增：

```text
FACTORIO_MOD_PORTAL_API_KEY
```

值填剛產生的 key。不要將 key 貼到 issue、聊天室、README、workflow 或 Git。若使用 CLI，執行 `gh secret set FACTORIO_MOD_PORTAL_API_KEY --repo kpoier/factory-telemetry-bridge` 後在提示輸入，避免將 key 直接寫在 shell command 裡。

首次發布後可改用只有 **ModPortal: Upload Mods** 的 key 覆蓋同名 secret，並撤銷舊 key。不需要 Edit Mods 權限；目前不自動更新已存在項目的長說明。

## 4. 首次建立 Portal 項目

初次尚未有 Portal 項目時，先不要推送版本標籤。到 GitHub **Actions → Publish mod → Run workflow**：

- Branch 選 `main`。
- mode 選 `first`。
- tag 填 `v0.6.0`，必須與當前 `mod/info.json` 完全一致。

這個 bootstrap 模式會檢查 main 的同一份 commit，在全部 CI 通過後使用官方 init_publish API。它不要求版本標籤事先存在，避免標籤觸發 update 模式卻找不到 mod 的問題。

成功後檢查 https://mods.factorio.com/mod/factory-telemetry-bridge ，再將相同 commit 標記為 `v0.6.0`：

```bash
git tag -a v0.6.0 -m "Factory Telemetry Bridge 0.6.0"
git push origin v0.6.0
```

這會再次啟動 update workflow；相同版本與相同套件 SHA1 會安全略過。若 main 已有其他 commit，應把標籤打在首次發布的 commit，避免同版本對應不同內容。

## 5. 後續更新

修改程式，更新 `mod/info.json` 版本，並在 `mod/changelog.txt` 最上方加上對應記錄。先推送 main，等 CI 成功，再標記同一個 commit：

```bash
git tag -a v0.6.1 -m "Factory Telemetry Bridge 0.6.1"
git push origin v0.6.1
```

一般 branch push 不會發布。標籤發布只允許 update，版本必須前進且標籤完全相符。手動重跑 update 時，Run workflow 的 Branch/tag 必須選擇對應標籤，tag 輸入填同一個值，確保檢查與上傳使用同一份來源。

不覆寫或刪除已發布版本。若發布有錯，修正後提高版本。

## 失敗處理與驗證範圍

- 缺少 secret、授權設定、版本不符或 ZIP 不符來源時會停止。
- 網路失敗不會當成「mod 不存在」。不會自動把 update 改成 first。
- 上傳回應遺失時只查詢已發布版本與 SHA1，不盲目重送上傳。
- CI 的 headless 測試建立全新 base 世界，啟動只綁定 localhost 的臨時伺服器並跑到至少 600 ticks，驗證模組載入及週期資料；不代表大型 Space Age／Py 世界的全部資料分支已測試。
- 此流程發布 mod，不會替換任何運行中的遊戲存檔、模組目錄或 systemd service。
- 打包可重現：同一份來源會得到相同 ZIP。打包器與發布器使用 Python 標準函式庫，所有 GitHub Actions 固定完整 commit SHA。

官方協定：[首次建立](https://wiki.factorio.com/Mod_publish_API)、[版本上傳](https://wiki.factorio.com/Mod_upload_API)、[修改說明](https://wiki.factorio.com/Mod_details_API)。
