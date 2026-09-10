import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_import/data/services/dive_resync_orchestrator.dart';
import 'package:submersion/features/dive_import/domain/dive_resync_failure.dart';
import 'package:submersion/features/dive_import/data/repositories/imported_file_repository.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/models/import_payload.dart';
import 'package:submersion/features/universal_import/data/models/import_options.dart';
import 'package:submersion/features/universal_import/data/parsers/import_parser.dart';

class _FakeImportedFiles extends ImportedFileRepository {
  final Map<String, Uint8List> files;
  _FakeImportedFiles(this.files);

  @override
  Future<Uint8List?> read(String id) async => files[id];
}

class _FakeParser implements ImportParser {
  final ImportPayload payload;
  _FakeParser(this.payload);

  @override
  List<ImportFormat> get supportedFormats => [ImportFormat.uddf];

  @override
  Future<ImportPayload> parse(
    Uint8List fileBytes, {
    ImportOptions? options,
  }) async => payload;
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<String> seedDiveWithSource({
    required DateTime dateTime,
    required double maxDepth,
    required int bottomTimeSeconds,
    required String importedFileId,
    String sourceFileFormat = 'uddf',
  }) async {
    const diveId = 'dive-1';
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: diveId,
            diveDateTime: dateTime.millisecondsSinceEpoch,
            maxDepth: Value(maxDepth),
            bottomTime: Value(bottomTimeSeconds),
            createdAt: dateTime.millisecondsSinceEpoch,
            updatedAt: dateTime.millisecondsSinceEpoch,
          ),
        );
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-1',
            diveId: diveId,
            isPrimary: const Value(true),
            importedAt: dateTime,
            createdAt: dateTime,
            sourceFileFormat: Value(sourceFileFormat),
            importedFileId: Value(importedFileId),
          ),
        );
    return diveId;
  }

  test('fails cleanly when the dive has no stored file', () async {
    const diveId = 'dive-none';
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: diveId,
            diveDateTime: 0,
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles(const {}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.noStoredFile);
  });

  test('fails cleanly for a dive that no longer exists', () async {
    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles(const {}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync('does-not-exist');

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.diveMissing);
  });

  test(
    'fails cleanly when this device does not hold the stored file',
    () async {
      final dateTime = DateTime(2026, 9, 1, 9);
      final diveId = await seedDiveWithSource(
        dateTime: dateTime,
        maxDepth: 18.0,
        bottomTimeSeconds: 40 * 60,
        importedFileId: 'file-uddf',
      );

      final orchestrator = DiveResyncOrchestrator(
        db: db,
        importedFiles: _FakeImportedFiles(const {}),
        parserFor: (_) => throw StateError('must not be called'),
      );

      final outcome = await orchestrator.resync(diveId);

      expect(outcome.succeeded, isFalse);
      expect(outcome.failureReason, DiveResyncFailure.storedFileMissing);
    },
  );

  test('fails cleanly for a format resync does not support', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFileId: 'file-csv',
      sourceFileFormat: 'csv',
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-csv': Uint8List(0)}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.unsupportedFormat);
  });

  test('fails cleanly when the stored format string is unrecognized', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFileId: 'file-bin',
      sourceFileFormat: 'someFutureFormatThatDoesNotExistYet',
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-bin': Uint8List(0)}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.unsupportedFormat);
  });

  test('picks the matching dive out of a multi-dive stored file', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFileId: 'file-uddf',
    );

    final payload = ImportPayload(
      entities: {
        ImportEntityType.dives: [
          {
            'dateTime': dateTime.add(const Duration(days: 3)),
            'maxDepth': 30.0,
            'duration': const Duration(minutes: 35),
          },
          {
            'dateTime': dateTime,
            'maxDepth': 18.2,
            'duration': const Duration(minutes: 41),
          },
        ],
      },
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-uddf': Uint8List(0)}),
      parserFor: (_) => _FakeParser(payload),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isTrue);
    final dive = await (db.select(
      db.dives,
    )..where((t) => t.id.equals(diveId))).getSingle();
    expect(dive.maxDepth, 18.2); // matched index 1, not index 0
  });

  test('carries the preserved-profile signal out of the writer', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFileId: 'file-uddf',
    );
    // A second source makes the dive multi-source, so the writer refuses to
    // touch the profile strand and the caller has to be able to say so.
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-2',
            diveId: diveId,
            isPrimary: const Value(false),
            importedAt: dateTime,
            createdAt: dateTime,
          ),
        );

    final payload = ImportPayload(
      entities: {
        ImportEntityType.dives: [
          {
            'dateTime': dateTime,
            'maxDepth': 18.2,
            'duration': const Duration(minutes: 41),
          },
        ],
      },
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-uddf': Uint8List(0)}),
      parserFor: (_) => _FakeParser(payload),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isTrue);
    expect(outcome.profilePreserved, isTrue);
  });

  test('fails when no parsed dive scores as a probable match', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFileId: 'file-uddf',
    );

    final payload = ImportPayload(
      entities: {
        ImportEntityType.dives: [
          {
            'dateTime': dateTime.add(const Duration(days: 30)),
            'maxDepth': 5.0,
            'duration': const Duration(minutes: 10),
          },
        ],
      },
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-uddf': Uint8List(0)}),
      parserFor: (_) => _FakeParser(payload),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.noMatchingDive);
  });

  test('scores a candidate that carries runtime rather than duration', () async {
    // UDDF emits `runtime` and never `duration`, so reading only `duration`
    // drops the 20% duration weight entirely. With a depth the parser fix just
    // moved, time 0.50 + depth 0.10 is 0.60 -- under the 0.70 threshold -- so
    // the resync refuses the very match it exists to deliver.
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 41 * 60,
      importedFileId: 'file-uddf',
    );

    final payload = ImportPayload(
      entities: {
        ImportEntityType.dives: [
          {
            'dateTime': dateTime,
            'maxDepth': 21.0,
            'runtime': const Duration(minutes: 41),
          },
        ],
      },
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-uddf': Uint8List(0)}),
      parserFor: (_) => _FakeParser(payload),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isTrue);
    final dive = await (db.select(
      db.dives,
    )..where((t) => t.id.equals(diveId))).getSingle();
    expect(dive.maxDepth, 21.0);
  });

  test('prefers duration over runtime when a parser fills both', () async {
    // macdiveXml fills both, and they mean different things: `duration` is the
    // bottom time the dive row stores, `runtime` the whole dive. Reading
    // runtime first would score the wrong pair.
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 41 * 60,
      importedFileId: 'file-uddf',
    );

    final payload = ImportPayload(
      entities: {
        ImportEntityType.dives: [
          {
            'dateTime': dateTime,
            'maxDepth': 21.0,
            'duration': const Duration(minutes: 41),
            'runtime': const Duration(minutes: 95),
          },
        ],
      },
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFiles: _FakeImportedFiles({'file-uddf': Uint8List(0)}),
      parserFor: (_) => _FakeParser(payload),
    );

    expect((await orchestrator.resync(diveId)).succeeded, isTrue);
  });
}
