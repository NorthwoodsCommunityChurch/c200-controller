# Credits

## Frameworks & Libraries

| Name | Description | License |
|------|-------------|---------|
| [Swift](https://swift.org/) | Programming language | [Apache 2.0](https://github.com/apple/swift/blob/main/LICENSE.txt) |
| [SwiftUI](https://developer.apple.com/xcode/swiftui/) | Declarative UI framework | Apple SDK — No separate license |
| [Network.framework](https://developer.apple.com/documentation/network) | Bonjour/mDNS discovery | Apple SDK — No separate license |
| [Foundation](https://developer.apple.com/documentation/foundation) | Networking, persistence | Apple SDK — No separate license |

## Companion Module Dependencies

| Name | Description | License |
|------|-------------|---------|
| [@companion-module/base](https://github.com/bitfocus/companion-module-base) | Bitfocus Companion module SDK | [MIT](https://github.com/bitfocus/companion-module-base/blob/main/LICENSE) |

## ESP32 Firmware Components

| Name | Description | License |
|------|-------------|---------|
| [ESP-IDF](https://github.com/espressif/esp-idf) | Espressif IoT Development Framework | [Apache 2.0](https://github.com/espressif/esp-idf/blob/master/LICENSE) |
| [cJSON](https://github.com/DaveGamble/cJSON) | JSON parser (via espressif__cjson) | [MIT](https://github.com/DaveGamble/cJSON/blob/master/LICENSE) |
| [mDNS](https://github.com/espressif/esp-protocols/tree/master/components/mdns) | mDNS service (via espressif__mdns) | [Apache 2.0](https://github.com/espressif/esp-protocols/blob/master/components/mdns/LICENSE) |
| [LwIP](https://savannah.nongnu.org/projects/lwip/) | TCP/IP stack (bundled in ESP-IDF) | [BSD](https://www.nongnu.org/lwip/) |

## Icons & Assets

- SF Symbols — Apple Inc. (used under Apple's [SF Symbols License](https://developer.apple.com/sf-symbols/))

## Tools

| Name | Description |
|------|-------------|
| [Swift Package Manager](https://www.swift.org/package-manager/) | Dependency management and build |
| [Xcode Command Line Tools](https://developer.apple.com/xcode/) | Swift compiler and build toolchain |
| [idf.py](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-guides/tools/idf-py.html) | ESP-IDF build and flash tool |

## Canon C200 API

Firmware communicates with the Canon C200 using Canon's undocumented Browser Remote HTTP API. API behavior was documented through reverse engineering and is captured in [CANON_C200_API.md](CANON_C200_API.md).

## Inspiration

- Canon EOS Browser Remote API community documentation
- [Bitfocus Companion](https://bitfocus.io/companion) ecosystem for broadcast control integration
