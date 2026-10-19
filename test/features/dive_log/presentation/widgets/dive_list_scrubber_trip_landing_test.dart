import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/constants/list_view_mode.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_scrubber_entry.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_summary.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/trip_group_collapse_provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/dive_list_content.dart';
import 'package:submersion/features/dive_log/presentation/widgets/trip_group_header.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber.dart';
import 'package:submersion/shared/widgets/list_scrubber/list_scrubber_geometry.dart';
import 'package:submersion/shared/widgets/master_detail/keyboard_list_navigator.dart';

import '../../../../helpers/mock_providers.dart';
import '../../../../helpers/test_app.dart';
import 'dive_list_trip_grouping_test.dart' show makeDive;
import 'dive_scrubber_index_override.dart';

class _LoadingNotifier extends StateNotifier<AsyncValue<PaginatedDiveListState>>
    implements PaginatedDiveListNotifier {
  _LoadingNotifier(this.all)
    : super(
        AsyncValue.data(
          PaginatedDiveListState(
            dives: all.take(50).toList(),
            totalCount: all.length,
            revision: 1,
          ),
        ),
      );

  final List<DiveSummary> all;

  @override
  Future<bool> loadThrough(String diveId, {required int targetIndex}) async {
    final through = (targetIndex + 51).clamp(0, all.length);
    state = AsyncValue.data(
      state.value!.copyWith(
        dives: all.take(through).toList(),
        hasMore: through < all.length,
      ),
    );
    return true;
  }

  @override
  Future<void> loadNextPage() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const tripFirst = 200;
  const tripLast = 220;
  const target = 210;

  final dives = [
    for (var i = 0; i < 300; i++)
      i >= tripFirst && i <= tripLast
          ? makeDive('d$i', tripId: 't1', tripName: 'Red Sea')
          : makeDive('d$i'),
  ];
  final index = [
    for (final d in dives)
      DiveScrubberEntry(
        id: d.id,
        sortTimestamp: d.sortTimestamp,
        diveNumber: d.diveNumber,
        siteName: d.siteName,
        tripId: d.tripId,
        tripName: d.tripName,
      ),
  ];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final mode in [ListViewMode.compact, ListViewMode.detailed]) {
    testWidgets('a drop inside an expanded trip lands below its pinned '
        'header (${mode.name})', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = await getBaseOverrides();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(kCollapsedTripIdsPrefsKey, const []);

      await tester.pumpWidget(
        testApp(
          locale: const Locale('en'),
          overrides: [
            ...base,
            diveListViewModeProvider.overrideWith((ref) => mode),
            diveListGroupTripsProvider.overrideWith((ref) => true),
            tripDiveCountsProvider.overrideWith(
              (ref) async => const {'t1': tripLast - tripFirst + 1},
            ),
            collapsedTripIdsProvider.overrideWith(
              (ref) => CollapsedTripsNotifier(prefs, null),
            ),
            paginatedDiveListProvider.overrideWith(
              (ref) => _LoadingNotifier(dives),
            ),
            diveScrubberIndexOverride(() => index),
          ],
          child: const DiveListContent(showAppBar: false),
        ),
      );
      await settle(tester);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -50));
      await tester.pump();
      final list = tester.getRect(find.byType(CustomScrollView));
      final thumbY = tester.getTopLeft(find.byKey(ListScrubber.thumbKey)).dy;
      final track = trackForSlot(
        slot: target,
        trackExtent: list.height - 48,
        slotCount: dives.length,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ListScrubber.thumbKey)),
      );
      await gesture.moveBy(Offset(0, list.top + track - thumbY));
      await tester.pump();
      await gesture.up();
      await settle(tester);

      final card = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is KeyboardListItem && w.navigationKey == 'd$target',
        ),
      );
      final header = tester.getRect(find.byType(TripGroupHeader));
      expect(header.top, closeTo(list.top, 1));
      expect(card.top, greaterThanOrEqualTo(header.bottom - 0.5));
      expect(card.top, lessThan(header.bottom + card.height));
    });
  }
}
