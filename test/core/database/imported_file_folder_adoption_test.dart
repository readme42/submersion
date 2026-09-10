import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/database/imported_file_folder_adoption.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

/// Before the maintainers settled on the database (issue #478), the stored
/// logbook files lived in `<documents>/Submersion/imported/` with
/// `dive_data_sources.imported_file_path` naming them. Only this unmerged
/// branch ever wrote that, but the device it was tested on has both, and
/// without an adoption pass every dive there silently loses its Resync action
/// and the folder becomes garbage no sweep can reach.
void main() {
  late Directory docs;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('imported_file_adoption');
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  /// A database shaped like the branch's own v208: the new table and column
  /// are there, and so is the legacy path column.
  AppDatabase openLegacyDatabase() {
    return AppDatabase(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA user_version = 208');
          rawDb.execute('CREATE TABLE dives (id TEXT PRIMARY KEY)');
          rawDb.execute('''
            CREATE TABLE dive_data_sources (
              id TEXT NOT NULL PRIMARY KEY,
              dive_id TEXT NOT NULL,
              is_primary INTEGER NOT NULL DEFAULT 0,
              imported_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              source_file_name TEXT,
              source_file_format TEXT,
              imported_file_path TEXT
            )
          ''');
        },
      ),
    );
  }

  Future<void> seedSource(
    AppDatabase db,
    String id,
    String storedPath, {
    String diveId = 'd1',
  }) async {
    await db.customStatement('INSERT OR IGNORE INTO dives (id) VALUES (?)', [
      diveId,
    ]);
    await db.customStatement(
      'INSERT INTO dive_data_sources '
      '(id, dive_id, is_primary, imported_at, created_at, '
      'source_file_format, imported_file_path) '
      "VALUES (?, ?, 1, 0, 0, 'uddf', ?)",
      [id, diveId, storedPath],
    );
  }

  Future<String> writeStoredFile(Uint8List bytes) async {
    final name = '${sha256.convert(bytes)}.uddf';
    final file = File(p.join(docs.path, 'Submersion', 'imported', name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return p.url.join('imported', name);
  }

  Future<List<String?>> pathsIn(AppDatabase db) async {
    final rows = await db
        .customSelect(
          'SELECT imported_file_path AS path FROM dive_data_sources',
        )
        .get();
    return [for (final row in rows) row.readNullable<String>('path')];
  }

  Future<String?> fileIdOf(AppDatabase db, String sourceId) async {
    final row = await db
        .customSelect(
          'SELECT imported_file_id AS id FROM dive_data_sources WHERE id = ?',
          variables: [Variable.withString(sourceId)],
        )
        .getSingle();
    return row.readNullable<String>('id');
  }

  test('moves a stored file into the table and repoints its row', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final storedPath = await writeStoredFile(bytes);
    await seedSource(db, 's1', storedPath);

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    final fileId = await fileIdOf(db, 's1');
    expect(fileId, sha256.convert(bytes).toString());
    final row = await (db.select(
      db.importedFiles,
    )..where((t) => t.id.equals(fileId!))).getSingle();
    expect(row.bytes, bytes);
    expect(row.fileName, endsWith('.uddf'));
    expect(row.byteCount, bytes.length);
  });

  test('leaves the folder empty and gone', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    final storedPath = await writeStoredFile(Uint8List.fromList([1, 2, 3]));
    await seedSource(db, 's1', storedPath);

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(
      await Directory(p.join(docs.path, 'Submersion', 'imported')).exists(),
      isFalse,
    );
  });

  test('one file shared by several dives becomes one row', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    final storedPath = await writeStoredFile(Uint8List.fromList([5, 6, 7]));
    await seedSource(db, 's1', storedPath, diveId: 'd1');
    await seedSource(db, 's2', storedPath, diveId: 'd2');

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(await db.select(db.importedFiles).get(), hasLength(1));
    expect(await fileIdOf(db, 's1'), await fileIdOf(db, 's2'));
  });

  test('adopts a row that still names its file by an absolute path', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    final bytes = Uint8List.fromList([8, 9]);
    final storedPath = await writeStoredFile(bytes);
    final absolute = p.join(docs.path, 'Submersion', storedPath);
    await seedSource(db, 's1', absolute);

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(await fileIdOf(db, 's1'), sha256.convert(bytes).toString());
  });

  test('gives up on a path whose file is gone, and says so by clearing '
      'it', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    await seedSource(db, 's1', 'imported/never-written.uddf');

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(await fileIdOf(db, 's1'), isNull);
    expect(await pathsIn(db), [isNull]);
    expect(await db.select(db.importedFiles).get(), isEmpty);
  });

  test('a second pass finds nothing left to do', () async {
    final db = openLegacyDatabase();
    addTearDown(db.close);
    final storedPath = await writeStoredFile(Uint8List.fromList([1, 2, 3]));
    await seedSource(db, 's1', storedPath);

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);
    final first = await fileIdOf(db, 's1');
    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(await fileIdOf(db, 's1'), first);
    expect(await db.select(db.importedFiles).get(), hasLength(1));
    expect(await pathsIn(db), [isNull]);
  });

  test(
    'the beforeOpen backstop runs it on a database already at 208',
    () async {
      // The device this exists for is already stamped v208, so the rung never
      // fires there. Seeded in the raw setup so the row is there before the
      // first open.
      final bytes = Uint8List.fromList([3, 1, 4, 1, 5]);
      final storedPath = await writeStoredFile(bytes);
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(docs.path);
      addTearDown(() => PathProviderPlatform.instance = previous);

      final db = AppDatabase(
        NativeDatabase.memory(
          setup: (rawDb) {
            rawDb.execute('PRAGMA user_version = 208');
            rawDb.execute('CREATE TABLE dives (id TEXT PRIMARY KEY)');
            rawDb.execute('''
            CREATE TABLE dive_data_sources (
              id TEXT NOT NULL PRIMARY KEY,
              dive_id TEXT NOT NULL,
              is_primary INTEGER NOT NULL DEFAULT 0,
              imported_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              source_file_format TEXT,
              imported_file_path TEXT
            )
          ''');
            rawDb.execute("INSERT INTO dives (id) VALUES ('d1')");
            rawDb.execute(
              "INSERT INTO dive_data_sources VALUES "
              "('s1', 'd1', 1, 0, 0, 'uddf', '$storedPath')",
            );
          },
        ),
      );
      addTearDown(db.close);

      expect(await fileIdOf(db, 's1'), sha256.convert(bytes).toString());
    },
  );

  test('a database that never had the legacy column is untouched', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

    expect(await db.select(db.importedFiles).get(), isEmpty);
  });

  test(
    'the adopted row carries no hlc, for the sync backfill to stamp',
    () async {
      // Written during a migration, where no clock and no sync bookkeeping are
      // available. SyncRepository's hlc backfill stamps it at the start of the
      // next sync, which is what gets the bytes to the diver's other devices.
      final db = openLegacyDatabase();
      addTearDown(db.close);
      final storedPath = await writeStoredFile(Uint8List.fromList([1, 2, 3]));
      await seedSource(db, 's1', storedPath);

      await adoptImportedFileFolder(db, documentsDirectory: () async => docs);

      expect((await db.select(db.importedFiles).getSingle()).hlc, isNull);
    },
  );
}
