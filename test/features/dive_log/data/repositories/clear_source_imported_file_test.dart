import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_cleanup.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_computer_repository_impl.dart';

import '../../../../helpers/test_database.dart';

/// The replaceSource path deletes the `dive_data_sources` row for a
/// dive+computer pair. When that row is the last one naming a stored import
/// copy (issue #478), the bytes have to go with it -- and when it is not,
/// they have to stay.
void main() {
  late AppDatabase db;
  late Directory tempDocsDir;
  late ImportedFileStore store;
  late DiveComputerRepository repo;

  setUp(() async {
    db = await setUpTestDatabase();
    await db.customStatement('PRAGMA foreign_keys = OFF');
    tempDocsDir = await Directory.systemTemp.createTemp(
      'clear_source_imported_file_test',
    );
    store = ImportedFileStore(documentsDirectory: () async => tempDocsDir);
    repo = DiveComputerRepository(
      importedFileCleanup: ImportedFileCleanup(store: store),
    );
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (await tempDocsDir.exists()) {
      await tempDocsDir.delete(recursive: true);
    }
  });

  Future<void> insertDive(String id) async {
    const epoch = 1700000000000;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: id,
            diveDateTime: epoch,
            createdAt: epoch,
            updatedAt: epoch,
          ),
        );
  }

  Future<String> storeFile({List<int> bytes = const [1, 2, 3]}) => store.store(
    bytes: Uint8List.fromList(bytes),
    originalFileName: 'logbook.uddf',
  );

  Future<void> insertSource({
    required String id,
    required String diveId,
    required String computerId,
    String? importedFilePath,
  }) async {
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: id,
            diveId: diveId,
            computerId: Value(computerId),
            isPrimary: const Value(true),
            importedAt: DateTime(2026, 1, 1),
            createdAt: DateTime(2026, 1, 1),
            sourceFileFormat: const Value('uddf'),
            importedFilePath: Value(importedFilePath),
          ),
        );
  }

  test('deletes the stored file whose last pointer it removes', () async {
    await insertDive('dive-1');
    final path = await storeFile();
    await insertSource(
      id: 'src-1',
      diveId: 'dive-1',
      computerId: 'comp-1',
      importedFilePath: path,
    );

    await repo.clearSourceAndProfiles(diveId: 'dive-1', computerId: 'comp-1');

    expect(await File(await store.absolutePathFor(path)).exists(), isFalse);
  });

  test('keeps a stored file another dive still points at', () async {
    await insertDive('dive-1');
    await insertDive('dive-2');
    final path = await storeFile();
    await insertSource(
      id: 'src-1',
      diveId: 'dive-1',
      computerId: 'comp-1',
      importedFilePath: path,
    );
    await insertSource(
      id: 'src-2',
      diveId: 'dive-2',
      computerId: 'comp-1',
      importedFilePath: path,
    );

    await repo.clearSourceAndProfiles(diveId: 'dive-1', computerId: 'comp-1');

    expect(await File(await store.absolutePathFor(path)).exists(), isTrue);
  });

  test('keeps a stored file a surviving source of the same dive '
      'points at', () async {
    await insertDive('dive-1');
    final path = await storeFile();
    await insertSource(
      id: 'src-1',
      diveId: 'dive-1',
      computerId: 'comp-1',
      importedFilePath: path,
    );
    await insertSource(
      id: 'src-2',
      diveId: 'dive-1',
      computerId: 'comp-2',
      importedFilePath: path,
    );

    await repo.clearSourceAndProfiles(diveId: 'dive-1', computerId: 'comp-1');

    expect(await File(await store.absolutePathFor(path)).exists(), isTrue);
  });

  test('the row goes before the bytes', () async {
    await insertDive('dive-1');
    final path = await storeFile();
    await insertSource(
      id: 'src-1',
      diveId: 'dive-1',
      computerId: 'comp-1',
      importedFilePath: path,
    );

    await repo.clearSourceAndProfiles(diveId: 'dive-1', computerId: 'comp-1');

    final rows = await db.select(db.diveDataSources).get();
    expect(rows, isEmpty);
    expect(await File(await store.absolutePathFor(path)).exists(), isFalse);
  });
}
