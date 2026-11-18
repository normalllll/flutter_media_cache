import 'dart:async';

/// Runs at most [limit] downloads at once. Requests over the limit wait, and
/// the newest waiting request starts first: while a list scrolls, the newest
/// requests are for the pictures now on screen.
///
/// Downloads that share one connection (HTTP/2) all slow down together, so a
/// limit finishes pictures sooner than starting them all.
final class MediaDownloadSlots {
  MediaDownloadSlots(this.limit) : assert(limit > 0);

  /// The slots every [CachedMediaImage] downloads through unless it is given
  /// its own.
  static final shared = MediaDownloadSlots(12);

  final int limit;
  int _running = 0;
  final _waiting = <void Function()>[];

  /// Downloads running now.
  int get running => _running;

  /// Requests waiting for a slot.
  int get waiting => _waiting.length;

  /// The stream [open] returns, opened once a slot is free and listened to.
  /// It holds its slot until it ends or is cancelled. A request cancelled
  /// while it waits never calls [open].
  Stream<T> schedule<T>(Stream<T> Function() open) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    var holding = false;

    void release() {
      if (!holding) return;
      holding = false;
      _running--;
      _startWaiting();
    }

    void start() {
      holding = true;
      _running++;
      try {
        subscription = open().listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            release();
            unawaited(controller.close());
          },
        );
        if (controller.isPaused) subscription!.pause();
      } catch (error, stack) {
        controller.addError(error, stack);
        release();
        unawaited(controller.close());
      }
    }

    controller = StreamController<T>(
      onListen: () {
        if (_running < limit) {
          start();
        } else {
          _waiting.add(start);
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        _waiting.remove(start);
        final running = subscription;
        subscription = null;
        release();
        return running?.cancel();
      },
    );
    return controller.stream;
  }

  void _startWaiting() {
    while (_running < limit && _waiting.isNotEmpty) {
      _waiting.removeLast()();
    }
  }
}
