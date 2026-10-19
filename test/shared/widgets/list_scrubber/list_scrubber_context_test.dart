import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber_context_painter.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber_geometry.dart';
import 'package:submersion/shared/widgets/list_scrubber/scrubber_marker.dart';

void main() {
  late ScrollController controller;
  setUp(() => controller = ScrollController());
  tearDown(() => controller.dispose());

  const stripe = Color(0xFF7D5260);
  const deep = Color(0xFFC62828);
  const warn = Color(0xFF955300);
  const segments = [
    ScrubberSegment(firstSlot: 10, lastSlot: 40, color: stripe),
    ScrubberSegment(firstSlot: 90, lastSlot: 90, color: deep),
  ];
  const ticks = [
    ScrubberTick(slot: 60, color: warn),
    ScrubberTick(slot: 150, color: warn),
  ];

  Widget host({
    List<ScrubberSegment> segments = segments,
    List<ScrubberTick> ticks = ticks,
    TextDirection direction = TextDirection.ltr,
    ValueChanged<int>? onRowTap,
  }) => MaterialApp(
    home: Scaffold(
      body: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: 600,
            width: 800,
            child: ListScrubber(
              controller: controller,
              slotCount: 200,
              loadedSlotCount: 200,
              labelFor: (slot) => 'Slot $slot',
              markers: const [ScrubberMarker(slot: 0, label: 'Top')],
              segments: segments,
              contextTicks: ticks,
              onScrubEnd: (_) {},
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemExtent: 50,
                itemBuilder: (_, i) => onRowTap == null
                    ? Text('Row $i')
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onRowTap(i),
                        child: Text('Row $i'),
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder contextPaint() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is ListScrubberContextPainter,
  );

  ListScrubberContextPainter painterOf(WidgetTester tester) =>
      tester.widget<CustomPaint>(contextPaint()).painter!
          as ListScrubberContextPainter;

  List<Rect> global(WidgetTester tester, List<Rect> Function(Size) rects) {
    final box = tester.getRect(contextPaint());
    return [for (final r in rects(box.size)) r.shift(box.topLeft)];
  }

  double y(int slot) =>
      24 + trackForSlot(slot: slot, trackExtent: 552, slotCount: 200);

  Future<TestGesture> hover(WidgetTester tester, {double x = 780}) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(x, 400));
    await tester.pumpAndSettle();
    return mouse;
  }

  Future<void> leave(WidgetTester tester, TestGesture mouse) async {
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.pump(ListScrubber.idleHide);
  }

  testWidgets('segments and ticks paint in the panel while active', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    final mouse = await hover(tester);

    expect(
      find.ancestor(
        of: contextPaint(),
        matching: find.byKey(ListScrubber.panelKey),
      ),
      findsOneWidget,
    );
    final painter = painterOf(tester);
    expect(painter.segments, segments);
    expect(painter.ticks, ticks);

    final bars = global(tester, painter.segmentRects);
    expect(bars[0].top, closeTo(y(10), 0.01));
    expect(bars[0].bottom, closeTo(y(40), 0.01));
    expect(bars[1].height, ListScrubberContextPainter.minSegment);
    expect(bars[1].center.dy, closeTo(y(90), 0.01));

    final marks = global(tester, painter.tickRects);
    expect(marks, hasLength(2));
    expect(marks[0].center.dy, closeTo(y(60), 0.01));
    expect(marks[1].center.dy, closeTo(y(150), 0.01));
    expect(marks[0].height, ListScrubberContextPainter.tickThickness);
    await leave(tester, mouse);
  });

  testWidgets('the column sits at the panel start edge, apart from the thumb', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    final mouse = await hover(tester);
    final panel = tester.getRect(find.byKey(ListScrubber.panelKey));
    final painter = painterOf(tester);
    for (final r in [
      ...global(tester, painter.segmentRects),
      ...global(tester, painter.tickRects),
    ]) {
      expect(r.left, panel.left + ListScrubberContextPainter.inset);
      expect(r.width, ListScrubberContextPainter.width);
    }
    await leave(tester, mouse);
  });

  testWidgets('the column mirrors to the panel start edge in RTL', (
    tester,
  ) async {
    await tester.pumpWidget(host(direction: TextDirection.rtl));
    await tester.pump();
    final mouse = await hover(tester, x: 20);
    final panel = tester.getRect(find.byKey(ListScrubber.panelKey));
    expect(panel.left, 0);
    final painter = painterOf(tester);
    for (final r in [
      ...global(tester, painter.segmentRects),
      ...global(tester, painter.tickRects),
    ]) {
      expect(r.right, panel.right - ListScrubberContextPainter.inset);
      expect(r.width, ListScrubberContextPainter.width);
    }
    await leave(tester, mouse);
  });

  testWidgets('nothing paints while idle', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    controller.jumpTo(500);
    await tester.pump();
    expect(find.byKey(ListScrubber.thumbKey), findsOneWidget);
    expect(contextPaint(), findsNothing);
    await tester.pump(ListScrubber.idleHide);
  });

  testWidgets('the column is left out without segments or ticks', (
    tester,
  ) async {
    await tester.pumpWidget(host(segments: const [], ticks: const []));
    await tester.pump();
    final mouse = await hover(tester);
    expect(contextPaint(), findsNothing);
    await leave(tester, mouse);
  });

  testWidgets('a tap on the column reaches the row', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(host(onRowTap: (i) => tapped = i));
    await tester.pump();
    final mouse = await hover(tester);
    final bar = global(tester, painterOf(tester).segmentRects).first;
    await tester.tapAt(bar.center);
    await tester.pump();
    expect(tapped, (bar.center.dy / 50).floor());
    await leave(tester, mouse);
  });

  group('painter', () {
    ListScrubberContextPainter painter({
      List<ScrubberSegment> segments = segments,
      List<ScrubberTick> ticks = ticks,
      int slotCount = 200,
    }) => ListScrubberContextPainter(
      segments: segments,
      ticks: ticks,
      slotCount: slotCount,
      trackExtent: 400,
      offset: 24,
      textDirection: TextDirection.ltr,
    );

    test('touching segments keep a 1 px gap', () {
      final rects = painter(
        segments: const [
          ScrubberSegment(firstSlot: 0, lastSlot: 499, color: stripe),
          ScrubberSegment(firstSlot: 500, lastSlot: 520, color: stripe),
          ScrubberSegment(firstSlot: 521, lastSlot: 521, color: stripe),
        ],
        slotCount: 1001,
      ).segmentRects(const Size(64, 448));
      for (var i = 1; i < rects.length; i++) {
        expect(
          rects[i].top - rects[i - 1].bottom,
          greaterThanOrEqualTo(ListScrubberContextPainter.gap),
        );
        expect(rects[i].height, greaterThan(0));
      }
    });

    test('repaints only when its inputs change', () {
      final a = painter();
      expect(a.shouldRepaint(painter()), isFalse);
      expect(a.shouldRepaint(painter(segments: [...segments])), isTrue);
      expect(a.shouldRepaint(painter(ticks: [...ticks])), isTrue);
    });
  });
}
