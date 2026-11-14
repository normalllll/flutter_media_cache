import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Where encoded files are kept between runs, by key ([CachedMediaImage.store]).
abstract interface class MediaStore {
  /// The bytes kept for [key], or null when there are none.
  Future<Uint8List?> read(String key);

  /// Keeps [bytes] for [key]. Best effort: a failure only means fetching
  /// again.
  Future<void> write(String key, Uint8List bytes);

  /// Removes what is kept for [key].
  Future<void> remove(String key);
}

/// What one trim removed, and the bytes of the files it left.
typedef MediaDiskTrim = ({int files, int bytes, int left});

/// Records when the folder was last trimmed, by its modified time.
const _trimMarker = '.trimmed';

/// A file being written is named with this prefix until it is complete.
const _partPrefix = '.part-';

/// Encoded files, one file per key in a folder, bounded by age and by total
/// size.
///
/// A file is written whole under a temporary name and then renamed, so a
/// reader sees either the complete file or none. Files are not checked when
/// read: a file that fails to decode is removed and fetched again
/// ([CachedMediaImage] does this), which costs less than checking every read.
///
/// Reading a file marks it as opened ([markOpenedOnRead]). A trim removes
/// files not opened within [maxAge], then, while the folder is past
/// [maxBytes], the files opened longest ago until [trimmedShare] of it is
/// left. Trims run on a background isolate ([trim], [trimAutomatically]), and
/// as soon as files written since the last trim take the folder past
/// [maxBytes].
class MediaDiskCache implements MediaStore {
  MediaDiskCache({
    required this._directory,
    this.maxBytes = 512 << 20,
    this.maxAge = const Duration(days: 14),
    this.trimmedShare = .6,
    this.unfinishedMaxAge = const Duration(hours: 1),
    this.fileNameOf = sha256FileName,
    this.markOpenedOnRead = true,
  }) : assert(maxBytes > 0),
       assert(trimmedShare > 0 && trimmedShare <= 1);

  /// A cache in [folder] at [defaultDirectory]: the app's own folder under
  /// the system's temporary files on Windows, where the system's disk cleanup
  /// can free it, and the app's cache directory elsewhere.
  factory MediaDiskCache.forApp({
    String folder = 'media_cache',
    String? appName,
    int maxBytes = 512 << 20,
    Duration maxAge = const Duration(days: 14),
    double trimmedShare = .6,
    Duration unfinishedMaxAge = const Duration(hours: 1),
    String Function(String key) fileNameOf = sha256FileName,
    bool markOpenedOnRead = true,
  }) => MediaDiskCache(
    directory: defaultDirectory(folder: folder, appName: appName),
    maxBytes: maxBytes,
    maxAge: maxAge,
    trimmedShare: trimmedShare,
    unfinishedMaxAge: unfinishedMaxAge,
    fileNameOf: fileNameOf,
    markOpenedOnRead: markOpenedOnRead,
  );

  /// [folder] where an app's cache belongs on this platform.
  ///
  /// On Windows: the system's temporary files, which its disk cleanup and
  /// storage settings free, in a folder of the app's own, [appName] (by
  /// default the executable's name), since every app shares that directory.
  /// On macOS and Linux the temporary directory is cleared within days or
  /// held in memory, so, as on mobile systems, the app's cache directory
  /// ([inApplicationCacheDirectory]).
  static Future<Directory> Function() defaultDirectory({String folder = 'media_cache', String? appName}) => Platform.isWindows
      ? () async => Directory(path.join((await getTemporaryDirectory()).path, appName ?? path.basenameWithoutExtension(Platform.resolvedExecutable), folder))
      : inApplicationCacheDirectory(folder);

  /// [folder] under the app's cache directory.
  static Future<Directory> Function() inApplicationCacheDirectory(String folder) =>
      () async => Directory(path.join((await getApplicationCacheDirectory()).path, folder));

  /// The SHA-256 of [key] in hex: the same length for every key and safe on
  /// every file system.
  static String sha256FileName(String key) => sha256.convert(utf8.encode(key)).toString();

  /// Where the files are kept; created when first needed.
  final Future<Directory> Function() _directory;

  /// What the folder may hold before a trim removes the files opened longest
  /// ago.
  final int maxBytes;

  /// A file not opened for this long is removed by the next trim.
  final Duration maxAge;

  /// The share of [maxBytes] a trim of a folder past it leaves: well below
  /// the limit, so a folder that keeps growing is not trimmed again at every
  /// file written.
  final double trimmedShare;

  /// A file still being written after this long was left by a write that
  /// never finished, and a trim removes it.
  final Duration unfinishedMaxAge;

  /// The file name a key is kept under.
  final String Function(String key) fileNameOf;

  /// Whether reading a file marks it as opened, which keeps it over files
  /// opened longer ago. Off, files age from when they were written.
  final bool markOpenedOnRead;

  Future<Directory>? _folder;

  /// The folder's bytes as the last trim left them plus what has been written
  /// since; null until a trim or [measure] has counted them.
  int? _bytes;
  Future<MediaDiskTrim>? _trimming;
  Timer? _launch;
  AppLifecycleListener? _lifecycle;
  Duration _hiddenInterval = Duration.zero;

  /// The folder, created when first needed.
  Future<Directory> get directory => _folder ??= () async {
    final folder = await _directory();
    await folder.create(recursive: true);
    return folder;
  }();

  Future<File> _file(String key) async => File(path.join((await directory).path, fileNameOf(key)));

  /// The bytes kept for [key], or null when there are none; marks the file
  /// as opened ([markOpenedOnRead]).
  @override
  Future<Uint8List?> read(String key) async {
    final File file;
    final Uint8List bytes;
    try {
      file = await _file(key);
      bytes = await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
    if (markOpenedOnRead) unawaited(_touch(file));
    return bytes;
  }

  /// Keeps [bytes] for [key], replacing what was kept for it. Best effort: a
  /// failed write leaves the key without a file.
  @override
  Future<void> write(String key, Uint8List bytes) async {
    File? part;
    try {
      final file = await _file(key);
      part = File(path.join(file.parent.path, '$_partPrefix${path.basename(file.path)}-${_partSuffix()}'));
      await part.writeAsBytes(bytes);
      await part.rename(file.path);
      part = null;
      _written(bytes.length);
    } on FileSystemException {
      // A cache that cannot be written only means fetching again.
    } finally {
      if (part != null) {
        try {
          await part.delete();
        } on FileSystemException {
          // Removed by a later trim.
        }
      }
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await (await _file(key)).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Removes every kept file, for a "clear cache" control.
  Future<void> clear() async {
    try {
      final folder = await directory;
      _folder = null;
      if (await folder.exists()) await folder.delete(recursive: true);
      _bytes = 0;
    } on FileSystemException {
      // Whatever is left goes with the next trim.
    }
  }

  /// The bytes the folder holds, counted on a background isolate, for showing
  /// beside a "clear cache" control.
  Future<int> measure() async {
    final folder = (await directory).path;
    final bytes = await Isolate.run(() => measureMediaDiskCacheFolder(folder), debugName: 'media disk cache measure');
    _bytes = bytes;
    return bytes;
  }

  /// Trims the folder on a background isolate; a trim already running is
  /// shared.
  Future<MediaDiskTrim> trim() => _trimming ??= _runTrim().whenComplete(() => _trimming = null);

  Future<MediaDiskTrim> _runTrim() async {
    final folder = (await directory).path;
    final now = DateTime.now();
    final maxAge = this.maxAge, maxBytes = this.maxBytes, trimmedShare = this.trimmedShare, unfinishedMaxAge = this.unfinishedMaxAge;
    final trimmed = await Isolate.run(
      () => trimMediaDiskCacheFolder(folder, now, maxAge: maxAge, maxBytes: maxBytes, trimmedShare: trimmedShare, unfinishedMaxAge: unfinishedMaxAge),
      debugName: 'media disk cache trim',
    );
    // Files written while the trim ran are counted again by the next one.
    _bytes = trimmed.left;
    try {
      final marker = File(path.join(folder, _trimMarker));
      await marker.writeAsBytes(const []);
      await marker.setLastModified(now);
    } on FileSystemException {
      // The next hidden app trims again.
    }
    return trimmed;
  }

  /// Trims [afterLaunch] from now, off the startup path, and when the app is
  /// hidden, at most once every [whenHiddenEvery]. Files written then count
  /// toward the limit from the first trim on. Stopped by [dispose].
  void trimAutomatically({Duration afterLaunch = const Duration(minutes: 1), Duration whenHiddenEvery = const Duration(days: 1)}) {
    dispose();
    _hiddenInterval = whenHiddenEvery;
    _launch = Timer(afterLaunch, () => unawaited(trim()));
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(_trimWhenDue()));
  }

  Future<void> _trimWhenDue() async {
    try {
      final marker = File(path.join((await directory).path, _trimMarker));
      if (await marker.exists() && DateTime.now().difference(await marker.lastModified()) < _hiddenInterval) return;
      await trim();
    } on FileSystemException {
      // Tried again the next time the app is hidden.
    }
  }

  /// Stops [trimAutomatically].
  void dispose() {
    _launch?.cancel();
    _launch = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  void _written(int bytes) {
    final measured = _bytes;
    if (measured == null) return;
    _bytes = measured + bytes;
    if (measured + bytes > maxBytes) unawaited(trim());
  }

  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException {
      // The file only ages as if it had not been opened.
    }
  }

  static final _random = math.Random();
  static String _partSuffix() => _random.nextInt(1 << 32).toRadixString(36);
}

/// The bytes of the kept files in [directory]: not the record of the last
/// trim, nor files still being written. Synchronous, for a background isolate
/// ([MediaDiskCache.measure]).
int measureMediaDiskCacheFolder(String directory) {
  final folder = Directory(directory);
  if (!folder.existsSync()) return 0;
  var total = 0;
  for (final entry in folder.listSync(followLinks: false)) {
    final name = path.basename(entry.path);
    if (entry is! File || name == _trimMarker || name.startsWith(_partPrefix)) continue;
    try {
      total += entry.lengthSync();
    } on FileSystemException {
      // Gone since it was listed.
    }
  }
  return total;
}

/// Removes from [directory] the files not opened since [now] - [maxAge].
/// When what is left is past [maxBytes], the files opened longest ago go too,
/// until what is left fits [trimmedShare] of it.
///
/// A file's modified time is when it was last opened. Files a write left
/// unfinished are removed after [unfinishedMaxAge], and folders once older
/// than [maxAge]. Synchronous, for a background isolate
/// ([MediaDiskCache.trim]).
MediaDiskTrim trimMediaDiskCacheFolder(
  String directory,
  DateTime now, {
  required Duration maxAge,
  required int maxBytes,
  double trimmedShare = .6,
  Duration unfinishedMaxAge = const Duration(hours: 1),
}) {
  final folder = Directory(directory);
  if (!folder.existsSync()) return (files: 0, bytes: 0, left: 0);
  final oldest = now.subtract(maxAge);
  final kept = <({File file, DateTime opened, int bytes})>[];
  var files = 0, bytes = 0;
  for (final entry in folder.listSync(followLinks: false)) {
    try {
      final stat = entry.statSync();
      final name = path.basename(entry.path);
      if (entry is Directory) {
        if (stat.modified.isBefore(oldest)) entry.deleteSync(recursive: true);
        continue;
      }
      if (entry is! File || name == _trimMarker) continue;
      if (name.startsWith(_partPrefix)) {
        if (stat.modified.isBefore(now.subtract(unfinishedMaxAge))) entry.deleteSync();
        continue;
      }
      if (stat.modified.isBefore(oldest)) {
        entry.deleteSync();
        files++;
        bytes += stat.size;
      } else {
        kept.add((file: entry, opened: stat.modified, bytes: stat.size));
      }
    } on FileSystemException {
      // A file being written or read right now is left for the next trim.
    }
  }
  var total = kept.fold(0, (sum, entry) => sum + entry.bytes);
  if (total > maxBytes) {
    final trimmedBytes = (maxBytes * trimmedShare).floor();
    kept.sort((a, b) => a.opened.compareTo(b.opened));
    for (final entry in kept) {
      if (total <= trimmedBytes) break;
      try {
        entry.file.deleteSync();
        total -= entry.bytes;
        files++;
        bytes += entry.bytes;
      } on FileSystemException {
        // Left for the next trim.
      }
    }
  }
  return (files: files, bytes: bytes, left: total);
}
