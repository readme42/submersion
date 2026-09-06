import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_import/data/services/dive_reimport_service.dart';
import 'package:submersion/features/dive_import/domain/dive_resync_failure.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart'
    as codec;
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;

import '../../../../helpers/test_database.dart';

/// `TankPressureRepository`/`DiveRepository` are zero-arg (no db injection
/// point) and always resolve through `DatabaseService.instance.database`, so
/// the test database must be registered there -- see
/// `test_database.dart`'s `setUpTestDatabase`/`tearDownTestDatabase`, the
/// same helper `tank_pressure_repository_series_writes_test.dart` uses.
void main() {
  late AppDatabase db;
  late DiveReimportService service;

  setUp(() async {
    db = await setUpTestDatabase();
    service = DiveReimportService(db: db);
  });

  tearDown(tearDownTestDatabase);

  Future<String> seedDive({
    required String notes,
    required String buddy,
  }) async {
    const diveId = 'dive-1';
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: diveId,
            diveDateTime: 1000,
            notes: Value(notes),
            buddy: Value(buddy),
            createdAt: 1000,
            updatedAt: 1000,
          ),
        );
    return diveId;
  }

  Future<void> seedTank(
    String diveId, {
    required String id,
    required int tankOrder,
    double? startPressure,
  }) async {
    await db
        .into(db.diveTanks)
        .insert(
          DiveTanksCompanion.insert(
            id: id,
            diveId: diveId,
            tankOrder: Value(tankOrder),
            startPressure: Value(startPressure),
          ),
        );
  }

  test(
    'preserves existing tank ids matched by tankOrder (#276 guard)',
    () async {
      final diveId = await seedDive(notes: 'great viz', buddy: 'Alex');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0, startPressure: 200);
      // Seeded via the real repository (not a raw insert) because
      // tank_pressure_series stores samples as a packed blob, not one row per
      // sample -- see the report's schema-mismatch notes.
      await TankPressureRepository().insertTankPressures(diveId, {
        'tank-a': [(timestamp: 0, pressure: 200.0)],
      });

      final result = await service.applyReimport(
        diveId: diveId,
        diveData: {
          'maxDepth': 18.0,
          'tanks': [
            {'order': 0, 'startPressure': 200.0, 'endPressure': 60.0},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      expect(result.updated, isTrue);
      final tanks = await (db.select(
        db.diveTanks,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(tanks.single.id, 'tank-a'); // NOT a fresh uuid
      final series = await (db.select(
        db.tankPressureSeries,
      )..where((t) => t.tankId.equals('tank-a'))).get();
      expect(series, isNotEmpty); // cascade did not fire
    },
  );

  test(
    'keeps a tank whose order no longer appears in the fresh parse',
    () async {
      // A stage cylinder the diver added by hand is indistinguishable from a
      // tank the old parse invented: dive_tanks carries no provenance. Issue
      // #478 exists because resync must not destroy diver edits, and the
      // dive_tanks -> gas_switches/tank_pressure_series cascade (#276) makes
      // a wrong delete unrecoverable, so an unmatched tank stays.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await seedTank(diveId, id: 'tank-b', tankOrder: 1);
      await TankPressureRepository().insertTankPressures(diveId, {
        'tank-b': [(timestamp: 0, pressure: 200.0)],
      });

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'tanks': [
            {'order': 0, 'startPressure': 200.0},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final tanks = await (db.select(
        db.diveTanks,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(tanks.map((t) => t.id), containsAll(['tank-a', 'tank-b']));
      final series = await (db.select(
        db.tankPressureSeries,
      )..where((t) => t.tankId.equals('tank-b'))).get();
      expect(series, isNotEmpty);
    },
  );

  test('inserts a brand-new tank order the old parse never had', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await seedTank(diveId, id: 'tank-a', tankOrder: 0);

    await service.applyReimport(
      diveId: diveId,
      diveData: {
        'tanks': [
          {'order': 0, 'startPressure': 200.0},
          {'order': 1, 'startPressure': 207.0},
        ],
      },
      now: DateTime(2026, 9, 3),
    );

    final tanks =
        await (db.select(db.diveTanks)
              ..where((t) => t.diveId.equals(diveId))
              ..orderBy([(t) => OrderingTerm.asc(t.tankOrder)]))
            .get();
    expect(tanks.map((t) => t.id), ['tank-a', isNot('tank-a')]);
  });

  test(
    'updates computer-authored dive fields but preserves notes/buddy',
    () async {
      final diveId = await seedDive(notes: 'great viz', buddy: 'Alex');

      await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 22.5, 'avgDepth': 12.0},
        now: DateTime(2026, 9, 3),
      );

      final dive = await (db.select(
        db.dives,
      )..where((t) => t.id.equals(diveId))).getSingle();
      expect(dive.maxDepth, 22.5);
      expect(dive.avgDepth, 12.0);
      expect(dive.notes, 'great viz');
      expect(dive.buddy, 'Alex');
    },
  );

  test('rebuilds gas switches against the preserved tank id', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await seedTank(diveId, id: 'tank-a', tankOrder: 0);
    await db
        .into(db.gasSwitches)
        .insert(
          GasSwitchesCompanion.insert(
            id: 'gs-old',
            diveId: diveId,
            tankId: 'tank-a',
            timestamp: 0,
            createdAt: 0,
          ),
        );

    await service.applyReimport(
      diveId: diveId,
      diveData: {
        'tanks': [
          {'order': 0, 'startPressure': 200.0},
        ],
        'gasSwitches': [
          {'timestamp': 0, 'tankIndex': 0},
          {'timestamp': 600, 'tankIndex': 0},
        ],
      },
      now: DateTime(2026, 9, 3),
    );

    final switches = await (db.select(
      db.gasSwitches,
    )..where((t) => t.diveId.equals(diveId))).get();
    expect(switches, hasLength(2));
    expect(switches.every((s) => s.tankId == 'tank-a'), isTrue);
  });

  test(
    'preserves existing gas switches when diveData has no gasSwitches key',
    () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await db
          .into(db.gasSwitches)
          .insert(
            GasSwitchesCompanion.insert(
              id: 'gs-old',
              diveId: diveId,
              tankId: 'tank-a',
              timestamp: 0,
              createdAt: 0,
            ),
          );

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'maxDepth': 18.0,
          'tanks': [
            {'order': 0, 'startPressure': 200.0},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final switches = await (db.select(
        db.gasSwitches,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(switches, hasLength(1));
      expect(switches.single.id, 'gs-old');
    },
  );

  test('reports skipped for a dive with no rows', () async {
    final result = await service.applyReimport(
      diveId: 'does-not-exist',
      diveData: const {},
      now: DateTime(2026, 9, 3),
    );
    expect(result.updated, isFalse);
    expect(result.skippedReason, DiveResyncFailure.diveMissing);
  });

  test('refreshes the primary dive_data_sources snapshot', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-1',
            diveId: diveId,
            isPrimary: const Value(true),
            importedAt: DateTime.fromMillisecondsSinceEpoch(0),
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            maxDepth: const Value(10.0),
          ),
        );

    await service.applyReimport(
      diveId: diveId,
      diveData: {'maxDepth': 25.0, 'avgDepth': 14.0},
      now: DateTime(2026, 9, 3),
    );

    final source = await (db.select(
      db.diveDataSources,
    )..where((t) => t.id.equals('src-1'))).getSingle();
    expect(source.maxDepth, 25.0);
    expect(source.avgDepth, 14.0);
  });

  test(
    'refreshes entryTime/exitTime/duration/cns/otu from the real parser shapes',
    () async {
      // entryTime/exitTime are DateTimes (only uddf_full_import_service.dart
      // ever emits entryTime, from DateTime.tryParse) and duration is always
      // a Duration (fit/macdive/subsurface/danDl7/ratioXml all emit one) --
      // never epoch-millis ints or raw seconds ints.
      final diveId = await seedDive(notes: '', buddy: '');
      await db
          .into(db.diveDataSources)
          .insert(
            DiveDataSourcesCompanion.insert(
              id: 'src-1',
              diveId: diveId,
              isPrimary: const Value(true),
              importedAt: DateTime.fromMillisecondsSinceEpoch(0),
              createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          );

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'entryTime': DateTime(2026, 9, 1, 9),
          'exitTime': DateTime(2026, 9, 1, 9, 41),
          'duration': const Duration(minutes: 40),
          'cnsEnd': 12.5,
          'otu': 8.0,
        },
        now: DateTime(2026, 9, 3),
      );

      final source = await (db.select(
        db.diveDataSources,
      )..where((t) => t.id.equals('src-1'))).getSingle();
      expect(source.entryTime, DateTime(2026, 9, 1, 9));
      expect(source.exitTime, DateTime(2026, 9, 1, 9, 41));
      expect(source.duration, 40 * 60);
      expect(source.cns, 12.5);
      expect(source.otu, 8.0);
    },
  );

  test(
    'marks the dive, its tanks, and its primary source pending sync',
    () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await db
          .into(db.diveDataSources)
          .insert(
            DiveDataSourcesCompanion.insert(
              id: 'src-1',
              diveId: diveId,
              isPrimary: const Value(true),
              importedAt: DateTime.fromMillisecondsSinceEpoch(0),
              createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          );
      final syncRepository = SyncRepository(database: db);
      final serviceWithSync = DiveReimportService(
        db: db,
        syncRepository: syncRepository,
      );

      await serviceWithSync.applyReimport(
        diveId: diveId,
        diveData: {
          'maxDepth': 20.0,
          'tanks': [
            {'order': 0, 'startPressure': 200.0},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final pending = await syncRepository.getPendingRecords();
      final pendingByType = <String, Set<String>>{};
      for (final record in pending) {
        pendingByType
            .putIfAbsent(record.entityType, () => {})
            .add(record.recordId);
      }
      expect(pendingByType['dives'], contains(diveId));
      expect(pendingByType['diveTanks'], contains('tank-a'));
      expect(pendingByType['diveDataSources'], contains('src-1'));
    },
  );

  Future<void> seedSource(
    String diveId, {
    required String id,
    bool isPrimary = true,
    String? computerId,
    Uint8List? rawData,
  }) async {
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: id,
            diveId: diveId,
            isPrimary: Value(isPrimary),
            computerId: Value(computerId),
            rawData: Value(rawData),
            importedAt: DateTime.fromMillisecondsSinceEpoch(0),
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
  }

  Future<void> seedComputer(String id) async {
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion.insert(
            id: id,
            name: 'Perdix',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  }

  const profileWithPressure = [
    {
      'timestamp': 0,
      'depth': 0.0,
      'allTankPressures': [
        {'tankIndex': 0, 'pressure': 200.0},
      ],
    },
    {
      'timestamp': 60,
      'depth': 20.0,
      'allTankPressures': [
        {'tankIndex': 0, 'pressure': 180.0},
      ],
    },
    {
      'timestamp': 1200,
      'depth': 20.0,
      'allTankPressures': [
        {'tankIndex': 0, 'pressure': 90.0},
      ],
    },
    {'timestamp': 1500, 'depth': 3.0},
  ];

  group('source ownership (#1164/#1177 guards)', () {
    test('a multi-source dive keeps every source strand untouched', () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedComputer('computer-perdix');
      await seedSource(diveId, id: 'src-file');
      await seedSource(
        diveId,
        id: 'src-perdix',
        isPrimary: false,
        computerId: 'computer-perdix',
        rawData: Uint8List.fromList([1, 2, 3]),
      );
      await seedTank(diveId, id: 'tank-a', tankOrder: 0, startPressure: 200);
      await db
          .into(db.gasSwitches)
          .insert(
            GasSwitchesCompanion.insert(
              id: 'gs-perdix',
              diveId: diveId,
              tankId: 'tank-a',
              timestamp: 0,
              createdAt: 0,
            ),
          );
      await TankPressureRepository().insertTankPressures(diveId, {
        'tank-a': [(timestamp: 0, pressure: 200.0)],
      });
      await ProfileSeriesRepository(database: db).insertSeries(
        diveId: diveId,
        computerId: 'computer-perdix',
        sourceId: 'src-perdix',
        samples: const [
          codec.ProfileSample(timestamp: 0, depth: 0.0),
          codec.ProfileSample(timestamp: 60, depth: 30.0),
        ],
      );

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'maxDepth': 18.0,
          'tanks': [
            {'order': 0, 'startPressure': 200.0},
          ],
          'gasSwitches': [
            {'timestamp': 900, 'tankIndex': 0},
          ],
          'profile': profileWithPressure,
        },
        now: DateTime(2026, 9, 3),
      );

      final switches = await (db.select(
        db.gasSwitches,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(switches.map((row) => row.id), [
        'gs-perdix',
      ], reason: 'the other source authored these; resync must not touch them');

      final pressures = await (db.select(
        db.tankPressureSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(pressures, hasLength(1));

      final series = await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(series.map((row) => row.sourceId), [
        'src-perdix',
      ], reason: 'the consolidated strand must survive a resync intact');
    });

    test('a multi-source dive reports its profile as preserved', () async {
      // The write is real -- the primary source still owns the dive header --
      // but the profile, switches and pressures are deliberately untouched,
      // so "Dive updated from the original file" would be a lie. Same signal
      // ReparseService surfaces as profilesPreserved (#1164).
      final diveId = await seedDive(notes: '', buddy: '');
      await seedSource(diveId, id: 'src-file');
      await seedSource(diveId, id: 'src-perdix', isPrimary: false);

      final result = await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 18.0, 'profile': profileWithPressure},
        now: DateTime(2026, 9, 3),
      );

      expect(result.updated, isTrue);
      expect(result.profilePreserved, isTrue);
    });

    test('a single-source dive reports nothing preserved', () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedSource(diveId, id: 'src-file');

      final result = await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 18.0, 'profile': profileWithPressure},
        now: DateTime(2026, 9, 3),
      );

      expect(result.profilePreserved, isFalse);
    });

    test('a combined dive (no primary source row) keeps its dive header '
        'too', () async {
      // No row claims to have authored this dive's summary, so nothing in the
      // fresh parse is entitled to overwrite it -- the same rule
      // ReparseService applies by writing the dive row only for the primary
      // source.
      final diveId = await seedDive(notes: '', buddy: '');
      await (db.update(db.dives)..where((t) => t.id.equals(diveId))).write(
        const DivesCompanion(maxDepth: Value(31.0)),
      );
      await seedSource(diveId, id: 'src-a', isPrimary: false);
      await seedSource(diveId, id: 'src-b', isPrimary: false);

      final result = await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 18.0},
        now: DateTime(2026, 9, 3),
      );

      final dive = await (db.select(
        db.dives,
      )..where((t) => t.id.equals(diveId))).getSingle();
      expect(dive.maxDepth, 31.0);
      expect(result.profilePreserved, isTrue);
    });

    test('a combined dive (no primary source row) is left alone', () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedSource(diveId, id: 'src-a', isPrimary: false);
      await seedSource(diveId, id: 'src-b', isPrimary: false);
      await ProfileSeriesRepository(database: db).insertSeries(
        diveId: diveId,
        samples: const [
          codec.ProfileSample(timestamp: 0, depth: 0.0),
          codec.ProfileSample(timestamp: 60, depth: 30.0),
        ],
      );

      await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 18.0, 'profile': profileWithPressure},
        now: DateTime(2026, 9, 3),
      );

      final series = await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(series, hasLength(1));
      expect(series.single.sampleCount, 2);
    });

    test('a single-source dive gets its profile replaced, attributed to '
        'the source it came from', () async {
      final diveId = await seedDive(notes: '', buddy: '');
      await seedComputer('computer-perdix');
      await seedSource(diveId, id: 'src-file', computerId: 'computer-perdix');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await ProfileSeriesRepository(database: db).insertSeries(
        diveId: diveId,
        samples: const [codec.ProfileSample(timestamp: 0, depth: 0.0)],
      );

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'maxDepth': 20.0,
          'tanks': [
            {'order': 0, 'startPressure': 200.0},
          ],
          'profile': profileWithPressure,
        },
        now: DateTime(2026, 9, 3),
      );

      final series = await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(series, hasLength(1));
      expect(series.single.sampleCount, 4);
      expect(series.single.sourceId, 'src-file');
      expect(
        series.single.computerId,
        isNull,
        reason:
            'a file import writes its samples with no computer; stamping one '
            'joins the delete scope of that computer',
      );
    });

    test('a profile the diver hand-edited survives the resync', () async {
      // saveEditedProfile writes the correction as a primary, null-computer
      // series owned by the primary source and demotes the parsed strand it
      // corrects. On a single-source dive the resync owns everything, so a
      // dive-wide profile delete takes the correction with it and tombstones
      // it to every peer -- the exact harm #478 exists to remove.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedSource(diveId, id: 'src-file');
      await ProfileSeriesRepository(database: db).insertSeries(
        diveId: diveId,
        samples: const [
          codec.ProfileSample(timestamp: 0, depth: 0.0),
          codec.ProfileSample(timestamp: 60, depth: 18.0),
        ],
      );
      await DiveRepository().saveEditedProfile(diveId, const [
        domain.DiveProfilePoint(timestamp: 0, depth: 0.0),
        domain.DiveProfilePoint(timestamp: 60, depth: 17.0),
        domain.DiveProfilePoint(timestamp: 120, depth: 16.0),
      ]);
      final editId = (await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.isPrimary.equals(true))).getSingle()).id;

      await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 20.0, 'profile': profileWithPressure},
        now: DateTime(2026, 9, 3),
      );

      final series = await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      final edit = series.where((row) => row.id == editId);
      expect(
        edit,
        hasLength(1),
        reason: 'the hand-edited series is not the parser to delete',
      );
      expect(edit.single.isPrimary, isTrue);
      expect(edit.single.sampleCount, 3);

      final fresh = series.where((row) => row.id != editId);
      expect(
        fresh.map((row) => row.sampleCount),
        [profileWithPressure.length],
        reason:
            'the fresh parse still lands, demoted under the correction the '
            'diver made',
      );
      expect(fresh.single.isPrimary, isFalse);
    });

    test('the resynced strand survives a re-parse of the computer the '
        'file import was matched to', () async {
      // matchImportedComputer matches a file import to an already-registered
      // downloaded computer on serial alone, so a file source row routinely
      // carries a physical computer's id while its rawData stays null --
      // invisible to sourceOwnsProfileStrand's contention check. If resync
      // stamps that computer on the profile, the next reparse of the
      // computer's own download deletes the file strand too (#478).
      final diveId = await seedDive(notes: '', buddy: '');
      await seedComputer('computer-perdix');
      await seedSource(diveId, id: 'src-file', computerId: 'computer-perdix');
      await ProfileSeriesRepository(database: db).insertSeries(
        diveId: diveId,
        samples: const [codec.ProfileSample(timestamp: 0, depth: 0.0)],
      );

      await service.applyReimport(
        diveId: diveId,
        diveData: {'maxDepth': 20.0, 'profile': profileWithPressure},
        now: DateTime(2026, 9, 3),
      );

      await ProfileSeriesRepository(
        database: db,
      ).deleteByComputer(diveId, 'computer-perdix');

      final series = await (db.select(
        db.diveProfileSeries,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(series, hasLength(1));
      expect(series.single.sampleCount, 4);
    });
  });

  test('keeps the pressure series of a tank the fresh parse never '
      'mentions', () async {
    // The unmatched tank is deliberately kept (dive_tanks has no provenance,
    // and the #276 cascade makes a wrong delete unrecoverable), so its
    // pressures have to be kept with it: a dive-wide delete leaves the diver
    // a stage cylinder with its history tombstoned away.
    final diveId = await seedDive(notes: '', buddy: '');
    await seedSource(diveId, id: 'src-file');
    await seedTank(diveId, id: 'tank-a', tankOrder: 0);
    await seedTank(diveId, id: 'diver-stage', tankOrder: 1);
    await TankPressureRepository().insertTankPressures(diveId, {
      'tank-a': [(timestamp: 0, pressure: 190.0)],
      'diver-stage': [(timestamp: 900, pressure: 180.0)],
    });

    await service.applyReimport(
      diveId: diveId,
      diveData: {
        'tanks': [
          {'order': 0, 'startPressure': 200.0},
        ],
        'profile': profileWithPressure,
      },
      now: DateTime(2026, 9, 3),
    );

    final stage = await TankPressureRepository().getPressuresForTank(
      diveId,
      'diver-stage',
    );
    expect(stage.map((p) => p.timestamp), [900]);
    expect(stage.single.pressure, 180.0);

    final replaced = await TankPressureRepository().getPressuresForTank(
      diveId,
      'tank-a',
    );
    expect(replaced.map((p) => p.timestamp), [
      0,
      60,
      1200,
    ], reason: 'a tank the fresh parse does cover is still replaced whole');
    expect(replaced.first.pressure, 200.0);
  });

  test('a profile with no pressure samples leaves pressure history '
      'alone', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await seedSource(diveId, id: 'src-file');
    await seedTank(diveId, id: 'tank-a', tankOrder: 0);
    await TankPressureRepository().insertTankPressures(diveId, {
      'tank-a': [(timestamp: 600, pressure: 120.0)],
    });

    await service.applyReimport(
      diveId: diveId,
      diveData: {
        'tanks': [
          {'order': 0, 'startPressure': 200.0},
        ],
        'profile': const [
          {'timestamp': 0, 'depth': 0.0},
          {'timestamp': 60, 'depth': 20.0},
          {'timestamp': 1200, 'depth': 20.0},
        ],
      },
      now: DateTime(2026, 9, 3),
    );

    final series = await (db.select(
      db.tankPressureSeries,
    )..where((t) => t.tankId.equals('tank-a'))).get();
    expect(series, isNotEmpty);
  });

  test('recomputes bottomTime from the replaced profile', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await seedSource(diveId, id: 'src-file');
    await (db.update(db.dives)..where((t) => t.id.equals(diveId))).write(
      const DivesCompanion(bottomTime: Value(99)),
    );

    await service.applyReimport(
      diveId: diveId,
      diveData: {'maxDepth': 20.0, 'profile': profileWithPressure},
      now: DateTime(2026, 9, 3),
    );

    final dive = await (db.select(
      db.dives,
    )..where((t) => t.id.equals(diveId))).getSingle();
    expect(dive.bottomTime, 1200);
  });

  group('fresh-parse tank identity (the keys real parsers emit)', () {
    test('resolves gas switches by tankRef, the key subsurface and DAN DL7 '
        'emit', () async {
      // subsurface_xml_parser and dan_dl7_import_parser never put `tankIndex`
      // on a gas switch: the switch carries `tankRef` and the tank it names
      // carries the matching `uddfTankId`, which is what the import path
      // resolves against.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await seedTank(diveId, id: 'tank-b', tankOrder: 1);

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'tanks': [
            {'order': 0, 'uddfTankId': '0:back gas', 'startPressure': 200.0},
            {'order': 1, 'uddfTankId': '1:deco', 'startPressure': 207.0},
          ],
          'gasSwitches': [
            {'timestamp': 0, 'tankRef': '0:back gas'},
            {'timestamp': 1200, 'tankRef': '1:deco'},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final switches =
          await (db.select(db.gasSwitches)
                ..where((t) => t.diveId.equals(diveId))
                ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
              .get();
      expect(switches.map((s) => s.tankId), ['tank-a', 'tank-b']);
    });

    test('resolves gas switches by gasMixRef, the key UDDF <switchmix> '
        'emits', () async {
      // MacDive-style UDDF marks a gas change with <switchmix ref>, so the
      // switch names a gas mix UUID and the tank carries `uddfGasMixRef`.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await seedTank(diveId, id: 'tank-b', tankOrder: 1);

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'tanks': [
            {'order': 0, 'uddfGasMixRef': 'mix-air', 'startPressure': 200.0},
            {'order': 1, 'uddfGasMixRef': 'mix-ean50', 'startPressure': 207.0},
          ],
          'gasSwitches': [
            {'timestamp': 0, 'gasMixRef': 'mix-air'},
            {'timestamp': 1200, 'gasMixRef': 'mix-ean50'},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final switches =
          await (db.select(db.gasSwitches)
                ..where((t) => t.diveId.equals(diveId))
                ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
              .get();
      expect(switches.map((s) => s.tankId), ['tank-a', 'tank-b']);
    });

    test('reads allTankPressures positionally, not by the parsed tank '
        'order', () async {
      // A UDDF re-import carries <tankorder> verbatim, so `order` is whatever
      // dive_tanks held (1 and 2 here, after the diver removed the original
      // first cylinder), while allTankPressures' `tankIndex` is an index into
      // the tanks list -- uddf_full_import_service builds it from
      // `tankRefToIndex[uddfTankId] = i`.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 1);
      await seedTank(diveId, id: 'tank-b', tankOrder: 2);

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'tanks': [
            {'order': 1, 'startPressure': 200.0},
            {'order': 2, 'startPressure': 207.0},
          ],
          'profile': const [
            {
              'timestamp': 0,
              'depth': 0.0,
              'allTankPressures': [
                {'tankIndex': 0, 'pressure': 200.0},
                {'tankIndex': 1, 'pressure': 207.0},
              ],
            },
            {
              'timestamp': 600,
              'depth': 20.0,
              'allTankPressures': [
                {'tankIndex': 0, 'pressure': 150.0},
                {'tankIndex': 1, 'pressure': 207.0},
              ],
            },
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final back = await TankPressureRepository().getPressuresForTank(
        diveId,
        'tank-a',
      );
      expect(back.map((p) => p.pressure), [200.0, 150.0]);
      final deco = await TankPressureRepository().getPressuresForTank(
        diveId,
        'tank-b',
      );
      expect(deco.map((p) => p.pressure), [207.0, 207.0]);
    });

    test('carries over one existing row per parsed tank when the parser '
        'omits order', () async {
      // ShearwaterDiveMapper.mapTanks emits no `order` key at all, so the
      // import wrote every row with tank_order 0 and the fresh parse has
      // nothing but list position to identify a tank by.
      final diveId = await seedDive(notes: '', buddy: '');
      await seedTank(diveId, id: 'tank-a', tankOrder: 0);
      await seedTank(diveId, id: 'tank-b', tankOrder: 0);

      await service.applyReimport(
        diveId: diveId,
        diveData: {
          'tanks': [
            {'gasMix': const domain.GasMix(o2: 32.0), 'startPressure': 200.0},
            {'gasMix': const domain.GasMix(o2: 50.0), 'startPressure': 207.0},
          ],
        },
        now: DateTime(2026, 9, 3),
      );

      final tanks = await (db.select(
        db.diveTanks,
      )..where((t) => t.diveId.equals(diveId))).get();
      expect(
        tanks.map((t) => t.id),
        unorderedEquals(['tank-a', 'tank-b']),
        reason: 'no third row invented, no row dropped',
      );
      final byId = {for (final t in tanks) t.id: t};
      expect(byId['tank-a']!.o2Percent, 32.0);
      expect(byId['tank-a']!.startPressure, 200.0);
      expect(byId['tank-b']!.o2Percent, 50.0);
      expect(byId['tank-b']!.startPressure, 207.0);
    });
  });

  test('falls back to the parsed duration when no profile resolves '
      'a bottom time', () async {
    final diveId = await seedDive(notes: '', buddy: '');
    await seedSource(diveId, id: 'src-file');

    await service.applyReimport(
      diveId: diveId,
      diveData: {'maxDepth': 20.0, 'duration': const Duration(minutes: 33)},
      now: DateTime(2026, 9, 3),
    );

    final dive = await (db.select(
      db.dives,
    )..where((t) => t.id.equals(diveId))).getSingle();
    expect(dive.bottomTime, 33 * 60);
  });
}
