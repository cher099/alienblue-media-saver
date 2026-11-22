# RedAlien RedGIFs Compatibility

A standalone compatibility add-on for RedGIFs links opened in AlienBlue alongside RedAlien 0.0.4.

 > **Status: Save to Photos-focused build 0.2.3.** Inline playback is intentionally out of scope. The add-on resolves and downloads RedGIFs videos, then presents a simple Save to Photos action. The save tap is intercepted through the embedded UIWebView navigation delegate.

## Target environment

| Item | Target |
| --- | --- |
| Device | iPhone 4S |
| iOS | 6.1.3 |
| CPU architecture | ARMv7 |
| Client | AlienBlue |
| Existing tweak | RedAlien 0.0.4 |
| Development host | Windows |
| Build system | GitHub Actions / Theos |

## Save-to-Photos flow

The add-on keeps its own package identifier and does not overwrite RedAlien files.

1. Intercept a RedGIFs watch/iframe URL in RedAlien's `RAProtocol`.
2. Resolve the RedGIFs MP4 URL using the RedGIFs API.
3. Download the MP4 to `/var/tmp/redalien/redgifs-<id>/source.mp4`.
4. Use the installed RedAlien FFmpeg executable to prepare a local MP4 in the same cache directory.
5. Display a lightweight **Save to Photos** page; no inline video player is used.
6. Intercept the button's custom URL at the `UIWebView` navigation-delegate level and call iOS 6's Assets Library API to save the cached MP4 to Camera Roll.

Saving is user-initiated. The add-on does not automatically add videos to Photos. The `redgifs-` cache prefix keeps files separate from ordinary Reddit video IDs.

## 0.2.1 diagnostics

The media worker now writes to the same persistent log files as the main tweak (`/var/mobile/Library/Logs/RedGIFsCompat.log` and `/tmp/RedGIFsCompat.log`). It records download response/completion and byte count, FFmpeg exit status and stderr tail on failure, output MP4 validation and size, template availability, local server port, and a localhost HTTP byte-range probe against the final MP4. The hook also records RedAlien status-poll requests. These diagnostics are intended to distinguish a processing failure from a local-server or WebView handoff failure.

## Important compatibility notes

- RedAlien's original `supportsCopy()` returns true on iOS 5 and later. This implementation initially follows that stream-copy approach rather than forcing a transcode.
- A successful FFmpeg remux only confirms that an MP4 container was produced. It does **not** prove that the source codec/profile is supported by the iOS 6.1.3 native player.
- If the copied streams do not play, the next experiment is a fallback transcode using a profile supported by the installed FFmpeg build and iOS 6.
- RedGIFs API endpoints and CDN behavior are unofficial and may change.
- Keep the original RedAlien package available for recovery. Do not install an artifact until the ARMv7 build and package contents have been inspected.

## Build

GitHub Actions builds the ARMv7 package on pushes to the main and integration branches, and on pull requests targeting main. A successful build is not equivalent to successful on-device playback.

## Testing checklist

- [x] Inspect RedAlien 0.0.4 source and package metadata.
- [x] Verify the existing RedAlien cache, status, local-server, and player-template interfaces.
- [x] Verify the diagnostic add-on loads and resolves RedGIFs MP4 URLs on-device.
- [x] Build the FFmpeg playback integration for ARMv7.
- [x] Inspect the generated Debian package and dependency metadata.
- [ ] Confirm the 0.2.1 diagnostic build compiles and package metadata is correct.
- [ ] Confirm the device can download the resolved MP4.
- [ ] Confirm the installed FFmpeg executable can remux it.
- [ ] Confirm the local server serves the resulting MP4 and status file; inspect the new HTTP probe and status-poll log entries.
- [ ] Confirm playback in AlienBlue on iOS 6.1.3.
- [ ] Confirm ordinary Reddit video playback remains unchanged.

## Upstream attribution

RedAlien is a separate upstream project: https://github.com/spytaspund/redalien

This repository is an independent compatibility add-on, not an official RedAlien or RedGIFs release. The add-on reuses RedAlien's installed runtime dependency and installed HTML templates without copying or modifying its source files. Preserve upstream copyright and license notices if source files are ever copied into this repository.


## Save to Photos (0.2.3)

The page shows a single **Save to Photos** button after the MP4 is ready. Its custom URL is intercepted by the UIWebView delegate, rather than relying on UIApplication's `openURL:` path. The save operation uses `ALAssetsLibrary` and logs completion or errors to `/var/mobile/Library/Logs/RedGIFsCompat.log` and `/tmp/RedGIFsCompat.log`.

Inline playback is intentionally not supported in this release.
