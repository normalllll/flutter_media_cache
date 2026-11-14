import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_media_cache/flutter_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory folder;
  final now = DateTime(2026, 11, 14, 12);

  setUp(() => folder = Directory.systemTemp.createTempSync('media-disk-cache-'));
  tearDown(() => folder.deleteSync(recursive: true));

  File file(String name, {required int bytes, required Duration openedAgo}) => File(path.join(folder.path, name))
    ..writeAsBytesSync(List.filled(bytes, 0))
    ..setLastModifiedSync(now.subtract(openedAgo));

  List<String> left() => [for (final entry in folder.listSync()) path.basename(entry.path)]..sort();

  MediaDiskCache cache({int maxBytes = 512 << 20}) => MediaDiskCache(directory: () async => folder, maxBytes: maxBytes);

  group('a cache', () {
    test('keeps bytes by key under the SHA-256 of the key, and writes leave no partial file', () async {
      final disk = cache();
      await disk.write('abc', Uint8List.fromList([1, 2, 3]));

      expect(await disk.read('abc'), [1, 2, 3]);
      expect(await disk.read('missing'), isNull);
      expect(left(), ['ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad']);
    });

    test('measures what the folder holds, leaving out unfinished files and the trim record', () async {
      final disk = cache();
      await disk.write('a', Uint8List(300));
      await disk.write('b', Uint8List(200));
      file('.part-unfinished', bytes: 1000, openedAgo: Duration.zero);
      file('.trimmed', bytes: 0, openedAgo: Duration.zero);

      expect(await disk.measure(), 500);
    });

    test('names files and marks them opened as the caller chooses', () async {
      final disk = MediaDiskCache(directory: () async => folder, fileNameOf: (key) => 'picture-$key', markOpenedOnRead: false);
      await disk.write('1', Uint8List(1));
      final stored = File(path.join(folder.path, 'picture-1'))..setLastModifiedSync(now);

      expect(await disk.read('1'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stored.lastModifiedSync(), now);
    });

    test('reading a file marks it as opened', () async {
      final disk = cache();
      await disk.write('key', Uint8List(1));
      final stored = File(path.join(folder.path, MediaDiskCache.sha256FileName('key')))..setLastModifiedSync(now);

      await disk.read('key');
      // The mark is written after the bytes are returned.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(stored.lastModifiedSync().isAfter(now), isTrue);
    });

    test('removes one key, or every file', () async {
      final disk = cache();
      await disk.write('a', Uint8List(1));
      await disk.write('b', Uint8List(1));

      await disk.remove('a');
      expect(await disk.read('a'), isNull);
      expect(await disk.read('b'), isNotNull);

      await disk.clear();
      expect(folder.existsSync(), isFalse);
      folder.createSync();
    });

    test('writes that take a measured folder past its limit trim it at once, to 60 % of the limit', () async {
      final disk = cache(maxBytes: 1000);
      expect(await disk.trim(), (files: 0, bytes: 0, left: 0));

      for (var index = 0; index < 4; index++) {
        await disk.write('picture $index', Uint8List(300));
        File(path.join(folder.path, MediaDiskCache.sha256FileName('picture $index'))).setLastModifiedSync(now.add(Duration(minutes: index)));
      }
      final trimmed = await disk.trim();

      expect(trimmed.left, lessThanOrEqualTo(600));
      expect(await disk.read('picture 3'), isNotNull, reason: 'the file opened last stays');
      expect(await disk.read('picture 0'), isNull);
    });

    test('trims a minute after launch by default, and when hidden once the interval has passed', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final disk = cache(maxBytes: 1000);
      file('old', bytes: 10, openedAgo: const Duration(days: 30));

      disk.trimAutomatically(afterLaunch: Duration.zero, whenHiddenEvery: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(left(), ['.trimmed']);

      file('older', bytes: 10, openedAgo: const Duration(days: 30));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(left(), ['.trimmed']);

      disk.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });

  group('a trim', () {
    test('removes files not opened within the age limit and keeps the record of the last trim', () {
      file('fresh', bytes: 10, openedAgo: const Duration(days: 1));
      file('stale', bytes: 20, openedAgo: const Duration(days: 15));
      file('.trimmed', bytes: 0, openedAgo: const Duration(days: 30));

      final trimmed = trimMediaDiskCacheFolder(folder.path, now, maxAge: const Duration(days: 14), maxBytes: 1000);

      expect(left(), ['.trimmed', 'fresh']);
      expect(trimmed, (files: 1, bytes: 20, left: 10));
    });

    test('past the byte limit, removes the files opened longest ago until 60 % of it is left', () {
      file('a', bytes: 400, openedAgo: const Duration(hours: 5));
      file('b', bytes: 400, openedAgo: const Duration(hours: 3));
      file('c', bytes: 400, openedAgo: const Duration(hours: 1));

      final trimmed = trimMediaDiskCacheFolder(folder.path, now, maxAge: const Duration(days: 14), maxBytes: 1000);

      expect(left(), ['c']);
      expect(trimmed, (files: 2, bytes: 800, left: 400));
    });

    test('within the byte limit, keeps every file opened within the age limit', () {
      file('a', bytes: 400, openedAgo: const Duration(hours: 5));
      file('b', bytes: 400, openedAgo: const Duration(hours: 3));

      expect(trimMediaDiskCacheFolder(folder.path, now, maxAge: const Duration(days: 14), maxBytes: 1000), (files: 0, bytes: 0, left: 800));
      expect(left(), ['a', 'b']);
    });

    test('removes a file a write left unfinished after an hour', () {
      file('.part-recent', bytes: 10, openedAgo: const Duration(minutes: 5));
      file('.part-left', bytes: 10, openedAgo: const Duration(hours: 2));

      final trimmed = trimMediaDiskCacheFolder(folder.path, now, maxAge: const Duration(days: 14), maxBytes: 1000);

      expect(left(), ['.part-recent']);
      expect(trimmed.left, 0, reason: 'unfinished files are not counted as kept');
    });

    test('removes a folder once it is older than the age limit', () {
      Directory(path.join(folder.path, 'leftover')).createSync();
      // Folder times cannot be set portably, so the trims run from now and
      // from past the age limit.
      trimMediaDiskCacheFolder(folder.path, DateTime.now(), maxAge: const Duration(days: 14), maxBytes: 1000);
      expect(left(), ['leftover']);

      trimMediaDiskCacheFolder(folder.path, DateTime.now().add(const Duration(days: 15)), maxAge: const Duration(days: 14), maxBytes: 1000);
      expect(left(), isEmpty);
    });

    test('leaves a missing folder alone', () {
      expect(trimMediaDiskCacheFolder(path.join(folder.path, 'missing'), now, maxAge: const Duration(days: 14), maxBytes: 1000), (files: 0, bytes: 0, left: 0));
    });
  });
}
