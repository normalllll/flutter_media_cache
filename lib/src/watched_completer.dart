import 'package:flutter/painting.dart';

/// Tells the viewers of a picture from the image cache's own listener.
///
/// The image cache listens to a pending picture itself until its first image
/// arrives, which is not anyone watching. Whether the cache is still attached
/// is read from the completer's own listeners, never from the key's status in
/// the cache, which may by now describe another load of the same key.
mixin WatchedCompleter on ImageStreamCompleter {
  final _listening = <ImageStreamListener>[];
  ImageStreamListener? _cacheListener;

  /// The next listener added is the image cache's. Set by the loader the cache
  /// is given, which the cache listens to right after it returns.
  bool expectCacheListener = false;

  /// Called each time the last viewer goes, with whether the cache's own
  /// listener was the one removed.
  void Function(bool removedByCache)? onViewersGone;

  /// Whether the image cache's own listener is still attached.
  bool get cacheListening => _cacheListener != null;

  int get viewers => _listening.length - (cacheListening ? 1 : 0);

  @override
  void addListener(ImageStreamListener listener) {
    // Counted first: a listener added to a finished picture may remove
    // itself before addListener returns.
    _listening.add(listener);
    final isCache = expectCacheListener;
    if (isCache) {
      expectCacheListener = false;
      _cacheListener = listener;
    }
    try {
      super.addListener(listener);
    } catch (_) {
      _listening.remove(listener);
      if (isCache) _cacheListener = null;
      rethrow;
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    final counted = _listening.remove(listener);
    final byCache = counted && identical(listener, _cacheListener);
    if (byCache) _cacheListener = null;
    super.removeListener(listener);
    if (counted && viewers == 0) onViewersGone?.call(byCache);
  }
}
