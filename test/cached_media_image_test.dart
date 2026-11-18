import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_media_cache/flutter_media_cache.dart';
import 'package:flutter_media_cache/src/jpeg_scan_buffer.dart';
import 'package:flutter_media_cache/src/cached_media_image.dart' show fittedDecodeSize;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xFF2196F3), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// Serves [bytes] for [cacheKey], failing the first [failures] opens.
class _Source extends MediaSource {
  _Source(this.cacheKey, this.bytes, {this.cacheOnDisk = true, this.failures = 0});

  @override
  final String cacheKey;
  final Uint8List bytes;
  @override
  final bool cacheOnDisk;
  int failures;
  int opens = 0;

  @override
  Stream<MediaChunk> open() {
    opens++;
    if (failures > 0) {
      failures--;
      return Stream.error(const SocketException('offline'));
    }
    return Stream.value(MediaChunk(bytes: bytes, received: bytes.length, total: bytes.length));
  }
}

/// Serves the chunks a test adds to [controller], and records whether the
/// download was cancelled.
class _StreamSource extends MediaSource {
  _StreamSource(this.cacheKey);

  @override
  final String cacheKey;
  late StreamController<MediaChunk> controller;
  int opens = 0;
  bool cancelled = false;

  @override
  Stream<MediaChunk> open() {
    opens++;
    controller = StreamController<MediaChunk>(onCancel: () => cancelled = true);
    return controller.stream;
  }
}

/// Resolves [image] to its first frame's size, or throws its error.
Future<Size> _load(ImageProvider image) {
  final result = Completer<Size>();
  final stream = image.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!result.isCompleted) result.complete(Size(info.image.width.toDouble(), info.image.height.toDouble()));
      info.dispose();
      stream.removeListener(listener);
    },
    onError: (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return result.future;
}

void main() {
  test('a box narrower than the picture decodes exactly as wide as the box', () {
    for (final width in [2894, 3000, 4096]) {
      for (var box = 800; box < 2000; box++) {
        expect(fittedDecodeSize(width, width, Size(box.toDouble(), double.infinity), BoxFit.contain).width, box);
      }
    }
  });

  late Directory folder;
  late MediaDiskCache disk;
  late Uint8List png;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('cached-media-image-');
    disk = MediaDiskCache(directory: () async => folder);
  });
  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    folder.deleteSync(recursive: true);
  });

  File kept(String key) => File(path.join(folder.path, MediaDiskCache.sha256FileName(key)));

  testWidgets('a fetched picture is kept on disk and later read from there instead of fetched', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _Source('picture', png);
      expect(await _load(CachedMediaImage(source, store: disk)), const Size(4, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(kept('picture').readAsBytesSync(), png);

      await CachedMediaImage(source, store: disk).evict();
      expect(await _load(CachedMediaImage(source, store: disk)), const Size(4, 2));
      expect(source.opens, 1);
    });
  });

  testWidgets('a file on disk that fails to decode is replaced by a fresh fetch', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      kept('picture').writeAsBytesSync([1, 2, 3]);
      final source = _Source('picture', png);

      expect(await _load(CachedMediaImage(source, store: disk)), const Size(4, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(source.opens, 1);
      expect(kept('picture').readAsBytesSync(), png);
    });
  });

  testWidgets('a source that must not outlive its sign-in is never written to disk', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      await _load(CachedMediaImage(_Source('private', png, cacheOnDisk: false), store: disk));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(folder.listSync(), isEmpty);
    });
  });

  testWidgets('a failed fetch is retried, and fails with the fetch stage once retries run out', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final flaky = _Source('flaky', png, failures: 1);
      expect(await _load(CachedMediaImage(flaky, store: disk, retries: 1)), const Size(4, 2));
      expect(flaky.opens, 2);

      final offline = _Source('offline', png, failures: 5);
      await expectLater(
        _load(CachedMediaImage(offline, retries: 1)),
        throwsA(isA<MediaImageException>().having((error) => error.stage, 'stage', MediaImageStage.fetch)),
      );
      expect(offline.opens, 2);
    });
  });

  testWidgets('bytes that are not a picture fail with the decode stage and are not kept', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        _load(CachedMediaImage(_Source('broken', Uint8List.fromList([1, 2, 3])), store: disk, retries: 0)),
        throwsA(isA<MediaImageException>().having((error) => error.stage, 'stage', MediaImageStage.decode).having((error) => error.byteCount, 'bytes', 3)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(folder.listSync(), isEmpty);
    });
  });

  testWidgets('a picture is decoded no larger than it is drawn in its box, and never above its own size', (tester) async {
    await tester.runAsync(() async {
      png = await _png(400, 200);
      Future<Size> decoded(Size? box, BoxFit fit) => _load(CachedMediaImage(_Source('$box $fit', png), decodeBox: box, decodeFit: fit));

      expect(await decoded(null, BoxFit.contain), const Size(400, 200));
      expect(await decoded(const Size(100, 100), BoxFit.contain), const Size(100, 50));
      // Covering: the shorter side has to fill the box, so it stays sharp.
      expect(await decoded(const Size(100, 100), BoxFit.cover), const Size(200, 100));
      expect(await decoded(const Size(100, double.infinity), BoxFit.contain), const Size(100, 50));
      expect(await decoded(const Size(800, 800), BoxFit.cover), const Size(400, 200));
    });
  });

  testWidgets('a picture already in memory is shown again without reading the store or fetching', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _Source('memory', png);
      await _load(CachedMediaImage(source, store: disk));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Gone from the store, so only memory can answer without a fetch.
      kept('memory').deleteSync();

      expect(await _load(CachedMediaImage(_Source('memory', png), store: disk)), const Size(4, 2));
      expect(source.opens, 1);
    });
  });

  testWidgets('a picture can be kept in an image cache of its own instead of the shared one', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final own = ImageCache();
      final image = CachedMediaImage(_Source('own', png), imageCache: own);

      await _load(image);

      expect(own.containsKey(image), isTrue);
      expect(PaintingBinding.instance.imageCache.containsKey(image), isFalse);
      expect(await image.evict(), isTrue);
      expect(own.containsKey(image), isFalse);
    });
  });

  testWidgets('the wait before each retry is the caller\'s', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final waits = <int>[];
      await _load(
        CachedMediaImage(
          _Source('waits', png, failures: 2),
          retries: 2,
          retryDelay: (attempt) {
            waits.add(attempt);
            return Duration.zero;
          },
        ),
      );
      expect(waits, [0, 1]);
    });
  });

  testWidgets('kept bytes are there once the picture loads and go when it is evicted', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final image = CachedMediaImage(_Source('kept', png), keepBytes: true);
      expect(image.keptBytes, isNull);

      await _load(image);
      expect(CachedMediaImage(_Source('kept', png), keepBytes: true).keptBytes, png);

      await image.evict();
      expect(image.keptBytes, isNull);
    });
  });

  testWidgets('the decode box covers the laid-out frame in device pixels, in steps', (tester) async {
    late Size? framed, filled, unbounded;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2.625),
        child: Builder(
          builder: (context) {
            framed = mediaDecodeBox(context, const BoxConstraints(maxWidth: 100, maxHeight: 1000), aspectRatio: 16 / 9);
            filled = mediaDecodeBox(context, const BoxConstraints(maxWidth: 100, maxHeight: 40));
            unbounded = mediaDecodeBox(context, const BoxConstraints(maxHeight: 100), aspectRatio: 1);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // 262.5 × 147.7 device pixels, rounded up.
    expect(framed, const Size(384, 256));
    expect(filled, const Size(384, 128));
    expect(unbounded, isNull);
  });

  testWidgets('a download no one listens to any more is cancelled, kept nowhere, and fetched afresh later', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _StreamSource('dropped');
      final image = CachedMediaImage(source, store: disk);
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose());
      stream.addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.opens, 1);
      source.controller.add(MediaChunk(bytes: png.sublist(0, 10), received: 10, total: png.length));

      stream.removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(source.cancelled, isTrue);
      expect(PaintingBinding.instance.imageCache.statusForKey(image).untracked, isTrue);
      expect(folder.listSync(), isEmpty);

      final again = _load(CachedMediaImage(source, store: disk));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.opens, 2);
      source.controller.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(source.controller.close());
      expect(await again, const Size(4, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(kept('dropped').readAsBytesSync(), png);
    });
  });

  testWidgets('a download still listened to elsewhere keeps going when one listener leaves', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _StreamSource('shared');
      final leaving = CachedMediaImage(source).resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose());
      leaving.addListener(listener);
      final staying = _load(CachedMediaImage(source));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      leaving.removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.cancelled, isFalse);

      source.controller.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(source.controller.close());
      expect(await staying, const Size(4, 2));
      expect(source.opens, 1);
    });
  });

  testWidgets('with one download slot, a second picture does not open until the first ends', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final slots = MediaDownloadSlots(1);
      final first = _StreamSource('first');
      final second = _StreamSource('second');
      final firstLoad = _load(CachedMediaImage(first, slots: slots));
      final secondLoad = _load(CachedMediaImage(second, slots: slots));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(first.opens, 1);
      expect(second.opens, 0);
      expect(slots.waiting, 1);

      first.controller.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(first.controller.close());
      expect(await firstLoad, const Size(4, 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(second.opens, 1);

      second.controller.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(second.controller.close());
      expect(await secondLoad, const Size(4, 2));
      expect(slots.running, 0);
    });
  });

  testWidgets('a picture unwatched while it waits for a slot never opens', (tester) async {
    await tester.runAsync(() async {
      final slots = MediaDownloadSlots(1);
      final busy = _StreamSource('busy');
      final waiting = _StreamSource('waiting');
      final busyStream = CachedMediaImage(busy, slots: slots).resolve(ImageConfiguration.empty);
      final busyListener = ImageStreamListener((info, _) => info.dispose());
      busyStream.addListener(busyListener);
      final image = CachedMediaImage(waiting, slots: slots);
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose());
      stream.addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(slots.waiting, 1);

      stream.removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(slots.waiting, 0);
      busyStream.removeListener(busyListener);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(waiting.opens, 0);
      expect(busy.cancelled, isTrue);
      expect(slots.running, 0);
    });
  });

  testWidgets('time spent waiting for a slot does not count toward the timeout', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final slots = MediaDownloadSlots(1);
      final busy = _StreamSource('busy');
      final waiting = _Source('waiting', png);
      final busyLoad = _load(CachedMediaImage(busy, slots: slots, retries: 0));
      final waitingLoad = _load(CachedMediaImage(waiting, slots: slots, retries: 0, timeout: const Duration(milliseconds: 200)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(waiting.opens, 0);

      busy.controller.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(busy.controller.close());
      await busyLoad;

      expect(await waitingLoad, const Size(4, 2));
      expect(waiting.opens, 1);
    });
  });

  testWidgets('a download that outlasts the timeout once it has its slot fails', (tester) async {
    await tester.runAsync(() async {
      final stalled = _StreamSource('stalled');
      await expectLater(
        _load(CachedMediaImage(stalled, slots: MediaDownloadSlots(1), retries: 0, timeout: const Duration(milliseconds: 100))),
        throwsA(isA<MediaImageException>().having((error) => error.stage, 'stage', MediaImageStage.fetch)),
      );
    });
  });

  testWidgets('an error the source will not retry opens it once and is reported', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _PickySource('picky', png, failures: 5);
      await expectLater(
        _load(CachedMediaImage(source, retries: 3)),
        throwsA(
          isA<MediaImageException>()
              .having((error) => error.stage, 'stage', MediaImageStage.fetch)
              .having((error) => error.cause, 'cause', isA<FormatException>()),
        ),
      );
      expect(source.opens, 1);

      final retried = _PickySource('retried', png, failures: 1, error: const SocketException('offline'));
      expect(await _load(CachedMediaImage(retried, retries: 3, retryDelay: (_) => Duration.zero)), const Size(4, 2));
      expect(retried.opens, 2);
    });
  });

  testWidgets('firstFrameOnly shows one frame of an animated picture, and the default animates', (tester) async {
    final gif = File('test/fixtures/two_frames.gif').readAsBytesSync();
    Future<int> framesShown(CachedMediaImage image) async {
      var frames = 0;
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) {
        frames++;
        info.dispose();
      });
      stream.addListener(listener);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(seconds: 1));
      }
      stream.removeListener(listener);
      return frames;
    }

    expect(await framesShown(CachedMediaImage(_Source('animated', gif))), greaterThan(1));
    expect(await framesShown(CachedMediaImage(_Source('still', gif), firstFrameOnly: true)), 1);
    expect(CachedMediaImage(_Source('still', gif), firstFrameOnly: true), isNot(CachedMediaImage(_Source('still', gif))));
  });

  testWidgets('retainDecoded false drops the picture from the image cache with its last listener, the default keeps it', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final own = ImageCache();
      Future<void> showThenLeave(CachedMediaImage image) async {
        final stream = image.resolve(ImageConfiguration.empty);
        final shown = Completer<void>();
        final listener = ImageStreamListener((info, _) {
          info.dispose();
          if (!shown.isCompleted) shown.complete();
        });
        stream.addListener(listener);
        await shown.future;
        stream.removeListener(listener);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final kept = CachedMediaImage(_Source('kept', png), imageCache: own);
      await showThenLeave(kept);
      expect(own.containsKey(kept), isTrue);

      final dropped = CachedMediaImage(_Source('dropped', png), imageCache: own, retainDecoded: false);
      await showThenLeave(dropped);
      expect(own.containsKey(dropped), isFalse);
      expect(own.statusForKey(dropped).live, isFalse);
      expect(CachedMediaImage(_Source('dropped', png), imageCache: own), isNot(dropped));
    });
  });

  testWidgets('a progressive JPEG shows previews before its final picture and is stored whole', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      final source = _StreamSource('progressive');
      final image = CachedMediaImage(source, store: disk, progressive: true, decodeBox: const Size(128, double.infinity));
      final stream = image.resolve(ImageConfiguration.empty);
      var beforeEnd = 0, afterEnd = 0;
      var ended = false;
      final finals = <bool>[];
      final listener = ImageStreamListener((info, _) {
        ended ? afterEnd++ : beforeEnd++;
        finals.add(showsFinalPicture(stream.completer!));
        info.dispose();
      });
      stream.addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final size = (bytes.length / 18).ceil();
      var sent = 0;
      for (var offset = 0; offset < bytes.length; offset += size) {
        final end = offset + size < bytes.length ? offset + size : bytes.length;
        sent += end - offset;
        source.controller.add(MediaChunk(bytes: Uint8List.sublistView(bytes, offset, end), received: sent, total: bytes.length));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      expect(kept('progressive').existsSync(), isFalse);
      ended = true;
      await source.controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(beforeEnd, greaterThanOrEqualTo(1));
      expect(afterEnd, 1);
      expect(finals, [...List.filled(beforeEnd, false), true]);
      expect(kept('progressive').readAsBytesSync(), bytes);
      expect(JpegScanBuffer.latest, isNull, reason: 'a finished worker is not kept with its file');
      stream.removeListener(listener);
    });
  });

  testWidgets('a progressive load takes a download slot for each attempt', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      final slots = MediaDownloadSlots(1);
      final source = _Source('flaky-progressive', bytes, failures: 1);
      final image = CachedMediaImage(source, progressive: true, slots: slots, retries: 1, retryDelay: (_) => Duration.zero);

      expect(await _load(image), isNot(Size.zero));
      expect(source.opens, 2);
      expect(slots.running, 0);
    });
  });

  testWidgets('complete progressive bytes are stored, bytes without an end marker are not', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      await _load(CachedMediaImage(_Source('whole', bytes), store: disk, progressive: true));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(kept('whole').readAsBytesSync(), bytes);

      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 2);
      await expectLater(
        _load(CachedMediaImage(_Source('cut', cut), store: disk, progressive: true, retries: 0)),
        throwsA(isA<MediaImageException>().having((error) => error.stage, 'stage', MediaImageStage.fetch)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(kept('cut').existsSync(), isFalse);
    });
  });

  testWidgets('a progressive picture of another format simply shows no previews', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      expect(await _load(CachedMediaImage(_Source('plain-png', png), store: disk, progressive: true)), const Size(4, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(kept('plain-png').readAsBytesSync(), png);
    });
  });

  testWidgets('a clear of the image cache and a newer load of the same key do not cancel the first load while a viewer remains', (tester) async {
    await tester.runAsync(() async {
      png = await _png(4, 2);
      final source = _StreamSource('cleared');
      final image = CachedMediaImage(source);
      final shown = Completer<Size>();
      final viewerA = ImageStreamListener((info, _) {
        if (!shown.isCompleted) shown.complete(Size(info.image.width.toDouble(), info.image.height.toDouble()));
        info.dispose();
      });
      final viewerB = ImageStreamListener((info, _) => info.dispose());
      final streamA = image.resolve(ImageConfiguration.empty)..addListener(viewerA);
      final streamB = image.resolve(ImageConfiguration.empty)..addListener(viewerB);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.opens, 1);
      final first = source.controller;

      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      final viewerC = ImageStreamListener((info, _) => info.dispose());
      final streamC = image.resolve(ImageConfiguration.empty)..addListener(viewerC);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.opens, 2);
      expect(PaintingBinding.instance.imageCache.statusForKey(image).pending, isTrue);

      streamB.removeListener(viewerB);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(first.isClosed, isFalse);
      expect(source.cancelled, isFalse);

      first.add(MediaChunk(bytes: png, received: png.length, total: png.length));
      unawaited(first.close());
      expect(await shown.future.timeout(const Duration(seconds: 5)), const Size(4, 2));
      streamA.removeListener(viewerA);
      streamC.removeListener(viewerC);
    });
  });

  testWidgets('a scan worker that dies mid-download is a fetch error: retried, then reported, never a hang', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      final source = _KillingSource('killed', bytes);
      final image = CachedMediaImage(source, progressive: true, retries: 1, retryDelay: (_) => Duration.zero);
      expect(await _load(image).timeout(const Duration(seconds: 15)), isNot(Size.zero));
      expect(source.opens, 2);

      final again = _KillingSource('killed-again', bytes, killEvery: true);
      await expectLater(
        _load(CachedMediaImage(again, progressive: true, retries: 1, retryDelay: (_) => Duration.zero)).timeout(const Duration(seconds: 15)),
        throwsA(isA<MediaImageException>().having((error) => error.stage, 'stage', MediaImageStage.fetch)),
      );
      expect(again.opens, 2);
    });
  });

  testWidgets('a progressive JPEG with bytes after its end marker displays and is stored, with and without scans', (tester) async {
    await tester.runAsync(() async {
      for (final name in ['progressive.jpg', 'baseline.jpg']) {
        final bytes = Uint8List.fromList([...File('test/fixtures/$name').readAsBytesSync(), ...List.filled(16, 0)]);
        expect(await _load(CachedMediaImage(_Source(name, bytes), store: disk, progressive: true, retries: 0)), isNot(Size.zero));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(kept(name).readAsBytesSync(), bytes);
      }
    });
  });

  testWidgets('a progressive JPEG on disk is read without an end marker check', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/baseline.jpg').readAsBytesSync();
      kept('on-disk').writeAsBytesSync(Uint8List.sublistView(bytes, 0, bytes.length - 2));
      final source = _Source('on-disk', bytes);
      await _load(CachedMediaImage(source, store: disk, progressive: true));
      expect(source.opens, 0);
    });
  });

  testWidgets('a waiting progressive load holds no scan worker until its slot opens', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      final slots = MediaDownloadSlots(1);
      final first = _StreamSource('first-progressive');
      final second = _StreamSource('second-progressive');
      final workers = JpegScanBuffer.started;
      final listener = ImageStreamListener((info, _) => info.dispose());
      final firstStream = CachedMediaImage(first, slots: slots, progressive: true).resolve(ImageConfiguration.empty)..addListener(listener);
      final secondStream = CachedMediaImage(second, slots: slots, progressive: true).resolve(ImageConfiguration.empty)..addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(slots.waiting, 1);
      expect(JpegScanBuffer.started, workers + 1);
      expect(second.opens, 0);

      first.controller.add(MediaChunk(bytes: bytes, received: bytes.length, total: bytes.length));
      unawaited(first.controller.close());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(second.opens, 1);
      expect(JpegScanBuffer.started, workers + 2);

      second.controller.add(MediaChunk(bytes: bytes, received: bytes.length, total: bytes.length));
      unawaited(second.controller.close());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      firstStream.removeListener(listener);
      secondStream.removeListener(listener);
    });
  });

  testWidgets('a progressive load unwatched while its scan worker starts ends without an error', (tester) async {
    // An error that escapes the cancelled load fails the test as uncaught.
    await tester.runAsync(() async {
      final errors = <Object>[];
      final source = _StreamSource('unwatched-starting');
      final workers = JpegScanBuffer.started;
      final listener = ImageStreamListener((info, _) => info.dispose(), onError: (error, _) => errors.add(error));
      final stream = CachedMediaImage(source, slots: MediaDownloadSlots(1), progressive: true).resolve(ImageConfiguration.empty)
        ..addListener(listener);
      // The worker counts itself as it starts spawning its isolate.
      for (var turn = 0; turn < 100 && JpegScanBuffer.started == workers; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(JpegScanBuffer.started, workers + 1);
      stream.removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(source.opens, 0);
      expect(errors, isEmpty);
      expect(JpegScanBuffer.latest, isNull);
    });
  });

  testWidgets('a progressive load unwatched mid-download lets go of its scan worker', (tester) async {
    await tester.runAsync(() async {
      final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
      final source = _StreamSource('unwatched-downloading');
      final listener = ImageStreamListener((info, _) => info.dispose());
      final stream = CachedMediaImage(source, slots: MediaDownloadSlots(1), progressive: true).resolve(ImageConfiguration.empty)
        ..addListener(listener);
      for (var turn = 0; turn < 100 && source.opens == 0; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final half = bytes.length ~/ 2;
      source.controller.add(MediaChunk(bytes: Uint8List.sublistView(bytes, 0, half), received: half, total: bytes.length));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final worker = JpegScanBuffer.latest;
      expect(worker, isNotNull);

      stream.removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(source.cancelled, isTrue);
      expect(JpegScanBuffer.latest, isNull);
    });
  });
}

/// Serves a progressive JPEG in chunks, killing the scan worker part way
/// through the first open, or every open with [killEvery].
class _KillingSource extends MediaSource {
  _KillingSource(this.cacheKey, this.bytes, {this.killEvery = false});

  @override
  final String cacheKey;
  final Uint8List bytes;
  final bool killEvery;
  int opens = 0;

  @override
  Stream<MediaChunk> open() async* {
    final attempt = ++opens;
    // Before the first chunk, so that no preview has shown yet.
    if (attempt == 1 || killEvery) JpegScanBuffer.latest!.isolate!.kill(priority: Isolate.immediate);
    final size = (bytes.length / 12).ceil();
    var sent = 0;
    for (var offset = 0; offset < bytes.length; offset += size) {
      final end = offset + size < bytes.length ? offset + size : bytes.length;
      sent += end - offset;
      yield MediaChunk(bytes: Uint8List.sublistView(bytes, offset, end), received: sent, total: bytes.length);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }
}

/// Fails the first [failures] opens with [error]; a [FormatException] is not
/// retried.
class _PickySource extends _Source {
  _PickySource(super.cacheKey, super.bytes, {super.failures, this.error = const FormatException('rejected')});

  final Object error;

  @override
  Stream<MediaChunk> open() {
    opens++;
    if (failures > 0) {
      failures--;
      return Stream.error(error);
    }
    return Stream.value(MediaChunk(bytes: bytes, received: bytes.length, total: bytes.length));
  }

  @override
  bool shouldRetry(Object error) => error is! FormatException;
}
