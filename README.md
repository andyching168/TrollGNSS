# TrollGNSS

English | [繁體中文](README_zh.md)

**Give a Wi-Fi-only iPad system-wide location from an affordable USB GNSS receiver, usable directly by Apple Maps, Google Maps, and other `CLLocationManager` apps.**

To the best of our knowledge, TrollGNSS is one of the first—and possibly the first—public, practical, low-cost approaches to this problem. It replaces the need for an expensive MFi or specialized Bluetooth GPS with TrollStore, a commodity USB serial GNSS receiver, and a USB-C adapter. Live external coordinates become an iPadOS system location source instead of remaining confined to one dashboard app.

> TrollGNSS is an experimental TrollStore project that uses private Apple APIs and entitlements. It is not suitable for the App Store. It has been tested on iPadOS 17.0 with a Wi-Fi-only iPad and a u-blox USB GNSS receiver. Other OS versions, hardware, and long-running background behavior require separate validation. Do not use it as the sole location source for safety-critical navigation.

## Verified on a physical device

- Continuously reads NMEA from a commodity u-blox receiver through `/dev/cu.usbmodem*`.
- Parses latitude, longitude, altitude, speed, course, UTC, DOP, fix quality, and satellite data.
- Feeds real movement into iPadOS through CoreLocation's private `CLSimulationManager`.
- An independent Location Probe without injection entitlements receives `simulated=true`; coordinates, altitude, speed, and accuracy match the external receiver.
- TrollGNSS continues updating at the receiver's current 1 Hz rate in the background while Apple Maps is in front.
- Stops and clears simulation on no-fix, stale data, serial disconnection, or manual shutdown instead of replaying the last coordinate.

Not yet validated: every iPadOS/iPad combination, screen locking for ten minutes or longer, physical 5 Hz/10 Hz receivers, and a full regression while the jailbreak is not activated. The app itself does not call a jailbreak daemon, tweak, or root helper. SSH was used only for development deployment and diagnostics.

## Data flow

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

## Features

- USB discovery with CDC-ACM, FTDI, CP210x, and Generic Bulk detection.
- Selectable baud rates from 4800 through 115200 bps.
- NMEA 0183 checksums and GGA, RMC, GSA, GSV, VTG, ZDA, and GLL parsing.
- Live dashboard, satellite sky plot, constellation details, and raw NMEA view.
- Switchable system-location output with fix state, input/output rate, last submission, and latency.
- Configurable `HDOP × UERE` horizontal-accuracy estimate; HDOP is not misrepresented as meters.
- Independent Location Probe target using only public `CLLocationManager` APIs.
- IORegistry, libusb, and injection diagnostics.
- English and Traditional Chinese UI.

## Requirements

- A TrollStore-compatible iPad. The project deployment target is iPadOS 16.0.
- A USB-C iPad or an appropriate Lightning USB Host adapter.
- An NMEA-compatible USB serial GNSS receiver. The tested receiver is u-blox `1546:01A8`.
- A powered USB hub if the receiver draws more power than the iPad can provide.

PL2303, CH34x, and other vendor-specific UARTs may currently appear only as Generic Bulk. A device that does not retain the correct serial configuration in firmware still needs a matching control-transfer driver.

## Build

Install Xcode, XcodeGen, and `ldid`:

```sh
brew install xcodegen ldid
./scripts/build_ipa.sh
```

The resulting IPA is `dist/NMEAPad.ipa`. Internal target, bundle identifier, and file names intentionally remain `NMEAPad` so existing installations can be upgraded in place; the displayed app name is TrollGNSS.

Build the independent observer app with:

```sh
bash scripts/build_location_probe.sh
```

## Install

Install the IPA manually with TrollStore, or use [trollinstall](https://github.com/andyching168/trollinstall):

```sh
trollinstall doctor
trollinstall install /absolute/path/to/NMEAPad.ipa
```

## Use

1. Connect the USB GNSS receiver to the iPad and open TrollGNSS.
2. Select the device and baud rate under Device, then tap Connect.
3. Wait for a valid 2D or 3D fix.
4. Enable System Location Output and grant location permission.
5. Switch to Apple Maps or another navigation app. Before disconnecting hardware, return to TrollGNSS, disable output, and confirm that simulation was stopped and cleared.

`willTerminate` is not guaranteed after a crash or forced termination. Reopen TrollGNSS or use **Emergency stop and clear simulated location** to issue another cleanup command.

## Implementation and entitlements

The USB layer uses [TrollUSBHostKit](https://github.com/andyching168/TrollUSBHostKit). System location output is based on the open-source implementations in [Geranium](https://github.com/c22dev/Geranium), [TrollBox](https://github.com/c22dev/TrollBox), and [locsim](https://github.com/udevsharold/locsim). All private API calls are isolated in `LocationSimulationBridge.m`.

Principal entitlements:

- `com.apple.vm.device-access`
- `AppleUSBHostDeviceUserClient`
- `AppleUSBHostInterfaceUserClient`
- `com.apple.locationd.simulation`
- `platform-application`
- `com.apple.security.exception.mach-lookup.global-name`, restricted to `com.apple.locationd.simulation`

Build 14's key fix was the precise sandbox lookup exception for the locationd simulation Mach service. On the tested iPadOS 17.0 device, the simulation entitlement and `platform-application` alone did not make the location visible to other apps.

## Test

```sh
swift test --package-path Packages/NMEACore
./scripts/build_ipa.sh
bash scripts/build_location_probe.sh
```

Eight parser/adapter tests currently cover 1/5/10 Hz input, unique epochs, fractional seconds, no-fix, stale data, unavailable fields, and recovery. Compilation and unit tests do not replace real road, lock-screen, hot-plug, and cross-device tests.

See the [system-location research and acceptance report](docs/2026-09-12-system-location-report.md) for implementation evidence and open validation items.

## License and third-party components

TrollGNSS is licensed under the MIT License. The vendored TrollUSBHostKit contains a statically linked LGPL-2.1 libusb fork. Binary redistribution must retain `Vendor/TrollUSBHostKit/THIRD_PARTY_NOTICES.md`, corresponding source, and relinking information.
