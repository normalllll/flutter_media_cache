import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'jpeg_scan_buffer.dart';
import 'media_disk_cache.dart';
import 'media_download_slots.dart';
import 'media_source.dart';
import 'progressive_image_stream.dart';
import 'watched_completer.dart';

/// A picture from [source], kept decoded in memory in [imageCache] (Flutter's
/// shared image cache by default) and, when [store] is given and the source
/// allows it, encoded in [store] between runs.
///
/// Memory is looked up first, then [store]. A file there that fails to decode
/// is removed and the picture fetched again; a fetched picture is written to
/// [store] only once its first frame has decoded. A fetch that fails is tried
/// [retries] more times after [retryDelay]; an error
/// [MediaSource.shouldRetry] rejects ends the load at once.
///
/// Downloads run through [slots], so only so many are open at once; disk reads
/// are not limited.
@immutable
class CachedMediaImage extends ImageProvider<CachedMediaImage> {
  const CachedMediaImage(
    this.source, {
    this.store,
    this.imageCache,
    this.scale = 1,
    this.retries = 2,
    this.timeout = const Duration(seconds: 45),
    this.retryDelay = doublingRetryDelay,
    this.decodeBox,
    this.decodeFit = BoxFit.contain,
    this.reloadRevision = 0,
    this.keepBytes = false,
    this.firstFrameOnly = false,
    this.retainDecoded = true,
    this.progressive = false,
    this.slots,
  }) : assert(retries >= 0);

  final MediaSource source;

  /// Where fetched pictures are kept between runs ([MediaDiskCache]); null
  /// keeps them in memory only.
  final MediaStore? store;

  /// The cache decoded pictures are kept in; null uses Flutter's shared
  /// image cache ([PaintingBinding.imageCache]). One of its own keeps a kind
  /// of picture apart, with its own limits.
  final ImageCache? imageCache;
  final double scale;
  final int retries;

  /// How long a fetch may go without data before it fails. The clock starts
  /// when the fetch gets its download slot and restarts with each chunk.
  final Duration timeout;

  /// The wait before retry [attempt] (0 for the first retry).
  final Duration Function(int attempt) retryDelay;

  /// 120 ms before the first retry, doubling for each one after.
  static Duration doublingRetryDelay(int attempt) => Duration(milliseconds: 120 << attempt);

  /// The box, in physical pixels, the picture is drawn in with [decodeFit]:
  /// it is decoded no larger than it is drawn there, and never above its own
  /// size. The height may be infinite for a box only as wide as it is laid
  /// out ([mediaDecodeBox]). Null decodes the picture at its own size.
  final Size? decodeBox;
  final BoxFit decodeFit;

  /// A higher value asks for the picture again, as a new image, after a
  /// failure.
  final int reloadRevision;

  /// Keeps the encoded bytes after decoding, for copying or saving the
  /// picture ([keptBytes]), until the picture is evicted.
  final bool keepBytes;

  /// Plays only the first frame of an animated picture: the codec reports one
  /// frame and never decodes another.
  final bool firstFrameOnly;

  /// Whether the decoded picture stays in [imageCache] once no one listens to
  /// it. When false it leaves the cache with its last listener, freeing its
  /// pixels, and is decoded again from [store] (or fetched) when next shown.
  final bool retainDecoded;

  /// Shows a progressive JPEG scan by scan while it downloads, each preview
  /// decoded as the final picture is ([decodeBox]). Other formats show no
  /// previews. The file is written to [store] only once it has downloaded and
  /// decoded in full.
  final bool progressive;

  /// How many downloads run at once; null uses [MediaDownloadSlots.shared].
  /// Not part of what makes two pictures the same.
  final MediaDownloadSlots? slots;

  static final _kept = <CachedMediaImage, Uint8List>{};

  /// The encoded bytes of a picture loaded with [keepBytes], or null before it
  /// has loaded.
  Uint8List? get keptBytes => _kept[this];

  @override
  Future<CachedMediaImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  ImageCache get _cache => imageCache ?? PaintingBinding.instance.imageCache;

  /// As [ImageProvider.resolveStreamForKey], in [imageCache].
  @override
  void resolveStreamForKey(ImageConfiguration configuration, ImageStream stream, CachedMediaImage key, ImageErrorListener handleError) {
    if (stream.completer case final completer?) {
      _cache.putIfAbsent(key, () => completer, onError: handleError);
      return;
    }
    final completer = _cache.putIfAbsent(key, () {
      final loaded = loadImage(key, PaintingBinding.instance.instantiateImageCodecWithSize);
      // The cache listens to what its loader returns, before anyone else.
      (loaded as WatchedCompleter).expectCacheListener = true;
      return loaded;
    }, onError: handleError);
    if (completer != null) stream.setCompleter(completer);
  }

  /// Loads the picture. When every viewer goes away before the bytes are in,
  /// the fetch is cancelled and the picture removed from [imageCache], so a
  /// later resolve fetches it afresh. The image cache's own listener is not a
  /// viewer.
  @override
  ImageStreamCompleter loadImage(CachedMediaImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    final cancel = _Cancel();
    ProgressiveImageLoading? loading;
    final completer = key.progressive
        ? _progressive(key, decode, chunks, cancel, loading = ProgressiveImageLoading((bytes) => key._decodeBytes(bytes, decode)))
        : null;
    final ImageStreamCompleter result =
        completer ??
        _WatchedMultiFrameCompleter(
          codec: key._load(chunks, decode, cancel),
          scale: key.scale,
          chunkEvents: chunks.stream,
          debugLabel: key.source.description,
          informationCollector: () => <DiagnosticsNode>[DiagnosticsProperty<ImageProvider>('Image provider', key)],
        );
    final watched = result as WatchedCompleter;

    watched.onViewersGone = (_) {
      if (cancel.settled || cancel.isCancelled) return;
      cancel.cancel();
      loading?.cancel();
      // While the cache's own listener is attached, its pending entry for the
      // key is this load. After the first image the cache holds it completed, so
      // a key that is not pending is evicted too (at worst another completed
      // load goes with it). A pending key without our listener is another load,
      // or a clear iterating the cache's map.
      if (watched.cacheListening || !key._cache.statusForKey(key).pending) key._cache.evict(key);
    };
    if (!key.retainDecoded) {
      result.addOnLastListenerRemovedCallback(() {
        // A newer completed load of the same key may go too: one extra decode.
        if (!watched.cacheListening && !key._cache.statusForKey(key).pending) key._cache.evict(key, includeLive: false);
      });
    }
    return result;
  }

  ProgressiveImageStreamCompleter _progressive(
    CachedMediaImage key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
    _Cancel cancel,
    ProgressiveImageLoading loading,
  ) {
    loading.onCancelled = cancel.cancel;
    return ProgressiveImageStreamCompleter(
      loading: loading,
      load: () => key._load(chunks, decode, cancel, loading),
      scale: key.scale,
      chunkEvents: chunks.stream,
      debugLabel: key.source.description,
    );
  }

  @override
  Future<bool> evict({ImageCache? cache, ImageConfiguration configuration = ImageConfiguration.empty}) {
    _kept.remove(this);
    return super.evict(cache: cache ?? imageCache, configuration: configuration);
  }

  bool get _stored => store != null && source.cacheOnDisk;

  Future<ui.Codec> _load(StreamController<ImageChunkEvent> chunks, ImageDecoderCallback decode, _Cancel cancel, [ProgressiveImageLoading? loading]) async {
    try {
      if (_stored) {
        final kept = await store!.read(source.cacheKey);
        cancel.check();
        if (kept != null) {
          try {
            cancel.settled = true;
            return await _decode(kept, decode, fromDisk: true);
          } on MediaImageException {
            cancel.settled = false;
            await store!.remove(source.cacheKey);
            cancel.check();
          }
        }
      }
      final bytes = await _fetch(chunks, cancel, loading);
      cancel.settled = true;
      final codec = await _decode(bytes, decode, fromDisk: false);
      if (_stored) unawaited(store!.write(source.cacheKey, bytes));
      return codec;
    } catch (error, stack) {
      // A cancelled load has no one to tell and was already removed from the
      // image cache, whose key may hold a new load by now. It never
      // completes, so nothing reports it as a failure.
      if (cancel.isCancelled) return Completer<ui.Codec>().future;
      // The image cache tracks this key only after the load starts.
      scheduleMicrotask(() => _cache.evict(this));
      Error.throwWithStackTrace(error is MediaImageException ? error : MediaImageException(source: source, stage: MediaImageStage.fetch, cause: error), stack);
    } finally {
      unawaited(chunks.close());
    }
  }

  Future<ui.Codec> _decode(Uint8List bytes, ImageDecoderCallback decode, {required bool fromDisk}) async {
    MediaImageException failure(Object error) =>
        MediaImageException(source: source, stage: MediaImageStage.decode, cause: error, byteCount: bytes.length, fromDisk: fromDisk);
    ui.Codec? codec;
    try {
      codec = await _decodeBytes(bytes, decode);
      // A codec decodes lazily: only a first frame proves the bytes are good.
      final first = await codec.getNextFrame();
      if (keepBytes) _kept[this] = bytes;
      return _CheckedCodec(codec, first, firstFrameOnly: firstFrameOnly, (error) async {
        if (_stored) await store!.remove(source.cacheKey);
        await evict();
        return failure(error);
      });
    } catch (error, stack) {
      codec?.dispose();
      Error.throwWithStackTrace(failure(error), stack);
    }
  }

  Future<ui.Codec> _decodeBytes(Uint8List bytes, ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    getTargetSize: switch (decodeBox) {
      null => null,
      final box => (width, height) => fittedDecodeSize(width, height, box, decodeFit),
    },
  );

  Future<Uint8List> _fetch(StreamController<ImageChunkEvent> chunks, _Cancel cancel, ProgressiveImageLoading? loading) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retries; attempt++) {
      cancel.check();
      try {
        return await _fetchOnce(chunks, cancel, loading);
      } on ImageLoadCancelled {
        rethrow;
      } catch (error, stack) {
        if (!source.shouldRetry(error)) rethrow;
        lastError = error;
        lastStack = stack;
        if (attempt < retries) await Future<void>.delayed(retryDelay(attempt));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  /// One attempt at the bytes; [cancel] cancels the source's stream. With
  /// [loading], the bytes go through its scan worker, which shows previews.
  Future<Uint8List> _fetchOnce(StreamController<ImageChunkEvent> chunks, _Cancel cancel, ProgressiveImageLoading? loading) async {
    final done = Completer<Uint8List>();
    StreamSubscription<MediaChunk>? subscription;
    void fail(Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    }

    try {
      cancel.check();
      final builder = loading == null ? BytesBuilder(copy: false) : null;
      var received = 0;
      int? total;
      // The timeout runs inside the slot: waiting for one is not downloading.
      // Nor does a waiting load hold a scan worker: it starts with the slot.
      subscription = (slots ?? MediaDownloadSlots.shared)
          .schedule(() async* {
            // A load cancelled while its worker starts is no longer listened
            // to: ending quietly keeps its cancel from surfacing as an error.
            try {
              await loading?.begin();
            } on ImageLoadCancelled {
              if (cancel.isCancelled) return;
              rethrow;
            }
            if (cancel.isCancelled) return;
            yield* source.open().timeout(timeout);
          })
          .listen(
            (chunk) {
              received += chunk.bytes.length;
              total = chunk.total ?? total;
              try {
                if (loading == null) {
                  builder!.add(chunk.bytes);
                } else {
                  loading.add(chunk.bytes is Uint8List ? chunk.bytes as Uint8List : Uint8List.fromList(chunk.bytes));
                }
              } catch (error, stack) {
                fail(error, stack);
                unawaited(subscription?.cancel());
                return;
              }
              chunks.add(ImageChunkEvent(cumulativeBytesLoaded: chunk.received, expectedTotalBytes: chunk.total));
            },
            onError: fail,
            onDone: () {
              if (received == 0) return fail(StateError('Empty file: expected ${total ?? 'unknown'} bytes'), StackTrace.current);
              if (total != null && received != total) {
                return fail(StateError('Incomplete file: $received of $total bytes'), StackTrace.current);
              }
              if (done.isCompleted) return;
              if (loading == null) {
                done.complete(builder!.takeBytes());
              } else {
                loading.finish().then(done.complete, onError: fail);
              }
            },
            cancelOnError: true,
          );
      cancel.onCancel = () {
        unawaited(subscription?.cancel());
        fail(const ImageLoadCancelled(), StackTrace.current);
      };
      return await done.future;
    } catch (_) {
      await loading?.endAttempt();
      unawaited(subscription?.cancel());
      rethrow;
    } finally {
      cancel.onCancel = null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CachedMediaImage &&
      other.source == source &&
      other.scale == scale &&
      other.decodeBox == decodeBox &&
      other.decodeFit == decodeFit &&
      other.reloadRevision == reloadRevision &&
      other.keepBytes == keepBytes &&
      other.firstFrameOnly == firstFrameOnly &&
      other.retainDecoded == retainDecoded &&
      other.progressive == progressive;

  @override
  int get hashCode => Object.hash(source, scale, decodeBox, decodeFit, reloadRevision, keepBytes, firstFrameOnly, retainDecoded, progressive);

  @override
  String toString() => '${objectRuntimeType(this, 'CachedMediaImage')}(${source.description}, scale: $scale)';
}

/// Whether the image [completer] reports now is the final picture, not a
/// preview of a progressive load still downloading. Saving or copying the
/// picture waits for the final one.
bool showsFinalPicture(ImageStreamCompleter completer) => completer is! ProgressiveImageStreamCompleter || completer.complete;

/// The decoded size that draws a [width] × [height] picture in [box] with
/// [fit] at one picture pixel per device pixel, never above its own size.
@visibleForTesting
ui.TargetImageSize fittedDecodeSize(int width, int height, Size box, BoxFit fit) {
  final across = box.width / width;
  final down = box.height.isFinite ? box.height / height : across;
  final scale = switch (fit) {
    BoxFit.cover || BoxFit.fill => math.max(across, down),
    BoxFit.fitWidth => across,
    BoxFit.fitHeight => down,
    BoxFit.contain || BoxFit.scaleDown => math.min(across, down),
    BoxFit.none => 1.0,
  };
  if (scale >= 1) return const ui.TargetImageSize();
  // width * (box.width / width) can land a hair above box.width in floating
  // point; rounding that up would decode one pixel wider than the box.
  return ui.TargetImageSize(width: math.max(1, (width * scale - 1e-6).ceil()));
}

/// Replays the checked first frame, then the rest; a later frame that fails
/// removes the picture from both caches.
final class _CheckedCodec implements ui.Codec {
  _CheckedCodec(this._codec, this._first, this._onError, {required this.firstFrameOnly});

  final ui.Codec _codec;
  ui.FrameInfo? _first;
  final Future<Object> Function(Object) _onError;
  final bool firstFrameOnly;

  @override
  int get frameCount => firstFrameOnly ? 1 : _codec.frameCount;

  @override
  int get repetitionCount => firstFrameOnly ? 0 : _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_first case final first?) {
      _first = null;
      return first;
    }
    try {
      return await _codec.getNextFrame();
    } catch (error, stack) {
      Error.throwWithStackTrace(await _onError(error), stack);
    }
  }

  @override
  void dispose() {
    _first?.image.dispose();
    _first = null;
    _codec.dispose();
  }
}

/// Whether anyone still waits for a load's bytes, and how to stop fetching
/// them.
final class _Cancel {
  bool isCancelled = false;

  /// The bytes are in and being decoded; nothing is left to cancel.
  bool settled = false;

  /// Stops the fetch running now, if any.
  void Function()? onCancel;

  void cancel() {
    isCancelled = true;
    final stop = onCancel;
    onCancel = null;
    stop?.call();
  }

  void check() {
    if (isCancelled) throw const ImageLoadCancelled();
  }
}

/// A multi-frame picture that tells its viewers from the image cache.
final class _WatchedMultiFrameCompleter extends MultiFrameImageStreamCompleter with WatchedCompleter {
  _WatchedMultiFrameCompleter({required super.codec, required super.scale, super.chunkEvents, super.debugLabel, super.informationCollector});
}
