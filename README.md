# RedAlien RedGIFs Compatibility

A standalone compatibility add-on for RedGIFs links opened in AlienBlue alongside RedAlien 0.0.4.

> **Status: implementation branch — build and device testing pending.** The existing diagnostic build has verified that the tweak loads in AlienBlue, hooks RAProtocol, recognizes RedGIFs URLs, and resolves an MP4 URL. This branch replaces the direct HTML5 remote-video response with RedAlien's local video playback flow.

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

## Playback integration

The add-on keeps its own package identifier and does not overwrite RedAlien files.

1. Intercept a RedGIFs watch/iframe URL in `RAProtocol`.
2. Resolve the RedGIFs MP4 URL using the existing API resolver.
3. Download the MP4 to `/var/tmp/redalien/redgifs-<id>/source.mp4` using a streamed `NSURLConnection` download (150 MB safety limit).
4. Invoke the already-installed `ffmpeg` executable supplied by RedAlien's `dev.spytaspund.ffmpeg` dependency. The initial implementation remuxes with stream copy and `+faststart`; it does not re-encode.
5. Write the resulting `video.mp4` and `status.js` under the same cache root RedAlien already uses.
6. Reuse RedAlien's `vLoading.html`, its `v.redd.it/<id>/status.js` status route, local HTTP server (including byte-range support), and `vPlayer.html`.

The `redgifs-` cache prefix keeps these files separate from ordinary Reddit video IDs. The add-on does not modify the original RedAlien package or its templates.

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
- [ ] Confirm the device can download the resolved MP4.
- [ ] Confirm the installed FFmpeg executable can remux it.
- [ ] Confirm the local server serves the resulting MP4 and status file.
- [ ] Confirm playback in AlienBlue on iOS 6.1.3.
- [ ] Confirm ordinary Reddit video playback remains unchanged.

## Upstream attribution

RedAlien is a separate upstream project: https://github.com/spytaspund/redalien

This repository is an independent compatibility add-on, not an official RedAlien or RedGIFs release. The add-on reuses RedAlien's installed runtime dependency and installed HTML templates without copying or modifying its source files. Preserve upstream copyright and license notices if source files are ever copied into this repository.
