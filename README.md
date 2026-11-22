# AlienBlue Media Saver

A lightweight MobileSubstrate tweak that extends AlienBlue's native **Save to Photos** action to more media types on legacy iOS devices.

It adds save support for cached Reddit videos, RedGIFs videos, multi-image Reddit galleries, album galleries, and direct GIF/image URLs. AlienBlue's existing single-photo save handler is deliberately left alone.

> **Tested setup:** iPhone 4S · iOS 6.1.3 · ARMv7 · AlienBlue · RedAlien 0.0.4  
> The maintainer has confirmed that all supported media save paths, including the progress indicator and completion alerts, work on the target device with v0.2.13. Version 0.2.14 is a branding/documentation/package-metadata update on top of that tested code.

## Features

- **Regular Reddit videos:** Saves RedAlien's cached video file through iOS' Assets Library API, preserving the known-good legacy iOS callback behavior.
- **RedGIFs videos:** Saves the cached MP4. When iOS 6 cannot add the original file to the Camera Roll, a separate AVFoundation compatibility export is created for saving. The playback cache is not overwritten.
- **Reddit galleries and album galleries:** Collects image URLs from native Reddit gallery metadata, legacy preview data, or AlienBlue's album optimizer.
- **GIFs and direct image URLs:** Downloads the original image bytes and submits them to the photo library, preserving GIF data.
- **Progress feedback:** Gallery batches are processed sequentially and show an item counter plus a progress bar. Video saves show an activity indicator while the save/export operation runs.
- **Completion feedback:** The final alert reports the number of gallery images saved and any failures, or the result of a video save.
- **Native single-photo behavior:** AlienBlue's original single-photo handler is passed through unchanged.

## How to use

1. Install AlienBlue Media Saver alongside the required RedAlien dependency.
2. Open a supported Reddit video, RedGIFs post, gallery, or album in AlienBlue.
3. Open AlienBlue's **Share** menu.
4. Choose **Save to Photos**.
5. For multi-image batches, watch the progress bar; an alert appears when processing finishes.

The add-on only attaches its save action to recognized AlienBlue browser/gallery media contexts. Unrelated menus are left alone.

## Compatibility and dependencies

| Item | Target |
| --- | --- |
| Device used for validation | iPhone 4S |
| iOS | 6.1.3 |
| Architecture | ARMv7 |
| Client | AlienBlue |
| RedAlien | 0.0.4 or later |
| Build system | Theos / GitHub Actions |

Package dependencies:

- MobileSubstrate
- RedAlien 0.0.4 or later (`dev.spytaspund.redalien`)
- RedAlien's FFmpeg package (`dev.spytaspund.ffmpeg`)

The package identifier remains `dev.cherwin.redalien.redgifs` so branding updates can be installed as an upgrade over previous versions rather than requiring a separate package identity.

## How this was built: vibe-coded with ChatGPT

This project was developed through a **vibe-coding workflow with ChatGPT as the primary implementation partner**. ChatGPT helped generate and iterate on the implementation, debugging changes, build fixes, and documentation.

Cherwin supplied the requirements, device and compatibility context, and the technical fundamentals used to guide the implementation. He reviewed the generated changes with those fundamentals in mind—especially looking for unsafe operations, unintended behavior, and changes that could disturb AlienBlue or RedAlien—and performed the real-device testing on the iPhone 4S.

In other words: **the implementation was largely AI-assisted/vibe-coded; the project direction, sanity-checking, and device validation were human-led.**

This should not be mistaken for a formal security audit. Human review and successful device testing reduce risk, but they do not guarantee that every code path is safe or free of bugs. AI-generated code can still contain mistakes. Review changes and keep a recovery path before installing tweaks on a primary device.

## Implementation notes

### RedGIFs playback

RedGIFs links are intercepted in RedAlien's `RAProtocol`. The add-on resolves the media URL through the RedGIFs API and hands the resulting cached video back to RedAlien's normal `vPlayer.html` playback interface.

### Save-to-Photos behavior

The add-on works with AlienBlue's existing Share menu and adds a context-aware **Save to Photos** action for supported videos and galleries. Regular videos use the existing Assets Library path. RedGIFs has a save-only AVFoundation fallback because iOS 6 can return a nil asset URL without an NSError even when no photo-library asset was created.

The compatibility export is written as a separate `camera-roll.mp4` or `camera-roll.mov` file in the RedGIFs cache directory. The original cached `video.mp4` used for playback is kept intact. The export uses the 640x480 preset when available, falling back to medium quality.

Gallery images are downloaded and saved one at a time. The next image begins after the previous photo-library callback, allowing the progress count to track completed items. A completion alert distinguishes full success, partial success, and failure.

### What this add-on does not change

- RedAlien's playback UI and normal player handoff.
- RedAlien's normal cached MP4 generation / FFmpeg processing.
- The original cached RedGIFs playback MP4 when making a Camera Roll-compatible copy.
- AlienBlue's existing native single-photo save handler.
- Unrelated AlienBlue action sheets and menus.

## Diagnostics

The tweak writes diagnostic logs to:

- `/var/mobile/Library/Logs/RedGIFsCompat.log`
- `/tmp/RedGIFsCompat.log`

The historic `RedGIFsCompat` log/file naming is retained internally for compatibility and easier diagnosis; the user-facing project name is **AlienBlue Media Saver**.

## Building

Build with Theos for ARMv7:

```sh
make package FINALPACKAGE=1
```

The GitHub Actions workflow also builds the Debian package and uploads it as a workflow artifact.

A successful build confirms that the package compiles for ARMv7; it does not replace testing on the target device and iOS version.

## Credits and attribution

- **ChatGPT / OpenAI:** AI coding partner used throughout implementation, debugging, and documentation.
- **Cherwin:** Project direction, requirements, technical review, and device testing.
- **RedAlien:** This add-on integrates with the separate upstream project: https://github.com/spytaspund/redalien

AlienBlue Media Saver is an independent community compatibility add-on. It is not an official release of AlienBlue, Reddit, RedGIFs, or RedAlien. It reuses RedAlien's installed runtime dependency and installed HTML templates without copying or modifying its source files. Preserve upstream copyright and license notices if source files are ever copied into this repository.
