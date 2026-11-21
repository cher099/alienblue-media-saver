# Integration design: RedAlien 0.0.4

## Confirmed from the supplied 0.0.4 source

- `Tweak.x` registers `RAProtocol` with `NSURLProtocol`.
- RedAlien also inserts `RAProtocol` into default and ephemeral `NSURLSessionConfiguration` protocol class lists.
- `RAProtocol +canInitWithRequest:` currently accepts a defined set of Reddit, Reddit-media, Imgur, and AlienBlue static hosts. RedGIFs hosts are not included.
- `RAProtocol -startLoading` dispatches `-patchRequest:` to a background selector.
- `RAProtocol -patchRequest:` contains the `v.redd.it` response branch and uses `respondWithStatus:headers:body:` to return a response.
- `videoResponse(videoID)` checks RedAlien's cache for `video.mp4`; when present, it returns the existing HTML player response. Otherwise it queues RedAlien's Reddit HLS-to-MP4 processing path.
- RedAlien's Makefile targets iOS 3.0+ and builds armv6/armv7. Its package depends on MobileSubstrate and `dev.spytaspund.ffmpeg`.

## Proposed add-on integration

The first integration candidate is a MobileSubstrate hook on the existing `RAProtocol` class:

1. Hook `+canInitWithRequest:` and return YES for supported RedGIFs hosts; defer all other requests to the original implementation.
2. Hook `-patchRequest:` and handle only recognized RedGIFs watch/media requests.
3. For all non-RedGIFs requests, call the original implementation unchanged.
4. Resolve the RedGIFs ID to a direct media URL, then use a verified playback handoff.
5. Keep the add-on package identifier, dylib, preference files, and cache separate from RedAlien.

## Critical integration constraint

A separate tweak cannot directly call a C function such as `videoResponse()` merely because that function exists in RedAlien's source or binary. It would need an exported symbol with a stable ABI, a runtime-accessible Objective-C interface, or a different handoff. The add-on must not assume that RedAlien's internal cache path or local HTTP server is a public API.

The preferred first prototype is therefore to hook `RAProtocol` and provide its own RedGIFs response/playback path unless testing establishes a safe existing handoff.

## Questions to settle before device installation

- Confirm the exact AlienBlue app bundle identifier / process filter on the user's device.
- Confirm which RedGIFs hosts and URL forms AlienBlue actually requests.
- Verify current RedGIFs media resolution and authentication behavior.
- Check the resulting MP4 codec/profile against iOS 6.1.3 playback support.
- Verify Logos hook compatibility with the Theos SDK/toolchain selected for the build.

## Source provenance

Based on the user-provided RedAlien 0.0.4 source archive and package metadata. This document describes a proposed integration, not a tested implementation.


## Prototype implementation status (2026-11-22)

The add-on now contains an initial runtime hook prototype in `Tweak.xm`:

- Hooks `RAProtocol +canInitWithRequest:` to recognize only `redgifs.com/watch/<id>` and `redgifs.com/ifr/<id>` URLs.
- Hooks `RAProtocol -patchRequest:` and leaves every non-RedGIFs request on RedAlien's original implementation.
- Requests a temporary RedGIFs API token, then requests `/v2/gifs/<id>` using the same User-Agent.
- Sends the RedGIFs Referer, Origin, and `x-customheader` metadata headers; retries once after HTTP 401.
- Prefers the SD media URL, falling back to HD, and returns a minimal HTML5 video page.

### Not yet verified

- The hook install assumes `RAProtocol` and both selectors exist when this tweak's constructor runs. The code logs and exits if they do not.
- The current package filter bundle identifiers have not been confirmed on the target device.
- The RedGIFs API calls have not yet been exercised from iOS 6.1.3.
- Direct MP4 playback, media-host request validation, and H.264/AAC compatibility have not been tested on the iPhone 4S.
- The implementation currently fetches a fresh temporary token per watch request; token caching is intentionally deferred.
- Build success, if achieved, proves compilation/package creation only—not runtime hook installation or video playback.

This is an experimental first functional increment, not a device-ready release.
