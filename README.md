# RedAlien RedGIFs Compatibility

A standalone compatibility add-on intended to make RedGIFs links playable in AlienBlue when used alongside RedAlien 0.0.4 on legacy jailbroken iOS devices.

> **Status: early development.** No working RedGIFs interception, media resolver, or installable add-on package has been validated yet.

## Project goals

- Detect RedGIFs watch links opened from AlienBlue.
- Extract the RedGIFs GIF identifier.
- Resolve a playable media URL using RedGIFs' available web/API behavior.
- Hand off playback through a method compatible with legacy iOS.
- Preserve the existing RedAlien installation and its files.
- Build a separate Debian package (`.deb`) for testing.

## Target environment

| Item | Target |
| --- | --- |
| Device | iPhone 4S |
| iOS | 6.1.3 |
| CPU architecture | ARMv7 |
| Existing player | AlienBlue |
| Existing tweak | RedAlien 0.0.4 |
| Development host | Windows |
| Build system | GitHub Actions (planned) |

Compatibility with this environment must be confirmed by actual builds and device tests.

## Design constraints

1. **Do not overwrite RedAlien.** The add-on should have its own package identifier and install paths.
2. **Verify integration before implementation.** RedAlien's internal functions are not automatically callable from a separate tweak. The integration point must be established from source and runtime behavior.
3. **Use legacy-compatible media.** Prefer a media format and codec profile supported by iOS 6.1.3; do not assume every RedGIFs MP4 is compatible.
4. **Treat RedGIFs API behavior as changeable.** Any unofficial endpoints, authentication flow, headers, or response fields must be tested and handled defensively.
5. **Do not install untested builds on the primary device.** Keep the original RedAlien package available for recovery.

## Planned architecture

1. URL detection for supported RedGIFs hosts and watch-link formats.
2. GIF ID parsing and URL normalization.
3. RedGIFs media resolution, including error handling.
4. A verified handoff to an existing player or a self-contained playback path.
5. Separate package metadata and installation files.
6. Automated ARMv7 build and package artifact upload.

The exact hook and playback architecture remains undecided pending source inspection and compatibility testing.

## Repository layout (planned)

```text
.
├── README.md
├── Makefile
├── control
├── Tweak.x
├── Sources/
└── .github/
    └── workflows/
        └── build.yml
```

The layout will be adjusted to match the selected Theos project structure.

## Build

Automated GitHub Actions builds are planned. The workflow must use a toolchain and SDK that can compile for the target iOS version and ARMv7. A successful workflow run is not sufficient by itself: the resulting package must also be inspected and tested on-device.

## Installation

No release package is available yet. Do not install placeholder or experimental packages. When a validated build is published, installation and removal instructions will be documented here.

## Testing checklist

- [ ] Confirm RedAlien 0.0.4 source and package metadata.
- [ ] Identify safe integration points without modifying RedAlien.
- [ ] Verify RedGIFs link formats and media-resolution behavior.
- [ ] Verify the resolved media codec/container is compatible with iOS 6.1.3.
- [ ] Build an ARMv7 package in GitHub Actions.
- [ ] Inspect package identifier, dependencies, paths, and install scripts.
- [ ] Test playback and failure handling on the iPhone 4S.
- [ ] Confirm removing the add-on leaves RedAlien unchanged.

## License and attribution

RedAlien is a separate upstream project: https://github.com/spytaspund/redalien

This repository is an independent compatibility project and is not an official RedAlien or RedGIFs release. Before copying or redistributing upstream source files, preserve their applicable copyright notices and license terms. The add-on's license will be declared after its source and dependency provenance are finalized.

## Contributing

Please document device/iOS versions, exact RedGIFs URL format, reproduction steps, and relevant logs when reporting an issue. Do not include account credentials, private tokens, or other secrets.
