import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_media_cache/flutter_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xFF2196F3), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(3, 2);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// flutter_test answers every request with 400; the server here is real.
class _RealHttp extends HttpOverrides {}

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
  testWidgets('plain HTTP fetches the picture with its headers and keeps it on disk', (tester) async {
    await tester.runAsync(() async {
      final png = await _png();
      final folder = Directory.systemTemp.createTempSync('http-media-source-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? referer;
      server.listen((request) {
        referer = request.headers.value('referer');
        if (request.uri.path == '/missing.png') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response
            ..contentLength = png.length
            ..add(png);
        }
        unawaited(request.response.close());
      });
      final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());
      try {
        final disk = MediaDiskCache(directory: () async => folder);
        final url = Uri.parse('http://${server.address.host}:${server.port}/picture.png?signature=secret');
        final source = HttpMediaSource(url, headers: {'Referer': 'https://example.test/'}, client: client);

        expect(await _load(CachedMediaImage(source, store: disk)), const Size(3, 2));
        expect(referer, 'https://example.test/');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(File(path.join(folder.path, MediaDiskCache.sha256FileName('$url'))).readAsBytesSync(), png);

        final missing = HttpMediaSource(url.replace(path: '/missing.png'), client: client);
        await expectLater(
          _load(CachedMediaImage(missing, retries: 0)),
          throwsA(isA<MediaImageException>().having((error) => '$error', 'diagnostics', allOf(contains('HTTP 404'), isNot(contains('secret'))))),
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
        PaintingBinding.instance.imageCache.clear();
        folder.deleteSync(recursive: true);
      }
    });
  });

  test('sources with the same address and headers are the same picture', () {
    final url = Uri.parse('https://example.test/a.png');
    expect(HttpMediaSource(url, headers: {'a': '1', 'b': '2'}), HttpMediaSource(url, headers: {'b': '2', 'a': '1'}));
    expect(HttpMediaSource(url, headers: {'a': '1', 'b': '2'}).hashCode, HttpMediaSource(url, headers: {'b': '2', 'a': '1'}).hashCode);
    expect(HttpMediaSource(url), isNot(HttpMediaSource(url, headers: {'a': '1'})));
  });
}
