## 0.1.0

- `CachedMediaImage`: an image provider over memory (Flutter's image cache or one of the caller's), a `MediaStore` and any
  fetch, with retries, decoding to a box and kept bytes.
- `MediaDiskCache`: a `MediaStore` of files named by the SHA-256 of their key, written atomically, trimmed by age and size on a
  background isolate, measured and cleared for a "clear cache" control. `forApp` keeps them in the platform's place for a
  cache.
- `HttpMediaSource` for plain HTTP; `MediaSource` for any other client.
- `mediaDecodeBox` and `limitDecodedPictureCache`.
