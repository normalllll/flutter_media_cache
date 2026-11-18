## 0.2.0

- Downloads now run at most 12 at once by default, through `MediaDownloadSlots`; the newest waiting request starts first and
  a request unwatched while it waits never opens. Pass `slots` to `CachedMediaImage` for a limit of its own.
- `CachedMediaImage.timeout` fails a download that gets no data for that long, counted from when it gets its slot.
- `CachedMediaImage.firstFrameOnly` plays only the first frame of an animated picture.
- `CachedMediaImage.retainDecoded: false` drops the decoded picture from the image cache with its last listener.
- `CachedMediaImage.progressive` shows a progressive JPEG scan by scan while it downloads; `showsFinalPicture` tells the
  final picture from a preview.
- `MediaSource.shouldRetry` stops retrying errors another try cannot fix.
- Clearing the image cache no longer cancels a load that a widget still listens to.

## 0.1.0

- `CachedMediaImage`: an image provider over memory (Flutter's image cache or one of the caller's), a `MediaStore` and any
  fetch, with retries, decoding to a box and kept bytes. A fetch no one listens to any more is cancelled.
- `MediaDiskCache`: a `MediaStore` of files named by the SHA-256 of their key, written atomically, trimmed by age and size on a
  background isolate, measured and cleared for a "clear cache" control. `forApp` keeps them in the platform's place for a
  cache.
- `HttpMediaSource` for plain HTTP; `MediaSource` for any other client.
- `mediaDecodeBox` and `limitDecodedPictureCache`.
