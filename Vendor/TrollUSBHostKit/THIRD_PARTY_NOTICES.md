# Third-Party Notices

USBHostKit is licensed under the MIT License (see [LICENSE](LICENSE)). It
builds on the following third-party component, under its own license.

## libusb (LGPL-2.1)

- Source: `utmapp/libusb`, branch `utm-edition`, pinned to commit
  `9eaebb714169264c346bcba0100ac650aba40002`.
- Vendored at: `Sources/CLibusb/`.
- License: GNU Lesser General Public License v2.1. Full text and author list
  are vendored unmodified alongside the source at
  `Sources/CLibusb/libusb/COPYING` and `Sources/CLibusb/libusb/AUTHORS`.
- **Relinking / corresponding source**: libusb is linked into `USBHostKit` as
  a static C target, not modified from the pinned commit. Per LGPL-2.1 §6,
  anyone who receives a binary built against this package is entitled to the
  corresponding source and the ability to relink against a modified libusb:
  - The exact pinned source is public at
    `https://github.com/utmapp/libusb/tree/9eaebb714169264c346bcba0100ac650aba40002`
    (branch `utm-edition`).
  - Because libusb is statically linked, relinking requires rebuilding this
    package (and the consuming app) from source against a replacement libusb
    of the same major/minor API version dropped into `Sources/CLibusb/`. This
    package's build (`swift build`) is fully reproducible from source for
    exactly this purpose.

## Apple frameworks

`IOKit`, `CoreFoundation`, and `Security` are used directly from Apple's
system frameworks under Apple's standard SDK license -- no third-party
redistribution applies to these.
