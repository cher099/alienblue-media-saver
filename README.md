# AlienBlue Media Saver

A lightweight MobileSubstrate tweak focused on **saving media from AlienBlue** on legacy iOS devices. It extends AlienBlue's native **Save to Photos** action to supported videos, RedGIFs MP4s, multi-image Reddit galleries, album galleries, and direct GIF/image URLs.

It also brings RedGIFs MP4 media into RedAlien's FFmpeg processing workflow. **This add-on does not implement RedGIFs playback in AlienBlue**; its focus is media saving and FFmpeg-based media preparation.

> **Tested setup:** iPhone 4S · iOS 6.1.3 · ARMv7 · AlienBlue · RedAlien 0.0.4  
> The maintainer confirmed that the supported save paths, progress indicator, and completion alerts work on the target device with v0.2.13. v0.2.15 is a package-metadata and documentation update on top of that tested implementation.

## What it does

- **Save regular Reddit videos:** Saves a cached video through iOS' Assets Library API, preserving the working legacy iOS callback behavior.
- **Process RedGIFs through FFmpeg:** Resolves and downloads the RedGIFs MP4, then sends it through RedAlien's installed FFmpeg workflow. In the currently tested implementation, FFmpeg uses stream copy (`-c copy`) to remux the source into an MP4 container; it does not re-encode the streams.
- **Save RedGIFs videos:** Attempts to save the cached MP4. If iOS 6 does not create a Camera Roll asset, a separate AVFoundation export is made for the save attempt. The original cached media file is not overwritten.
- **Save Reddit and album galleries:** Collects image URLs from native Reddit gallery metadata, legacy preview data, or AlienBlue's album optimizer.
- **Save GIFs and direct images:** Downloads the original image bytes and submits them to the photo library, preserving GIF data.
- **Show progress:** Gallery batches are processed one at a time with an item counter and progress bar. Video saves show an activity indicator during the save/export operation.
- **Confirm completion:** An alert reports the number of gallery images saved and any failures, or the result of a video save.
- **Preserve single-photo saving:** AlienBlue's existing single-photo handler is deliberately left unchanged.

## How to use

1. Install AlienBlue Media Saver alongside the required RedAlien and FFmpeg dependencies.
2. Open a supported Reddit video, RedGIFs post, gallery, or album in AlienBlue.
3. Open AlienBlue's **Share** menu.
4. Choose **Save to Photos**.
5. For multi-image batches, watch the progress bar; a completion alert appears when processing finishes.

The tweak only attaches its save action to recognized AlienBlue browser/gallery media contexts. Unrelated menus are left alone.

## RedGIFs and FFmpeg

The add-on retrieves the RedGIFs MP4 and feeds it into the FFmpeg workflow supplied by RedAlien. This makes RedGIFs media processable through the existing FFmpeg path used by the tweak.

In the currently tested implementation, the FFmpeg command uses stream copy (`-c copy`) and `-movflags +faststart`. That operation is **remuxing**, not a codec re-encode: it places the existing audio/video streams into an MP4 container without changing their codecs. It is important to be precise about that distinction—the current build does not force a new H.264 encode.

**AlienBlue Media Saver does not add RedGIFs playback to AlienBlue and does not guarantee that an FFmpeg-generated MP4 will play on iOS 6.1.3.** Its RedGIFs role is retrieval and FFmpeg media preparation, alongside the Save to Photos functionality.

For Camera Roll saving, the tweak has a separate RedGIFs-only AVFoundation fallback. When Assets Library returns no asset URL (including the iOS 6 nil-error case), AVFoundation exports a separate 640x480/medium-quality MP4 or MOV copy and tries saving that copy. The original cached file remains untouched.

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

The Debian package identifier remains `dev.cherwin.redalien.redgifs` so updates install over previous versions rather than requiring a separate package identity.

## How this was built: vibe-coded with ChatGPT

This project was developed through a **vibe-coding workflow with ChatGPT as the primary implementation partner**. ChatGPT helped generate and iterate on the implementation, debugging changes, build fixes, and documentation.

Cherwin supplied the requirements, device and compatibility context, and the technical fundamentals used to guide the implementation. He reviewed the generated changes with those fundamentals in mind—especially looking for unsafe operations, unintended behavior, and changes that could disturb AlienBlue or RedAlien—and performed the real-device testing on the iPhone 4S.

In other words: **the implementation was largely AI-assisted/vibe-coded; the project direction, sanity-checking, and device validation were human-led.**

This should not be mistaken for a formal security audit. Human review and successful device testing reduce risk, but they do not guarantee that every code path is safe or free of bugs. AI-generated code can still contain mistakes. Review changes and keep a recovery path before installing tweaks on a primary device.

## Implementation boundaries

- The primary purpose is adding and improving **Save to Photos** support in AlienBlue.
- RedGIFs retrieval and FFmpeg processing make the media available to the existing processing workflow; this add-on does not implement RedGIFs playback.
- The RedGIFs Camera Roll export is a separate save-only fallback.
- RedAlien's installed FFmpeg executable and package dependency are reused; this project does not bundle its own FFmpeg binary.
- AlienBlue's existing single-photo save handler is passed through unchanged.
- Unrelated AlienBlue action sheets and menus are left alone.

## Diagnostics

The tweak writes diagnostic logs to:

- `/var/mobile/Library/Logs/RedGIFsCompat.log`
- `/tmp/RedGIFsCompat.log`

The historic `RedGIFsCompat` log/file naming is retained internally; the user-facing project name is **AlienBlue Media Saver**.

## Building

Build with Theos for ARMv7:

```sh
make package FINALPACKAGE=1
```

GitHub Actions also builds the Debian package and uploads it as a workflow artifact. A successful build confirms that the package compiles for ARMv7; it does not replace testing on the target device and iOS version.

## Credits and attribution

- **ChatGPT / OpenAI:** AI coding partner used throughout implementation, debugging, and documentation.
- **Cherwin:** Project direction, requirements, technical review, and device testing.
- **RedAlien:** Required upstream runtime dependency: https://github.com/spytaspund/redalien

AlienBlue Media Saver is an independent community add-on. It is not an official release of AlienBlue, Reddit, RedGIFs, or RedAlien.