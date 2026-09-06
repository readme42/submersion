import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/core/database/database.dart' as db;
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/dive_import/presentation/providers/dive_resync_providers.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    await setUpTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('dive_resync_providers');
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seedDiveWithSource(String path) async {
    final database = DatabaseService.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await database
        .into(database.divers)
        .insert(
          db.DiversCompanion(
            id: const Value('x'),
            name: const Value('Test Diver'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    await database
        .into(database.dives)
        .insert(
          db.DivesCompanion(
            id: const Value('d1'),
            diverId: const Value('x'),
            diveDateTime: Value(now),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await database
        .into(database.diveDataSources)
        .insert(
          db.DiveDataSourcesCompanion(
            id: const Value('s1'),
            diveId: const Value('d1'),
            isPrimary: const Value(true),
            importedAt: Value(DateTime.now()),
            createdAt: Value(DateTime.now()),
            importedFilePath: Value(path),
          ),
        );
  }

  test(
    'diveHasImportedFileProvider is true for a file still on disk',
    () async {
      final path = p.join(tempDir.path, 'logbook.uddf');
      await File(path).writeAsBytes([1, 2, 3]);
      await seedDiveWithSource(path);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container.read(diveHasImportedFileProvider('d1').future),
        isTrue,
      );
      expect(
        await container.read(diveHasImportedFileProvider('nope').future),
        isFalse,
      );
    },
  );

  test('a documents-relative path resolves against the current documents '
      'directory', () async {
    // The whole point of storing the path relative: an iOS reinstall or a
    // restore moves the app container, and the action has to survive it.
    final store = ImportedFileStore(documentsDirectory: () async => tempDir);
    final stored = await store.store(
      bytes: Uint8List.fromList([1, 2, 3]),
      originalFileName: 'logbook.uddf',
    );
    expect(p.isRelative(stored), isTrue);
    await seedDiveWithSource(stored);

    final container = ProviderContainer(
      overrides: [importedFileStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(
      await container.read(diveHasImportedFileProvider('d1').future),
      isTrue,
    );
  });

  test('a synced path that does not resolve on this device is false', () async {
    // `imported_file_path` is exported verbatim by sync, so a peer (or this
    // device after an iOS reinstall moves the container) holds a path whose
    // file never existed here. Offering resync there only ever fails.
    await seedDiveWithSource(p.join(tempDir.path, 'never-written.uddf'));

    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(diveHasImportedFileProvider('d1').future),
      isFalse,
    );
  });
}
