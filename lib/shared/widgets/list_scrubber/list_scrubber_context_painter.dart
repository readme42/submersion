import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber_geometry.dart';
import 'package:submersion/shared/widgets/list_scrubber/scrubber_marker.dart';

/// Paints [segments] as stripes and [ticks] as short marks in a narrow
/// context column just inside the panel's start edge.
class ListScrubberContextPainter extends CustomPainter {
  const ListScrubberContextPainter({
    required this.segments,
    required this.ticks,
    required this.slotCount,
    required this.trackExtent,
    required this.offset,
    required this.textDirection,
  });

  static const width = 4.0;

  /// The column's distance from the panel's start edge, past its hairline.
  static const inset = 1.0;
  static const minSegment = 2.0;
  static const tickThickness = 3.0;

  /// The least space between two neighbouring stripes.
  static const gap = 1.0;

  final List<ScrubberSegment> segments;
  final List<ScrubberTick> ticks;
  final int slotCount;
  final double trackExtent;

  /// Where slot 0 sits below the panel's top: half the thumb height.
  final double offset;
  final TextDirection textDirection;

  double _left(Size size) =>
      textDirection == TextDirection.rtl ? size.width - inset - width : inset;

  double _y(int slot) =>
      offset +
      trackForSlot(slot: slot, trackExtent: trackExtent, slotCount: slotCount);

  /// The stripes in the panel's coordinates, in slot order.
  List<Rect> segmentRects(Size size) {
    final left = _left(size);
    final rects = <Rect>[];
    double? previousBottom;
    for (final segment in segments) {
      var top = _y(segment.firstSlot);
      var bottom = _y(segment.lastSlot);
      if (bottom - top < minSegment) {
        final centre = (top + bottom) / 2;
        top = centre - minSegment / 2;
        bottom = centre + minSegment / 2;
      }
      if (previousBottom != null && top < previousBottom + gap) {
        top = previousBottom + gap;
        bottom = math.max(bottom, top + gap);
      }
      rects.add(Rect.fromLTRB(left, top, left + width, bottom));
      previousBottom = bottom;
    }
    return rects;
  }

  /// The ticks in the panel's coordinates, in slot order.
  List<Rect> tickRects(Size size) {
    final left = _left(size);
    return [
      for (final tick in ticks)
        Rect.fromLTWH(
          left,
          _y(tick.slot) - tickThickness / 2,
          width,
          tickThickness,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paths = <Color, Path>{};
    void add(Color color, Rect rect) => (paths[color] ??= Path()).addRect(rect);
    final stripes = segmentRects(size);
    for (var i = 0; i < stripes.length; i++) {
      add(segments[i].color, stripes[i]);
    }
    final marks = tickRects(size);
    for (var i = 0; i < marks.length; i++) {
      add(ticks[i].color, marks[i]);
    }
    for (final MapEntry(key: color, value: path) in paths.entries) {
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(ListScrubberContextPainter oldDelegate) =>
      !identical(oldDelegate.segments, segments) ||
      !identical(oldDelegate.ticks, ticks) ||
      oldDelegate.slotCount != slotCount ||
      oldDelegate.trackExtent != trackExtent ||
      oldDelegate.offset != offset ||
      oldDelegate.textDirection != textDirection;
}
