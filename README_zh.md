# TrollGNSS

[English](README.md) | 繁體中文

**讓 Wi-Fi 版 iPad 用平價 USB GNSS 取得系統級定位，直接供 Apple Maps、Google Maps 與其他 `CLLocationManager` App 導航。**

TrollGNSS 是我們所知目前少見、可能是第一個公開且可實際使用的低成本方案：不必購買昂貴的 MFi／專用藍牙 GPS，只需要 TrollStore、一般 USB Serial GNSS 接收器及 USB-C 轉接器。外接 GNSS 的即時座標會成為 iPadOS 的系統定位來源，而不只顯示在本 App 裡。

> 這是使用 TrollStore entitlement 與 Apple private API 的實驗性專案，不適用 App Store。已在 iPadOS 17.0、Wi-Fi 版 iPad 及 u-blox USB GNSS 上實機驗證；其他系統版本、硬體與長時間背景穩定性仍需個別測試。請勿在安全關鍵導航中把它當作唯一定位來源。

## 已實機驗證

- 一般 u-blox USB GNSS 經 `/dev/cu.usbmodem*` 持續讀取 NMEA。
- 解析 latitude、longitude、altitude、speed、course、UTC、DOP、fix quality 及衛星資料。
- 透過 CoreLocation private `CLSimulationManager` 將真實移動位置送入 iPadOS。
- 獨立、沒有注入 entitlement 的 Location Probe 收到 `simulated=true`，座標、高度、速度與精度和外接 GNSS 一致。
- Apple Maps 在前景時，TrollGNSS 仍能於背景以接收器目前的 1 Hz 頻率持續更新。
- GNSS no-fix、資料過期、serial 斷線或手動關閉時會停止並清除 simulation，不重播最後座標。

尚未完成的驗證包括：所有 iPadOS／iPad 型號、鎖屏十分鐘以上、所有 5 Hz／10 Hz 接收器，以及未啟用 jailbreak 狀態的完整回歸。程式本身不呼叫 jailbreak daemon、tweak 或 root helper；SSH 只用於開發階段部署與讀取診斷。

## 資料流

```text
Commodity USB GNSS
        ↓
TrollUSBHostKit / native USB serial
        ↓
existing NMEA parser and GPS UI
        ↓
ExternalGNSSFix
        ↓
SystemLocationInjector
        ↓
iPadOS Core Location
        ↓
Apple Maps / navigation apps / CLLocationManager
```

## 功能

- USB 裝置掃描與 CDC-ACM、FTDI、CP210x、Generic Bulk 辨識。
- 4800 至 115200 bps 選擇。
- NMEA 0183 checksum 與 GGA、RMC、GSA、GSV、VTG、ZDA、GLL parsing。
- 即時儀表、衛星天空圖、GPS／GLONASS 等星系資訊及原始 NMEA。
- 可開關的「系統定位輸出」，顯示 GNSS fix、輸入／輸出頻率、最後送出時間與延遲。
- HDOP × 可調 UERE 的水平精度估算；不把 HDOP 誤稱為公尺。
- 獨立 Location Probe target，以公開 `CLLocationManager` 驗證其他 App 實際收到的資料。
- IORegistry、libusb 與 location injection 診斷。

## 硬體與環境

- TrollStore 相容的 iPad；專案 deployment target 為 iPadOS 16.0。
- USB-C iPad 或合適的 Lightning USB Host 轉接器。
- NMEA 相容 USB Serial GNSS；目前實機接收器為 u-blox `1546:01A8`。
- 若接收器耗電較高，請使用有外接供電的 USB hub。

PL2303、CH34x 及其他 vendor-specific UART 目前可能只會列為 Generic Bulk。若裝置不會自行維持正確 serial 設定，仍需加入對應的 control-transfer driver。

## 建置

需要 Xcode、XcodeGen 與 `ldid`：

```sh
brew install xcodegen ldid
./scripts/build_ipa.sh
```

輸出為 `dist/NMEAPad.ipa`。內部 target、bundle identifier 與檔名暫時保留 `NMEAPad`，以便原地升級已安裝版本；App 顯示名稱為 TrollGNSS。

另建置獨立驗證 App：

```sh
bash scripts/build_location_probe.sh
```

## 安裝

可透過 TrollStore 手動安裝 IPA，或使用 [trollinstall](https://github.com/andyching168/trollinstall)：

```sh
trollinstall doctor
trollinstall install /absolute/path/to/NMEAPad.ipa
```

## 使用

1. 將 USB GNSS 接到 iPad，開啟 TrollGNSS。
2. 在「裝置」選擇裝置與鮑率，按「連線」。
3. 等待有效 2D／3D fix。
4. 在「系統定位」開啟輸出並允許定位權限。
5. 切換 Apple Maps 或其他導航 App。關閉輸出前請回到 TrollGNSS，確認狀態已停止並清除 simulation。

若 App crash 或被系統強制終止，`willTerminate` 不保證執行；重新開啟 App 或使用「緊急停止並清空系統模擬位置」可再次送出清除命令。

## 實作與權限

USB 層使用 [TrollUSBHostKit](https://github.com/andyching168/TrollUSBHostKit)。系統定位輸出參考 [Geranium](https://github.com/c22dev/Geranium)、[TrollBox](https://github.com/c22dev/TrollBox) 與 [locsim](https://github.com/udevsharold/locsim) 的公開實作，private API 集中在 `LocationSimulationBridge.m`。

主要 entitlement：

- `com.apple.vm.device-access`
- `AppleUSBHostDeviceUserClient`
- `AppleUSBHostInterfaceUserClient`
- `com.apple.locationd.simulation`
- `platform-application`
- `com.apple.security.exception.mach-lookup.global-name`：僅允許 `com.apple.locationd.simulation`

Build 14 的關鍵修正是加入 locationd simulation Mach service 的精確 sandbox lookup 例外；只加入 simulation entitlement 與 `platform-application`，在這台 iPadOS 17.0 裝置上仍無法讓其他 App 收到模擬位置。

## 測試

```sh
swift test --package-path Packages/NMEACore
./scripts/build_ipa.sh
bash scripts/build_location_probe.sh
```

目前 8 項 parser／adapter 測試通過，涵蓋 1／5／10 Hz、新 epoch、小數秒、no-fix、過期資料、缺值與恢復。編譯與單元測試不能取代真實道路、鎖屏、拔插及不同裝置的實機驗證。

詳細研究與驗收狀態見 [系統定位研究報告](docs/2026-09-12-system-location-report.md)。

## 授權與第三方元件

TrollGNSS 採 MIT License。Vendored TrollUSBHostKit 包含靜態連結的 LGPL-2.1 libusb fork；散布二進位時必須保留 `Vendor/TrollUSBHostKit/THIRD_PARTY_NOTICES.md`、對應來源與重新連結資訊。
