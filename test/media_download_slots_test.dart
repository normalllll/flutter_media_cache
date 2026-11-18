import 'dart:async';

import 'package:flutter_media_cache/flutter_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake downloads that stay open until a test finishes them.
final class _Downloads {
  final opened = <String>[];
  final open = <String, StreamController<int>>{};

  Stream<int> stream(String url) {
    opened.add(url);
    final controller = StreamController<int>(onCancel: () => open.remove(url));
    open[url] = controller;
    return controller.stream;
  }

  Future<void> finish(String url) async {
    final controller = open.remove(url)!;
    controller.add(1);
    await controller.close();
  }
}

void main() {
  late _Downloads downloads;
  late MediaDownloadSlots slots;

  Stream<int> request(int index) => slots.schedule(() => downloads.stream('$index.jpg'));

  setUp(() {
    downloads = _Downloads();
    slots = MediaDownloadSlots(12);
  });

  test('never more than twelve downloads run at once', () async {
    final subscriptions = [for (var i = 0; i < 20; i++) request(i).listen((_) {})];
    await pumpEventQueue();
    expect(downloads.open, hasLength(12));
    expect(slots.waiting, 8);

    for (var i = 0; i < 20; i++) {
      final running = downloads.open.keys.toList();
      if (running.isEmpty) break;
      await downloads.finish(running.first);
      await pumpEventQueue();
      expect(downloads.open.length, lessThanOrEqualTo(12));
    }
    expect(downloads.opened, hasLength(20));
    expect(slots.running, 0);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('the newest waiting request starts first', () async {
    for (var i = 0; i < 15; i++) {
      request(i).listen((_) {});
    }
    await pumpEventQueue();

    await downloads.finish('0.jpg');
    await pumpEventQueue();
    expect(downloads.opened.last, '14.jpg');

    await downloads.finish('1.jpg');
    await pumpEventQueue();
    expect(downloads.opened.last, '13.jpg');
  });

  test('a request cancelled while it waits never opens, and a cancelled download frees its slot', () async {
    final subscriptions = [for (var i = 0; i < 14; i++) request(i).listen((_) {})];
    await pumpEventQueue();

    await subscriptions[13].cancel();
    expect(slots.waiting, 1);

    await subscriptions[0].cancel();
    await pumpEventQueue();
    expect(downloads.open.containsKey('0.jpg'), isFalse);
    expect(downloads.opened, isNot(contains('13.jpg')));
    expect(downloads.opened.last, '12.jpg');
    expect(slots.running, 12);
    expect(slots.waiting, 0);
  });

  test('a download that fails frees its slot', () async {
    final failing = slots.schedule<int>(() => Stream.error(StateError('offline')));
    await expectLater(failing.toList(), throwsStateError);
    expect(slots.running, 0);
  });

  test('the shared slots allow twelve downloads', () {
    expect(MediaDownloadSlots.shared.limit, 12);
  });
}
