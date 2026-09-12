# 系統定位輸出：研究與實驗版驗收

目前是已通過短時間實機系統定位與 Apple Maps 驗證的實驗版。USBSerial 與既有 NMEAParser 未修改；新增 output adapter、private API wrapper、輸出頁面及獨立 CoreLocation Probe。尚無證據能宣稱純 TrollStore 在 iPadOS 17.0 鎖屏後持續輸出十分鐘，或 crash 後必定恢復定位。

## 來源與結論

2026-09-12 實際 clone 並讀取以下固定版本原始碼（不是只讀 README）：

| 專案 | 版本／來源 | 實際定位流程 |
|---|---|---|
| Geranium | [LocSimManager.swift](https://github.com/c22dev/Geranium/blob/29f66d70120f2ed804f5da19fc0962415d0562ba/Geranium/LocSim/LocSimManager.swift)、同目錄 LocSimPrivateHeaders.h | App 內的 CLSimulationManager，stop → clear → append CLLocation → flush → start |
| TrollBox | [LocSimManager.swift](https://github.com/c22dev/TrollBox/blob/f512e65b8ca6545326d8c3985d6e5614b58410ac/TrollBox/Tools/LocationSimulator/LocSimManager.swift) | 與 Geranium 相同；定位呼叫不經 root helper |
| locsim | [main.m](https://github.com/udevsharold/locsim/blob/7f7010de6061896237a98de950df715aa1fd61b9/main.m)、PrivateHeaders.h、entitlements.plist | 相同 simulation API；支援完整 CLLocation 欄位，delivery=0 pass-through、repeat=0 unavailable |

三者使用 CoreLocation 中 Apple 內建的 private `CLSimulationManager`，而不是 hook 各 App 的 CLLocationManager。所讀取的呼叫端沒有自行建立 NSXPCConnection，也沒有直接開 locationd socket；不可由此聲稱已確認框架內部 XPC service 名称或權限檢查位置。locsim 註解提到 locationd 的 XPC 更新，但這不是本機 daemon 實作證據。

Geranium／TrollBox 的核心 selector：`stopLocationSimulation`、`clearSimulatedLocations`、`appendSimulatedLocation:`、`flush`、`startLocationSimulation`。本版額外採用 locsim 已宣告的 `setLocationDeliveryBehavior:`、`setLocationRepeatBehavior:`，在呼叫前確認 class 與 selector 存在。所有 private 呼叫集中在 `LocationSimulationBridge.m`，Objective-C exception 轉 NSError；API 為 void，沒有 daemon 成功 ACK，因此 UI 只稱「送出」，不稱「成功注入」。

實機逐步測試顯示，只有 `com.apple.locationd.simulation` 不足，另加 `platform-application` 仍不足；Build 14 再加入僅允許 `com.apple.locationd.simulation` 的 `com.apple.security.exception.mach-lookup.global-name` 後，獨立 observer 才收到 `simulated=true`。Geranium 有大量供其他功能使用的廣泛權限，不能推論全部是定位必需。本版未新增 no-sandbox、root helper 或 JB 執行元件。

## 即時資料與失效策略

`ExternalFixAdapter` 接在既有 parser 輸出旁：每個有效 RMC epoch 產生一次 ExternalGNSSFix，GGA 必須在 3 秒內且 quality=1…5；近期 GSA 若 no-fix 則拒絕。刻意不把 GSV 等更新當成新位置。RMC 小數秒另行保留，避免原 snapshot 的整秒 timestamp 將 5／10 Hz 合併。首版要求 RMC + GGA；純 GGA 接收器暫不注入。

| 欄位 | 處理 |
|---|---|
| 位置／時間 | RMC 有效且新 epoch，座標範圍檢查；UTC 超過 3 秒或超前 1 秒拒絕 |
| altitude | 最近 GGA 公尺值；2D 不使用。GGA 是海拔，尚待 observer 驗證其垂直 datum 表現 |
| speed | 最新 RMC knots × 0.5144444444444445 → m/s |
| course | 最新 RMC [0,360) degrees；缺值傳 -1 |
| horizontalAccuracy | GGA HDOP × UERE（UI 可調 1…20 m，預設 5 m）；缺值 -1 |
| verticalAccuracy | 有高度及近期 VDOP 時 × UERE；否則 -1，表示高度不可作為有效精度資料 |

CLLocation 沒有 optional altitude，缺值以 0 作容器 placeholder，但 verticalAccuracy=-1 明確標為無效；不是宣稱海拔零。HDOP 推算不是實測誤差界線。

失效或斷線會 stop/clear/flush；執行中的 250 ms watchdog 檢查無新 fix 或 UTC 超齡，並不重送座標。有效 fix 回來後自動恢復；USB 讀取失敗後只在輸出開啟時，下一次熱插拔掃描嘗試重新連線，實機重插行為尚待測試。示範資料先強制停止輸出。

## 背景及 crash 限制

優先採用 [Apple Background Location](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)：UIBackgroundModes=location、前景請求 WhenInUse、allowsBackgroundLocationUpdates=true、pausesLocationUpdatesAutomatically=false，顯示背景定位指示。本 App 收到的 CLLocation 僅供觀察，絕不回送 injector，避免回授。Apple Maps 切至前景後已短時間觀察到 TrollGNSS 在背景維持約 1 Hz；這仍不等於鎖屏十分鐘或長時間導航保證。

`beginBackgroundTask` 是有限時間收尾，不足以承諾十分鐘無限 serial loop，本版不以此維持服務。尚未加入未驗證的 private background entitlement 或 TrollStore persistent helper；若標準模式失敗，先收集暫停時間及 observer 紀錄，再評估獨立 TrollStore helper，最後才考慮 JB daemon。SSH 僅供部署與讀取診斷，不是 App 執行依賴；当前測試 iPad 有 JB，不能等同已在無 JB 啟動狀態驗證。

每次更新明確設 repeat=0（不重播最後位置）；正常 OFF、失效與 willTerminate 時停止，留下 pending-cleanup 標記供下次啟動補清理。但 SIGKILL／jetsam 不保證 willTerminate，暫停中的 timer 也不能工作。repeat=0 的真正有效期、其他 App 快取最後位置及停用後恢復真實位置都尚待測試。不得保證 crash 後立即恢復，更不得以「無限重播最後位置」掩飾背景失敗。

## 可重現測試與證據

在專案根目錄執行：

```sh
swift test --package-path Packages/NMEACore
./scripts/build_ipa.sh
bash scripts/build_location_probe.sh
```

Build 14 IPA：`dist/NMEAPad.ipa`；Probe：`dist/LocationProbe.ipa`。安裝不刪除既有 App 資料。TrollGNSS Documents/LocationInjection-Diagnostics.json 提供 5 秒輸入／送出頻率、timestamp、latency、背景標記及本 App CLLocation 觀察；Probe Documents/locations.jsonl 逐筆記錄所有欄位。latency 是 GNSS UTC 到呼叫完成，包含傳輸與時鐘偏差，不是 locationd ACK latency。含精確座標與本機路徑的原始 evidence 保留在本機，已由 `.gitignore` 排除公開 repository。

### Evidence → finding → next path

| Evidence | 觀察／來源 | Finding | 下一步 |
|---|---|---|---|
| E1（source，2026-09-12） | 上述固定 commit 的三個定位實作 | 原始碼確認 App 可走 simulation API，定位流程不需 root helper；本機權限結果仍是 candidate | 用正常權限 Probe 觀察實際送出 |
| E2（command，2026-09-12） | swift test：8 tests、0 failures | 轉接層 1/5/10 Hz、小數秒、失效、缺值、恢復通過合成單元測試 | 真接收器頻率／移動驗證 |
| E3（command，2026-09-12） | wrapper、整合版、Probe 均 BUILD SUCCEEDED | 僅編譯驗證，不代表實機 simulation 有效 | 啟動、授權、有效 GNSS，再切 App |
| E4（device log，2026-09-12） | Build 12：enabled=true、GSA no fix、input/submission=0、simulated=no | no-fix 沒有輸出，未重播舊座標 | 取得有效 fix 後再驗證 |
| E5（device log，2026-09-12） | Build 14：Probe 收到 simulated=true；座標、高度、速度、精度與外接 GNSS 一致，約 1 Hz | system-wide injection 已由獨立 App 實機驗證 | 長時間、鎖屏與不同硬體驗證 |
| E6（device log，2026-09-12） | Apple Maps 前景時，TrollGNSS diagnostics 顯示 background=true、input/submission 約 1 Hz | 短時間背景管線有效 | 十分鐘與鎖屏測試 |

範圍：使用者的 iPadGPS 專案及授權 iPad；不 hook 第三方、不修改定位 daemon、不改接收器設定。以上是工程實作紀錄，非安全漏洞報告（flavor=null）。

## 實機驗收清單

- [x] 追讀 Geranium、TrollBox、locsim source。
- [x] private wrapper 隔離，新增 service／UI，原 USBSerial／NMEAParser 不變。
- [x] adapter 單元測試；逐階段編譯。
- [x] Build 14 安裝工具回報成功。
- [x] App 開啟、系統輸出已啟用；實機 no-fix 狀態不送出位置。
- [x] App 實際開啟、授權定位並收到有效外接 fix。
- [x] Apple Maps 藍點隨外接 GNSS 真實移動。
- [x] 獨立 Location Probe 對照座標、高度、速度、精度、來源與約 1 Hz 頻率。
- [ ] 切換 Apple Maps 至少 10 分鐘，每段診斷記錄持續更新。
- [ ] 鎖屏至少 10 分鐘，檢查 UTC／接收 gap，而不是只看程序仍存在。
- [ ] 拔除 GNSS 停止，重插恢復。
- [ ] 關閉輸出後恢復正常位置；強制終止／重啟後無殘留 simulation。
- [ ] 接收器真實移動下 1、5、10 Hz，分別對比 input／submission／Probe callback rate。
- [ ] 無 JB 啟動狀態下完成上述純 TrollStore 驗證。

測試需要實體移動、拔插、解鎖及定位授權；目前不可把未勾選項目宣稱通過。
