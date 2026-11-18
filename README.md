# flutter_media_cache

An `ImageProvider` for network images that caches decoded images in memory and encoded files on disk, and fetches them
through any transport: plain HTTP, or your own client with its proxy, headers and authentication.

- Works with any widget that takes an `ImageProvider`: `Image`, `DecorationImage`, `CircleAvatar` and the like.
- Memory: Flutter's `ImageCache` (or one of your own), so equal images share one decoded copy.
- Disk: one file per key, written atomically, trimmed by age and total size on a background isolate.
- Fetching: `HttpMediaSource` for plain HTTP, or implement `MediaSource` to use any client.
- Decoding at the drawn size, retries with backoff, download progress, and the encoded bytes on request.
- Every limit and timing is a parameter with a default.

Android, iOS, macOS, Windows and Linux. The web is not supported.

## Installation

```yaml
dependencies:
  flutter_media_cache:
    git:
      url: https://github.com/normalllll/flutter_media_cache.git
```

## Usage

Create one disk cache for the app and start its automatic trimming:

```dart
final imageStore = MediaDiskCache.forApp()..trimAutomatically();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  limitDecodedPictureCache(bytes: 150 << 20);
  runApp(const MyApp());
}
```

Show an image over plain HTTP:

```dart
Image(
  image: CachedMediaImage(HttpMediaSource(Uri.parse('https://example.com/cat.jpg')), store: imageStore),
)
```

Without `store`, an image is cached in memory only.

### Your own transport

Implement `MediaSource` to fetch through any client. `cacheKey` identifies the bytes; sources with equal keys share one image
in memory and one file on disk.

```dart
class ClientSource extends MediaSource {
  const ClientSource(this.client, this.url);

  final MyHttpClient client;
  final String url;

  @override
  String get cacheKey => url;

  @override
  Stream<MediaChunk> open() async* {
    var received = 0;
    final response = await client.get(url);
    await for (final bytes in response.body) {
      received += bytes.length;
      yield MediaChunk(bytes: bytes, received: received, total: response.contentLength);
    }
  }
}
```

Override `cacheOnDisk` to keep a source off the disk, for example images behind a sign-in. Override `description` and
`describe` to keep credentials and signed addresses out of error messages.

## How an image is found

1. **Memory**: the `ImageCache`, keyed by the provider.
2. **Store**: a `MediaStore`, usually a `MediaDiskCache`.
3. **Network**: `MediaSource.open()`, retried on failure.

A fetch that no one listens to any more, such as an image scrolled away before it arrived, is cancelled: the source's stream
is cancelled, nothing is written to the store, and the image leaves the `ImageCache` so a later resolve fetches it again.

An image is written to the store only after its first frame decodes. Stored files are not checked when read: a file that fails
to decode is removed and fetched again, which costs less than checking every read.

## Disk cache

`MediaDiskCache.forApp()` keeps files where a cache belongs on each platform:

- **Windows**: a folder of the app's own under the system's temporary files (`%TEMP%\<app>\media_cache`), which Windows' disk
  cleanup frees. Every app shares `%TEMP%`, so the folder is named after the app (`appName`, by default the executable's name).
- **macOS, Linux, Android, iOS**: the app's cache directory. The temporary directory there is cleared within days or held in
  memory.

Or pass any `directory` to `MediaDiskCache`.

A trim removes files not opened for `maxAge`. While the folder is past `maxBytes` it also removes the files opened longest ago
until `trimmedShare` of the limit is left. Reading a file marks it as opened. `trimAutomatically()` trims a minute after launch,
when the app is hidden (at most once a day), and as soon as writes take the folder past `maxBytes`. All trims run on a
background isolate.

For a "clear cache" control:

```dart
final bytes = await imageStore.measure(); // counted on a background isolate
await imageStore.clear();
```

Any other storage can implement `MediaStore` (`read`, `write`, `remove`).

## Memory cache

`limitDecodedPictureCache` bounds Flutter's image cache by bytes, with room for many images so the count does not fill first.
The cache counts four bytes a pixel, while Impeller also keeps each image's mip levels, so the graphics memory held is over a
third more than the budget. Pass `imageCache` to keep a kind of image in a cache of its own, with its own limits.

## Decoding at the drawn size

An image that is far larger than its frame can be decoded no larger than it is drawn:

```dart
LayoutBuilder(
  builder: (context, constraints) => Image(
    image: CachedMediaImage(
      source,
      store: imageStore,
      decodeBox: mediaDecodeBox(context, constraints, aspectRatio: 16 / 9),
      decodeFit: BoxFit.cover,
    ),
    fit: BoxFit.cover,
  ),
)
```

The box is rounded up in steps, so resizing a window does not decode again at every width. Each box is an image of its own in
both caches: use it where an image is shown at one size, not for one shown elsewhere at other sizes.

## Download limit

Downloads run through `MediaDownloadSlots`, 12 at once by default (`MediaDownloadSlots.shared`). Pictures fetched over one
HTTP/2 connection share it and all finish together, so past a few at once more downloads finish none of them sooner. A request
over the limit waits, the newest first: in a scrolling list the newest requests are the pictures now on screen. A picture
scrolled away while it waits never opens its source. A download fails when no data arrives for `timeout`; the clock starts
when the download gets its slot, not when it queued. Disk reads never wait for a slot. Pass `slots` to use a limit of your own for one kind of image.

`MediaSource.shouldRetry` returns false for an error another try cannot fix (a sign-in or a rejected request), and the load then
fails at once instead of using its `retries`.

## Progressive previews

With `progressive: true`, a progressive JPEG is shown scan by scan while it downloads, each preview decoded at the same size as
the final picture (`decodeBox`). A scan worker on a background isolate finds the scans, so the main isolate does no parsing.
Other formats, and baseline JPEGs, show no previews. The file is written to the store only after it has downloaded and decoded
in full: a JPEG that stops before its end marker is never stored (bytes after the marker are fine). The scan worker starts
when the download gets its slot. Unwatching the picture cancels the download and the worker.

## Animation and decoded memory

`firstFrameOnly` plays only the first frame of an animated picture: the codec reports one frame and decodes no other.
`retainDecoded: false` removes the decoded picture from its `ImageCache` when its last listener goes, so pictures that are off
screen hold no pixels; the encoded file stays in the store and is decoded again when the picture is shown next.

## Settings

| Where | Setting | Default |
|---|---|---|
| `CachedMediaImage` | `store` | none: memory only |
| | `imageCache` | Flutter's shared image cache |
| | `retries`, `timeout`, `retryDelay` | 2 retries, 45 s without data, 120 ms doubling |
| | `decodeBox`, `decodeFit` | full size; `BoxFit.contain` |
| | `scale`, `reloadRevision`, `keepBytes` | 1, 0, off |
| | `firstFrameOnly`, `retainDecoded`, `progressive` | off, on, off |
| | `slots` | `MediaDownloadSlots.shared`: 12 downloads at once |
| `MediaSource` | `shouldRetry` | every error is retried |
| `MediaDiskCache` | directory | `forApp`, or any `directory` function |
| | `maxBytes`, `trimmedShare`, `maxAge` | 512 MB, trimmed to 60 %, 14 days unopened |
| | `unfinishedMaxAge` | 1 hour |
| | `fileNameOf` | SHA-256 of the key in hex |
| | `markOpenedOnRead` | on |
| `trimAutomatically` | `afterLaunch`, `whenHiddenEvery` | 1 minute, 1 day |
| `HttpMediaSource` | `headers`, `client`, `cacheOnDisk` | none, a shared `HttpClient`, on |
| `mediaDecodeBox` | `step` | 128 device pixels |
| `limitDecodedPictureCache` | `bytes`, `count` | required, 1000 |

## License

MIT. See [LICENSE](LICENSE).
