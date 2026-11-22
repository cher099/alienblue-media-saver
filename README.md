# RedAlien RedGIFs Compatibility

A standalone compatibility add-on for RedGIFs links opened in AlienBlue alongside RedAlien 0.0.4.

> **Status:** RedGIFs playback is handed back to RedAlien's normal `vPlayer.html` interface after the MP4 is cached. The native AlienBlue **Save to Photos** action is extended to cached regular videos, RedGIFs MP4s, native Reddit galleries, album galleries, and direct GIF/image URLs. Solo-photo saving remains with AlienBlue's existing handler.

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

The add-on does not replace the player with a separate Save to Photos page and does not change playback or FFmpeg processing. The save action uses the iOS Assets Library API for cached MP4 files and downloaded image bytes, including original GIF data. Existing solo-image saving is passed through to AlienBlue.

## Diagnostics

The tweak writes to `/var/mobile/Library/Logs/RedGIFsCompat.log` and `/tmp/RedGIFsCompat.log`. It records media menu discovery, gallery URL counts, image downloads, and Assets Library success or failure. The `UIActionSheet` hook is limited to AlienBlue browser and gallery contexts; unrelated menus are left alone.

## Important compatibility notes

- RedAlien's original `supportsCopy()` returns true on iOS 5 and later. This implementation initially follows that stream-copy approach rather than forcing a transcode.
- A successful FFmpeg remux only confirms that an MP4 container was produced. It does **not** prove that the source codec/profile is supported by the iOS 6.1.3 native player.
- If copied streams do not play, the next experiment is a fallback transcode using a profile supported by the installed FFmpeg build and iOS 6.
- RedGIFs API endpoints and CDN behavior are unofficial and may change.
- Keep the original RedAlien package available for recovery. A successful ARMv7 build is not proof of successful on-device playback.

## Native AlienBlue Share menu

The tweak targets AlienBlue's browser Share menu when a regular RedAlien video or RedGIFs cached MP4 exists, and gallery/album Share menus when image URLs can be collected from the gallery model. For album pages, it follows `BrowserViewController.optimizer` to `JMAlbumContentOptimizer_iPhone.galleryItems`, where AlienBlue stores its `JMGalleryItem` models. Videos are submitted by file path through `ALAssetsLibrary`, with a compatibility-checked UIKit fallback if the Assets Library callback returns no asset URL; multi-photo galleries and GIFs are saved from their original downloaded image data. Non-media menus and AlienBlue's working single-photo save path are passed through unchanged. This integration still needs on-device testing.

## Upstream attribution

RedAlien is a separate upstream project: https://github.com/spytaspund/redalien

This repository is an independent compatibility add-on, not an official RedAlien or RedGIFs release. The add-on reuses RedAlien's installed runtime dependency and installed HTML templates without copying or modifying its source files. Preserve upstream copyright and license notices if source files are ever copied into this repository.
