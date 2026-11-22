# RedAlien RedGIFs Compatibility

A standalone compatibility add-on for RedGIFs links opened in AlienBlue alongside RedAlien 0.0.4.

> **Status:** RedGIFs playback is handed back to RedAlien's normal `vPlayer.html` interface after the MP4 is cached. Native Share-menu integration for **Save to Photos** is still in progress; the temporary save page has been removed.

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

## RedGIFs playback flow

1. Intercept only RedGIFs watch/iframe URLs in RedAlien's `RAProtocol`.
2. Resolve the RedGIFs MP4 URL using the RedGIFs API.
3. Download the MP4 to `/var/tmp/redalien/redgifs-<id>/source.mp4`.
4. Use the installed RedAlien FFmpeg executable to prepare a local MP4 in the same cache directory.
5. While processing, show RedAlien's existing loading template and status polling.
6. Once ready, use RedAlien's existing `vPlayer.html` template and local HTTP server URL for playback.

The add-on does not replace the player with a separate Save to Photos page. The existing Assets Library save routine remains available for the planned native AlienBlue Share-menu action. Regular Reddit videos and images are not intentionally intercepted by this add-on.

## Diagnostics

The media worker writes to `/var/mobile/Library/Logs/RedGIFsCompat.log` and `/tmp/RedGIFsCompat.log`. It records download response/completion and byte count, FFmpeg exit status and stderr tail on failure, output MP4 validation and size, template availability, local server port, and status-poll requests. A `UIActionSheet` discovery probe records button titles, delegate class, and cancel-button index to identify AlienBlue's Share menu without modifying unrelated sheets.

## Important compatibility notes

- RedAlien's original `supportsCopy()` returns true on iOS 5 and later. This implementation initially follows that stream-copy approach rather than forcing a transcode.
- A successful FFmpeg remux only confirms that an MP4 container was produced. It does **not** prove that the source codec/profile is supported by the iOS 6.1.3 native player.
- If copied streams do not play, the next experiment is a fallback transcode using a profile supported by the installed FFmpeg build and iOS 6.
- RedGIFs API endpoints and CDN behavior are unofficial and may change.
- Keep the original RedAlien package available for recovery. A successful ARMv7 build is not proof of successful on-device playback.

## Native AlienBlue Share menu

The intended UX is to add **Save to Photos** alongside AlienBlue's existing Share actions. The diagnostic hook logs `UIActionSheet` presentations through `showInView:`; it does not yet add a menu item. Once the exact menu and delegate callback are identified, the existing `ALAssetsLibrary` save routine can be connected to that action.

## Upstream attribution

RedAlien is a separate upstream project: https://github.com/spytaspund/redalien

This repository is an independent compatibility add-on, not an official RedAlien or RedGIFs release. The add-on reuses RedAlien's installed runtime dependency and installed HTML templates without copying or modifying its source files. Preserve upstream copyright and license notices if source files are ever copied into this repository.
