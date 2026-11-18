import 'package:flutter/foundation.dart';

/// Part of a file as it arrives: the [bytes] just received, [received] so far
/// and the [total] when known.
@immutable
class MediaChunk {
  const MediaChunk({required this.bytes, required this.received, this.total});

  final List<int> bytes;
  final int received;
  final int? total;
}

/// Where a picture's bytes come from, through the app's own transport (its
/// HTTP client, proxy, headers and sign-in).
///
/// Two sources with the same [runtimeType], [cacheKey] and [cacheOnDisk] are
/// the same picture: they share a decoded picture in memory and a file on
/// disk. A subclass that holds more that changes the bytes (a transport with
/// another proxy) overrides [==] and [hashCode] to include it.
abstract class MediaSource {
  const MediaSource();

  /// Identifies the bytes; names the file on disk.
  String get cacheKey;

  /// Whether the bytes may be kept on disk. Off for files behind a sign-in
  /// that must not outlive it.
  bool get cacheOnDisk => true;

  /// Fetches the bytes. Called again for each retry.
  Stream<MediaChunk> open();

  /// Whether a fetch that failed with [error] is worth trying again. Return
  /// false for errors another try cannot fix, such as a sign-in or a request
  /// the server rejects: the load then fails at once.
  bool shouldRetry(Object error) => true;

  /// How the source reads in diagnostics and error messages; never
  /// credentials or signed addresses.
  String get description => cacheKey;

  /// How a failure to fetch reads in diagnostics; override to keep
  /// credentials and signed addresses out of it.
  String describe(Object cause) => '$cause';

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType && other is MediaSource && other.cacheKey == cacheKey && other.cacheOnDisk == cacheOnDisk;

  @override
  int get hashCode => Object.hash(runtimeType, cacheKey, cacheOnDisk);
}

/// Which step a picture failed at.
enum MediaImageStage { fetch, decode }

/// A picture that could not be fetched or decoded.
final class MediaImageException implements Exception {
  const MediaImageException({required this.source, required this.stage, required this.cause, this.byteCount, this.fromDisk = false});

  final MediaSource source;
  final MediaImageStage stage;
  final Object cause;

  /// The bytes that failed to decode.
  final int? byteCount;

  /// Whether the bytes that failed came from the disk cache.
  final bool fromDisk;

  @override
  String toString() =>
      'media=${source.description}\n'
      'stage=${stage.name} · disk=$fromDisk${byteCount == null ? '' : ' · bytes=$byteCount'}\n'
      '${source.describe(cause)}';
}
