# TrollUSBHostKit

A Swift package providing unsandboxed USB host access on iOS/iPadOS, via
IOKit's `AppleUSBHostDeviceUserClient`/`AppleUSBHostInterfaceUserClient` user
clients wrapped by a pinned [utmapp/libusb](https://github.com/utmapp/libusb)
fork (`utm-edition` branch).

Extracted from [TrollScrcpy](https://github.com/andyching168/iPadADB) so it
can be maintained in one place and consumed by multiple projects (TrollScrcpy,
HeadunitPad, ...) instead of each keeping its own copy. See `PRD.md` for scope
and delivery phases.

This package has no dependency on TrollStore, ADB, or any specific app.
TrollStore is just one way a consuming app can obtain the entitlements this
capability requires.

## Usage

```swift
.package(url: "https://github.com/andyching168/TrollUSBHostKit", from: "0.1.0")
```

A consuming app must declare, in its own entitlements:

```xml
<key>com.apple.vm.device-access</key>
<true/>
<key>com.apple.security.exception.iokit-user-client-class</key>
<array>
    <string>AppleUSBHostDeviceUserClient</string>
    <string>AppleUSBHostInterfaceUserClient</string>
</array>
```

How a consuming app obtains and preserves these entitlements is outside
this package's scope. TrollStore is one known environment in which the
required entitlements can be used.

## License

MIT, see [LICENSE](LICENSE). Third-party notices (vendored libusb, LGPL-2.1)
are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
