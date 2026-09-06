import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_import/data/services/dive_resync_orchestrator.dart';
import 'package:submersion/features/dive_import/domain/dive_resync_failure.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/models/import_payload.dart';
import 'package:submersion/features/universal_import/data/models/import_options.dart';
import 'package:submersion/features/universal_import/data/parsers/import_parser.dart';

class _FakeImportedFileStore extends ImportedFileStore {
  final Map<String, Uint8List> files;
  _FakeImportedFileStore(this.files);

  @override
  Future<Uint8List?> read(String path) async => files[path];
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
    required String importedFilePath,
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
            importedFilePath: Value(importedFilePath),
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
      importedFileStore: _FakeImportedFileStore(const {}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.noStoredFile);
  });

  test('fails cleanly for a dive that no longer exists', () async {
    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFileStore: _FakeImportedFileStore(const {}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync('does-not-exist');

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.diveMissing);
  });

  test('fails cleanly when the stored file is missing on disk', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFilePath: '/fake/imported/src-1.uddf',
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFileStore: _FakeImportedFileStore(const {}),
      parserFor: (_) => throw StateError('must not be called'),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.storedFileMissing);
  });

  test('fails cleanly for a format resync does not support', () async {
    final dateTime = DateTime(2026, 9, 1, 9);
    final diveId = await seedDiveWithSource(
      dateTime: dateTime,
      maxDepth: 18.0,
      bottomTimeSeconds: 40 * 60,
      importedFilePath: '/fake/imported/src-1.csv',
      sourceFileFormat: 'csv',
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFileStore: _FakeImportedFileStore({
        '/fake/imported/src-1.csv': Uint8List(0),
      }),
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
      importedFilePath: '/fake/imported/src-1.bin',
      sourceFileFormat: 'someFutureFormatThatDoesNotExistYet',
    );

    final orchestrator = DiveResyncOrchestrator(
      db: db,
      importedFileStore: _FakeImportedFileStore({
        '/fake/imported/src-1.bin': Uint8List(0),
      }),
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
      importedFilePath: '/fake/imported/src-1.uddf',
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
      importedFileStore: _FakeImportedFileStore({
        '/fake/imported/src-1.uddf': Uint8List(0),
      }),
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
      importedFilePath: '/fake/imported/src-1.uddf',
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
      importedFileStore: _FakeImportedFileStore({
        '/fake/imported/src-1.uddf': Uint8List(0),
      }),
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
      importedFilePath: '/fake/imported/src-1.uddf',
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
      importedFileStore: _FakeImportedFileStore({
        '/fake/imported/src-1.uddf': Uint8List(0),
      }),
      parserFor: (_) => _FakeParser(payload),
    );

    final outcome = await orchestrator.resync(diveId);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureReason, DiveResyncFailure.noMatchingDive);
  });
}
