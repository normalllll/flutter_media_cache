import 'dart:io';

import 'package:flutter/foundation.dart';

import 'media_source.dart';

/// A picture fetched over plain HTTP with `dart:io`, as `NetworkImage` does,
/// for an app without a transport of its own.
///
/// The file is keyed by [url] alone. When [headers] select different bytes
/// for the same address (a sign-in), subclass and include them in
/// [cacheKey], or turn [cacheOnDisk] off.
class HttpMediaSource extends MediaSource {
  HttpMediaSource(this.url, {Map<String, String> headers = const {}, this.client, this.cacheOnDisk = true}) : headers = Map.unmodifiable(headers);

  final Uri url;
  final Map<String, String> headers;

  /// The client requests go through; null shares one for every source.
  final HttpClient? client;

  @override
  final bool cacheOnDisk;

  static final _shared = HttpClient();

  @override
  String get cacheKey => '$url';

  /// The address without its query and user info, which may hold
  /// signatures and credentials.
  @override
  String get description => '${Uri(scheme: url.scheme, host: url.host, port: url.hasPort ? url.port : null, path: url.path)}';

  @override
  String describe(Object cause) => '$cause'.replaceAll('$url', description);

  @override
  Stream<MediaChunk> open() async* {
    final request = await (client ?? _shared).getUrl(url);
    headers.forEach(request.headers.set);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    // A response decompressed on the way has no known length.
    final total = response.contentLength >= 0 ? response.contentLength : null;
    var received = 0;
    await for (final bytes in response) {
      received += bytes.length;
      yield MediaChunk(bytes: bytes, received: received, total: total);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HttpMediaSource &&
      other.runtimeType == runtimeType &&
      other.url == url &&
      mapEquals(other.headers, headers) &&
      identical(other.client, client) &&
      other.cacheOnDisk == cacheOnDisk;

  @override
  int get hashCode =>
      Object.hash(runtimeType, url, Object.hashAllUnordered(headers.entries.map((entry) => Object.hash(entry.key, entry.value))), client, cacheOnDisk);
}
