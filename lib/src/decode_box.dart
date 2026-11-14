import 'package:flutter/widgets.dart';

/// The box, in physical pixels, that a picture laid out in [constraints] at
/// [aspectRatio] (null fills them) is drawn in, for
/// [CachedMediaImage.decodeBox].
///
/// It is rounded up to [step] device pixels, so a window resized by a few
/// pixels keeps the picture it already decoded instead of decoding it again,
/// and it is never smaller than the frame drawn, so the picture stays sharp.
/// Null while the width is unbounded.
///
/// Each box is a picture of its own in the caches: use it where a picture is
/// shown at one size, not for one shared with other places at other sizes.
Size? mediaDecodeBox(BuildContext context, BoxConstraints constraints, {double? aspectRatio, double step = 128}) {
  final width = constraints.maxWidth;
  if (!width.isFinite || width <= 0) return null;
  final height = aspectRatio == null ? constraints.maxHeight : width / aspectRatio;
  final pixelRatio = MediaQuery.devicePixelRatioOf(context);
  double rounded(double extent) => (extent * pixelRatio / step).ceil() * step;
  return Size(rounded(width), height.isFinite && height > 0 ? rounded(height) : double.infinity);
}
