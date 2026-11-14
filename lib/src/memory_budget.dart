import 'package:flutter/painting.dart';

/// Bounds Flutter's cache of decoded pictures by [bytes], with room for
/// [count] pictures so that small avatars and thumbnails do not reach the
/// count before the byte budget applies.
///
/// The cache counts a picture as four bytes a pixel. Impeller also keeps each
/// picture's smaller mip levels, a third more, so the graphics memory the
/// cache holds is over a third more than [bytes].
void limitDecodedPictureCache({required int bytes, int count = 1000}) {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = count;
  cache.maximumSizeBytes = bytes;
}
