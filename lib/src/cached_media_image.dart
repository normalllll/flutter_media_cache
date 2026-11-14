import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'media_disk_cache.dart';
import 'media_source.dart';

/// A picture from [source], kept decoded in memory in [imageCache] (Flutter's
/// shared image cache by default) and, when [store] is given and the source
/// allows it, encoded in [store] between runs.
///
/// Memory is looked up first, then [store]. A file there that fails to decode
/// is removed and the picture fetched again; a fetched picture is written to
/// [store] only once its first frame has decoded. A fetch that fails is tried
/// [retries] more times, each within [timeout], after [retryDelay].
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

  /// How long one fetch may take, from opening to its last byte.
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
    final completer = _cache.putIfAbsent(key, () => loadImage(key, PaintingBinding.instance.instantiateImageCodecWithSize), onError: handleError);
    if (completer != null) stream.setCompleter(completer);
  }

  @override
  ImageStreamCompleter loadImage(CachedMediaImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: key._load(chunks, decode),
      scale: key.scale,
      chunkEvents: chunks.stream,
      debugLabel: key.source.description,
      informationCollector: () => <DiagnosticsNode>[DiagnosticsProperty<ImageProvider>('Image provider', key)],
    );
  }

  @override
  Future<bool> evict({ImageCache? cache, ImageConfiguration configuration = ImageConfiguration.empty}) {
    _kept.remove(this);
    return super.evict(cache: cache ?? imageCache, configuration: configuration);
  }

  bool get _stored => store != null && source.cacheOnDisk;

  Future<ui.Codec> _load(StreamController<ImageChunkEvent> chunks, ImageDecoderCallback decode) async {
    try {
      if (_stored) {
        final kept = await store!.read(source.cacheKey);
        if (kept != null) {
          try {
            return await _decode(kept, decode, fromDisk: true);
          } on MediaImageException {
            await store!.remove(source.cacheKey);
          }
        }
      }
      final bytes = await _fetch(chunks);
      final codec = await _decode(bytes, decode, fromDisk: false);
      if (_stored) unawaited(store!.write(source.cacheKey, bytes));
      return codec;
    } catch (error, stack) {
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
      codec = await decode(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: switch (decodeBox) {
          null => null,
          final box => (width, height) => fittedDecodeSize(width, height, box, decodeFit),
        },
      );
      // A codec decodes lazily: only a first frame proves the bytes are good.
      final first = await codec.getNextFrame();
      if (keepBytes) _kept[this] = bytes;
      return _CheckedCodec(codec, first, (error) async {
        if (_stored) await store!.remove(source.cacheKey);
        await evict();
        return failure(error);
      });
    } catch (error, stack) {
      codec?.dispose();
      Error.throwWithStackTrace(failure(error), stack);
    }
  }

  Future<Uint8List> _fetch(StreamController<ImageChunkEvent> chunks) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final builder = BytesBuilder(copy: false);
      try {
        int? total;
        await for (final chunk in source.open().timeout(timeout)) {
          builder.add(chunk.bytes);
          total = chunk.total ?? total;
          chunks.add(ImageChunkEvent(cumulativeBytesLoaded: chunk.received, expectedTotalBytes: chunk.total));
        }
        if (builder.isEmpty) throw StateError('Empty file: expected ${total ?? 'unknown'} bytes');
        if (total != null && builder.length != total) throw StateError('Incomplete file: ${builder.length} of $total bytes');
        return builder.takeBytes();
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt < retries) await Future<void>.delayed(retryDelay(attempt));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  @override
  bool operator ==(Object other) =>
      other is CachedMediaImage &&
      other.source == source &&
      other.scale == scale &&
      other.decodeBox == decodeBox &&
      other.decodeFit == decodeFit &&
      other.reloadRevision == reloadRevision &&
      other.keepBytes == keepBytes;

  @override
  int get hashCode => Object.hash(source, scale, decodeBox, decodeFit, reloadRevision, keepBytes);

  @override
  String toString() => '${objectRuntimeType(this, 'CachedMediaImage')}(${source.description}, scale: $scale)';
}

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
  return scale >= 1 ? const ui.TargetImageSize() : ui.TargetImageSize(width: math.max(1, (width * scale).ceil()));
}

/// Replays the checked first frame, then the rest; a later frame that fails
/// removes the picture from both caches.
final class _CheckedCodec implements ui.Codec {
  _CheckedCodec(this._codec, this._first, this._onError);

  final ui.Codec _codec;
  ui.FrameInfo? _first;
  final Future<Object> Function(Object) _onError;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

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
