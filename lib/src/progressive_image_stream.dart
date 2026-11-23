import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'jpeg_scan_buffer.dart';
import 'watched_completer.dart';

/// Shows the scans of a progressive JPEG while it downloads, then the
/// validated final picture. Previews own their load lifecycle; once the final
/// codec is ready, Flutter's multi-frame completer owns animation timing and
/// disposal.
final class ProgressiveImageStreamCompleter extends ImageStreamCompleter with WatchedCompleter {
  ProgressiveImageStreamCompleter({
    required this.loading,
    required Future<ui.Codec> Function() load,
    required double scale,
    required Stream<ImageChunkEvent> chunkEvents,
    required String debugLabel,
  }) {
    this.debugLabel = debugLabel;
    loading.onImage = (image) => setImage(ImageInfo(image: image, scale: scale));
    _chunks = chunkEvents.listen(reportImageChunkEvent);
    unawaited(_run(load, scale));
  }

  final ProgressiveImageLoading loading;
  MultiFrameImageStreamCompleter? _finalStream;
  ImageStreamListener? _finalListener;
  ImageStreamCompleterHandle? _finalHandle;
  late final StreamSubscription<ImageChunkEvent> _chunks;
  bool _disposed = false, _finalListening = false, _resuming = false;

  bool get complete => loading.complete;

  Future<void> _run(Future<ui.Codec> Function() load, double scale) async {
    try {
      final codec = await load();
      if (loading.cancelled || _disposed) {
        codec.dispose();
        return;
      }
      loading.complete = true;
      final stream = MultiFrameImageStreamCompleter(codec: SynchronousFuture(codec), scale: scale, debugLabel: debugLabel);
      _finalStream = stream;
      _finalHandle = stream.keepAlive();
      final listener = ImageStreamListener(
        (image, synchronousCall) {
          // Re-attaching replays the final stream's current frame at once.
          // This completer already holds that frame and has just given it to
          // the returning listener; passing it on would repeat it as if it
          // were new and outside the listener's addListener call.
          if (synchronousCall && _resuming) {
            image.dispose();
            return;
          }
          setImage(image);
        },
        onError: (Object error, StackTrace? stack) => reportError(exception: error, stack: stack, context: ErrorDescription('decoding a complete image')),
      );
      _finalListener = listener;
      if (hasListeners) {
        _finalListening = true;
        stream.addListener(listener);
      }
    } catch (error, stack) {
      if (!loading.cancelled && !_disposed) {
        reportError(exception: error, stack: stack, context: ErrorDescription('loading an image'));
      }
    } finally {
      await loading.endAttempt();
      await _chunks.cancel();
    }
  }

  @override
  void addListener(ImageStreamListener listener) {
    final resume = !hasListeners && _finalListener != null;
    super.addListener(listener);
    if (resume) {
      _finalListening = true;
      _resuming = true;
      try {
        _finalStream!.addListener(_finalListener!);
      } finally {
        _resuming = false;
      }
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!_disposed && !hasListeners && _finalListening) {
      _finalListening = false;
      _finalStream!.removeListener(_finalListener!);
    }
  }

  @override
  void onDisposed() {
    _disposed = true;
    loading.cancel();
    final listener = _finalListener;
    if (listener != null && _finalListening) {
      _finalStream!.removeListener(listener);
    }
    _finalHandle?.dispose();
    super.onDisposed();
  }
}

/// One progressive load: the scan worker that parses the bytes as they come,
/// and the previews decoded from the scans it finds.
class ProgressiveImageLoading {
  ProgressiveImageLoading(this._decodePreview);

  /// Decodes a complete JPEG, the way the final picture is decoded.
  final Future<ui.Codec> Function(Uint8List bytes) _decodePreview;
  JpegScanBuffer? _buffer;
  Future<void>? _pending;
  bool _ended = false;
  bool cancelled = false, complete = false;
  void Function(ui.Image)? onImage;

  /// Called once, when the load is cancelled, to stop what feeds it.
  VoidCallback? onCancelled;

  /// Ends the load: stops the scan worker and no preview is shown after.
  void cancel() {
    if (cancelled || complete) return;
    cancelled = true;
    _buffer?.cancel();
    onCancelled?.call();
  }

  void checkActive() {
    if (cancelled) throw const ImageLoadCancelled();
  }

  /// Starts the scan worker for one attempt at the bytes.
  Future<void> begin() async {
    checkActive();
    _ended = false;
    final buffer = await JpegScanBuffer.start(
      onPreview: (bytes, scanEnd) {
        if (cancelled || _ended) return;
        assert(_pending == null);
        _pending = _decode(bytes).whenComplete(() {
          _pending = null;
          if (!_ended && !cancelled) _buffer?.nextPreview();
        });
      },
    );
    _buffer = buffer;
    // The attempt may have ended while the worker was starting.
    if (cancelled || _ended) buffer.cancel();
    checkActive();
  }

  void add(Uint8List bytes) {
    checkActive();
    _buffer!.add(bytes);
  }

  /// The bytes of the whole file, once the last chunk was added.
  Future<Uint8List> finish() async {
    _ended = true;
    final buffer = _buffer!;
    final bytes = await buffer.finish();
    await _pending;
    checkActive();
    // The engine decodes a JPEG missing its last scans, which must not pass
    // for a whole file. Bytes after the end marker are fine.
    if (buffer.truncatedJpeg) throw StateError('Incomplete JPEG: no end marker after ${bytes.length} bytes');
    return bytes;
  }

  /// Ends the attempt, whether it finished or failed, and its scan worker.
  Future<void> endAttempt() async {
    _ended = true;
    _buffer?.cancel();
    await _pending;
    _buffer = null;
  }

  Future<void> _decode(Uint8List bytes) async {
    ui.Image? image;
    try {
      // The worker has already found a complete progressive scan. The engine
      // decodes it on its own threads; no pixel work runs on this isolate.
      final codec = await _decodePreview(bytes);
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // A preview does not validate a file. The final decode reports corruption.
      image?.dispose();
      return;
    }
    if (cancelled || _ended) {
      image.dispose();
      return;
    }
    final callback = onImage;
    if (callback == null) {
      image.dispose();
    } else {
      callback(image);
    }
  }
}
