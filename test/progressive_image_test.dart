import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_media_cache/flutter_media_cache.dart';
import 'package:flutter_media_cache/src/progressive_image_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const _box = Size(128, double.infinity);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttp = HttpOverrides.current;
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = previousHttp);

  late Directory folder;
  late MediaDiskCache disk;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('progressive-image-');
    disk = MediaDiskCache(directory: () async => folder);
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    folder.deleteSync(recursive: true);
  });

  File kept(String key) => File(path.join(folder.path, MediaDiskCache.sha256FileName(key)));

  for (final name in ['baseline.jpg', 'progressive.jpg', 'noninterlaced.png']) {
    test('slow download of $name follows its scan contract, ends in exact pixels and is stored only whole', () async {
      final fixture = await _SlowFixture.open(name);
      addTearDown(fixture.close);
      final provider = CachedMediaImage(fixture.source, store: disk, progressive: true, decodeBox: _box, retries: 0);
      final stream = provider.resolve(ImageConfiguration.empty);
      final frames = <Future<Uint8List>>[];
      final done = Completer<void>();
      var partials = 0;
      final listener = ImageStreamListener(
        (info, _) {
          final complete = (stream.completer! as ProgressiveImageStreamCompleter).complete;
          if (!complete) {
            partials++;
            expect(kept(fixture.source.cacheKey).existsSync(), isFalse);
          }
          final image = info.image.clone();
          info.dispose();
          frames.add(_pixels(image));
          if (complete && !done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace? stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      try {
        await done.future.timeout(const Duration(seconds: 15));
        expect(partials, name == 'progressive.jpg' ? greaterThanOrEqualTo(3) : 0);
        final all = await Future.wait(frames);
        final codec = await ui.instantiateImageCodec(fixture.bytes, targetWidth: 128);
        final full = await codec.getNextFrame();
        codec.dispose();
        expect(all.last, await _pixels(full.image));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(kept(fixture.source.cacheKey).readAsBytesSync(), fixture.bytes);
        if (name.endsWith('.jpg')) {
          var previous = double.infinity;
          for (final pixels in all.take(partials)) {
            var error = 0;
            for (var i = 0; i < pixels.length; i++) {
              error += (pixels[i] - all.last[i]).abs();
            }
            final mean = error / pixels.length;
            expect(mean, lessThanOrEqualTo(previous));
            previous = mean;
          }
        }
      } finally {
        stream.removeListener(listener);
        await provider.evict();
      }
    });
  }

  test('clearing the image cache mid-load neither re-enters it nor cancels a load someone still watches', () async {
    final transport = StreamController<MediaChunk>();
    final source = _ControlledSource('clear-pending', transport.stream);
    final provider = CachedMediaImage(source, progressive: true, decodeBox: _box, retries: 0);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose());
    stream.addListener(listener);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(PaintingBinding.instance.imageCache.statusForKey(provider).pending, isTrue);

    PaintingBinding.instance.imageCache.clear();
    final loading = (stream.completer! as ProgressiveImageStreamCompleter).loading;
    expect(loading.cancelled, isFalse);

    stream.removeListener(listener);
    expect(loading.cancelled, isTrue);
    await transport.close();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('an unknown-length truncated progressive JPEG is never written to the store', () async {
    final bytes = File('test/fixtures/progressive.jpg').readAsBytesSync();
    final source = _ControlledSource(
      'truncated',
      Stream.value(MediaChunk(bytes: Uint8List.sublistView(bytes, 0, bytes.length ~/ 2), received: bytes.length ~/ 2)),
    );
    final provider = CachedMediaImage(source, store: disk, progressive: true, decodeBox: _box, retries: 0);
    final stream = provider.resolve(ImageConfiguration.empty);
    final failed = Completer<Object>();
    final listener = ImageStreamListener(
      (info, _) => info.dispose(),
      onError: (Object error, StackTrace? _) {
        if (!failed.isCompleted) failed.complete(error);
      },
    );
    stream.addListener(listener);
    try {
      expect(await failed.future.timeout(const Duration(seconds: 5)), isA<MediaImageException>());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(folder.listSync(), isEmpty);
    } finally {
      stream.removeListener(listener);
      await provider.evict();
    }
  });

  test('the last listener leaving stops preview frames, the download and the store write', () async {
    final fixture = await _SlowFixture.open('progressive.jpg');
    addTearDown(fixture.close);
    final provider = CachedMediaImage(fixture.source, store: disk, progressive: true, decodeBox: _box, retries: 0);
    final stream = provider.resolve(ImageConfiguration.empty);
    final first = Completer<void>();
    var count = 0;
    final listener = ImageStreamListener((info, _) {
      count++;
      info.dispose();
      if (!first.isCompleted) first.complete();
    });
    stream.addListener(listener);
    await first.future.timeout(const Duration(seconds: 10));
    stream.removeListener(listener);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final before = count;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(count, before);
    expect((stream.completer! as ProgressiveImageStreamCompleter).loading.cancelled, isTrue);
    expect(folder.listSync(), isEmpty);
    expect(fixture.source.cancelled, isTrue);
    expect(PaintingBinding.instance.imageCache.statusForKey(provider).untracked, isTrue);
  });
}

Future<Uint8List> _pixels(ui.Image image) async {
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class _ControlledSource extends MediaSource {
  _ControlledSource(this.cacheKey, this.stream);

  @override
  final String cacheKey;
  final Stream<MediaChunk> stream;

  @override
  Stream<MediaChunk> open() => stream;
}

/// Serves a fixture over a real socket, in slow chunks.
class _SlowFixture {
  _SlowFixture(this.bytes, this.server);

  final Uint8List bytes;
  final HttpServer server;
  late final _SocketSource source = _SocketSource(Uri.parse('http://127.0.0.1:${server.port}/image'));

  static Future<_SlowFixture> open(String name) async {
    final bytes = await File('test/fixtures/$name').readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.bufferOutput = false;
      try {
        final chunkSize = (bytes.length / 18).ceil();
        for (var offset = 0; offset < bytes.length; offset += chunkSize) {
          request.response.add(Uint8List.sublistView(bytes, offset, math.min(offset + chunkSize, bytes.length)));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await request.response.close();
      } on IOException {
        // The client going away is the expected end of a cancelled load.
      }
    });
    return _SlowFixture(bytes, server);
  }

  Future<void> close() => server.close(force: true);
}

class _SocketSource extends MediaSource {
  _SocketSource(this.url);

  final Uri url;
  bool cancelled = false;

  @override
  String get cacheKey => '$url';

  @override
  Stream<MediaChunk> open() async* {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        yield MediaChunk(bytes: chunk, received: received, total: response.contentLength);
      }
    } finally {
      client.close(force: true);
      cancelled = true;
    }
  }
}
