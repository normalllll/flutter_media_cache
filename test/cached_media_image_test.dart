import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_media_cache/flutter_media_cache.dart';
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
}
