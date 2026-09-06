import 'package:drift/drift.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';

/// Refcounted cleanup of the stored import copies (issue #478).
///
/// `imported/` has no orphan sweep, and one import run points every dive it
/// created at one content-addressed copy, so a copy may only be deleted once
/// no surviving `dive_data_sources` row still names it. Every path that
/// destroys such a row -- a dive deletion, a replaceSource re-download --
/// asks here rather than reasoning about the refcount itself.
class ImportedFileCleanup {
  ImportedFileCleanup({
    AppDatabase Function()? database,
    ImportedFileStore? store,
  }) : _database = database ?? _defaultDatabase,
       _store = store ?? ImportedFileStore();

  final AppDatabase Function() _database;
  final ImportedFileStore _store;

  static AppDatabase _defaultDatabase() => DatabaseService.instance.database;

  /// The stored copies that deleting every source row of [diveIds] orphans.
  Future<Set<String>> doomedForDives(List<String> diveIds) async {
    if (diveIds.isEmpty) return const {};
    final db = _database();
    final doomed =
        await (db.select(db.diveDataSources)..where(
              (t) => t.diveId.isIn(diveIds) & t.importedFilePath.isNotNull(),
            ))
            .get();
    return _doomedAmong(doomed);
  }

  /// The stored copies that deleting every dive of [diverId] orphans.
  ///
  /// Scoped by a join rather than by the diver's dive ids so a logbook of
  /// thousands of dives does not bind one SQL variable per dive.
  Future<Set<String>> doomedForDiver(String diverId) async {
    final db = _database();
    final rows =
        await (db.select(db.diveDataSources).join([
              innerJoin(
                db.dives,
                db.dives.id.equalsExp(db.diveDataSources.diveId),
              ),
            ])..where(
              db.dives.diverId.equals(diverId) &
                  db.diveDataSources.importedFilePath.isNotNull(),
            ))
            .get();
    return _doomedAmong([
      for (final row in rows) row.readTable(db.diveDataSources),
    ]);
  }

  /// The stored copies that deleting the source rows [sourceIds] orphans.
  Future<Set<String>> doomedForSources(List<String> sourceIds) async {
    if (sourceIds.isEmpty) return const {};
    final db = _database();
    final doomed =
        await (db.select(db.diveDataSources)..where(
              (t) => t.id.isIn(sourceIds) & t.importedFilePath.isNotNull(),
            ))
            .get();
    return _doomedAmong(doomed);
  }

  /// Groups the doomed rows by the copy they actually name -- one copy can be
  /// spelled two ways in the column, documents-relative since the path fix
  /// and absolute in the rows earlier builds wrote -- and keeps a copy whose
  /// spelling any surviving row still uses.
  Future<Set<String>> _doomedAmong(List<DiveDataSourcesData> doomedRows) async {
    if (doomedRows.isEmpty) return const {};
    final db = _database();
    final doomedIds = [for (final row in doomedRows) row.id];
    final spellings = <String, Set<String>>{};
    for (final path in {for (final row in doomedRows) row.importedFilePath!}) {
      (spellings[await _store.absolutePathFor(path)] ??= <String>{}).addAll(
        await _store.spellingsOf(path),
      );
    }
    final doomed = <String>{};
    for (final entry in spellings.entries) {
      final survivors =
          await (db.select(db.diveDataSources)..where(
                (t) =>
                    t.importedFilePath.isIn(entry.value.toList()) &
                    t.id.isIn(doomedIds).not(),
              ))
              .get();
      if (survivors.isEmpty) doomed.add(entry.key);
    }
    return doomed;
  }

  /// Deletes the bytes [doomedForDives]/[doomedForSources] found, once the
  /// rows that named them are gone. A failure in between leaves an
  /// unreferenced file -- the failure mode that existed before this cleanup
  /// did -- rather than a surviving row pointing at bytes that are not there.
  Future<void> deleteAll(Iterable<String> paths) async {
    for (final path in paths) {
      await _store.delete(path);
    }
  }
}
