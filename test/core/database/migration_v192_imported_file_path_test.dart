import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';

void main() {
  NativeDatabase setupDb() {
    return NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA user_version = 191');
        rawDb.execute('CREATE TABLE dives (id TEXT PRIMARY KEY)');
        rawDb.execute('''
          CREATE TABLE dive_data_sources (
            id TEXT NOT NULL PRIMARY KEY,
            dive_id TEXT NOT NULL,
            is_primary INTEGER NOT NULL DEFAULT 0,
            imported_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            source_file_name TEXT,
            source_file_format TEXT
          )
        ''');
      },
    );
  }

  test('v192 is the current schema version and is in the ladder', () {
    expect(AppDatabase.currentSchemaVersion, 192);
    expect(AppDatabase.migrationVersions, contains(192));
  });

  test('adds imported_file_path to dive_data_sources', () async {
    final db = AppDatabase(setupDb());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_data_sources')")
        .get();
    expect(
      cols.map((c) => c.read<String>('name')),
      contains('imported_file_path'),
    );
  });

  test('pre-existing rows read the new column back as null', () async {
    final db = AppDatabase(setupDb());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO dives (id) VALUES ('d1')");
    await db.customStatement(
      "INSERT INTO dive_data_sources "
      "(id, dive_id, is_primary, imported_at, created_at, source_file_name, source_file_format) "
      "VALUES ('s1', 'd1', 1, 0, 0, 'dive.uddf', 'uddf')",
    );
    final row = await db
        .customSelect(
          "SELECT imported_file_path FROM dive_data_sources WHERE id = 's1'",
        )
        .getSingle();
    expect(row.readNullable<String>('imported_file_path'), isNull);
  });
}
