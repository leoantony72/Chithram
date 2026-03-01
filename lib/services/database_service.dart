import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  static Database? _database;

  DatabaseService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = 'chithram_faces.db';
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    } else if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dbPath = await getDatabasesPath();
      path = join(dbPath, 'chithram_faces.db');
    } else {
      final dbPath = await getDatabasesPath();
      path = join(dbPath, 'chithram_faces.db');
    }

    return await openDatabase(
      path,

      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE faces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            image_path TEXT NOT NULL,
            bbox TEXT NOT NULL,
            landmarks TEXT,
            embedding BLOB,
            thumbnail BLOB,
            cluster_id INTEGER,
            fl_trained INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE clusters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            representative_face_id INTEGER,
            embedding BLOB, -- Centroid embedding
            thumbnail BLOB, -- Cached representative thumbnail
            FOREIGN KEY (representative_face_id) REFERENCES faces (id)
          )
        ''');

        await db.execute('''
          CREATE TABLE processed_images (
            image_path TEXT PRIMARY KEY
          )
        ''');

        await db.execute('''
          CREATE TABLE backup_settings (key TEXT PRIMARY KEY, value TEXT)
        ''');

        await db.execute('''
          CREATE TABLE backup_log (file_path TEXT PRIMARY KEY, status TEXT, timestamp INTEGER)
        ''');

        await db.execute('''
          CREATE TABLE journey_covers (
            city TEXT PRIMARY KEY,
            image_id TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE journey_cache (
            id TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE local_gallery_index (
            id TEXT PRIMARY KEY,
            title TEXT,
            type_int INTEGER,
            width INTEGER,
            height INTEGER,
            create_dt INTEGER,
            modify_dt INTEGER,
            relative_path TEXT,
            is_favorite INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE semantic_embeddings (
            id TEXT PRIMARY KEY,
            embedding BLOB
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
         if (oldVersion < 4) {
            try {
              await db.execute('ALTER TABLE faces ADD COLUMN landmarks TEXT');
            } catch (_) {}
            try {
              await db.execute('ALTER TABLE clusters ADD COLUMN embedding BLOB');
            } catch (_) {}
         }
         if (oldVersion < 5) {
            try {
               await db.execute('CREATE TABLE processed_images (image_path TEXT PRIMARY KEY)');
            } catch (_) {}
         }
         if (oldVersion < 6) {
            try {
               await db.execute('CREATE TABLE backup_settings (key TEXT PRIMARY KEY, value TEXT)');
               await db.execute('CREATE TABLE backup_log (file_path TEXT PRIMARY KEY, status TEXT, timestamp INTEGER)');
            } catch (_) {}
         }
          if (oldVersion < 7) {
            try {
               await db.execute('ALTER TABLE clusters ADD COLUMN thumbnail BLOB');
            } catch (_) {}
          }
          if (oldVersion < 8) {
            try {
               await db.execute('ALTER TABLE faces ADD COLUMN fl_trained INTEGER DEFAULT 0');
            } catch (_) {}
          }
          if (oldVersion < 9) {
            try {
               await db.execute('''
                 CREATE TABLE IF NOT EXISTS journey_covers (
                   city TEXT PRIMARY KEY,
                   image_id TEXT NOT NULL
                 )
               ''');
            } catch (_) {}
          }
          if (oldVersion < 10) {
            try {
               await db.execute('''
                 CREATE TABLE IF NOT EXISTS journey_cache (
                   id TEXT PRIMARY KEY,
                   data TEXT NOT NULL,
                   timestamp INTEGER NOT NULL
                 )
               ''');
            } catch (_) {}
          }
          if (oldVersion < 11) {
            try {
               await db.execute('''
                 CREATE TABLE IF NOT EXISTS local_gallery_index (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    type_int INTEGER,
                    width INTEGER,
                    height INTEGER,
                    create_dt INTEGER,
                    modify_dt INTEGER,
                    relative_path TEXT
                 )
               ''');
            } catch (_) {}
          }
          if (oldVersion < 13) {
            try {
               await db.execute('''
                 CREATE TABLE IF NOT EXISTS semantic_embeddings (
                   id TEXT PRIMARY KEY,
                   embedding BLOB
                 )
               ''');
            } catch (_) {}
          }
      },
      version: 13,
    );
  }

  // --- Local Gallery Index ---
  Future<void> saveGalleryIndex(List<Map<String, dynamic>> items) async {
    final db = await database;
    Batch batch = db.batch();
    for (var item in items) {
       batch.insert('local_gallery_index', item, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateFavoriteStatus(String id, bool isFavorite) async {
    final db = await database;
    await db.update(
      'local_gallery_index',
      {'is_favorite': isFavorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearGalleryIndex() async {
    final db = await database;
    await db.delete('local_gallery_index');
  }

  Future<Set<String>> getFavoritesIds() async {
    final db = await database;
    final res = await db.query('local_gallery_index', columns: ['id'], where: 'is_favorite = 1');
    return res.map((e) => e['id'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> getGalleryIndex({int limit = 500, int offset = 0}) async {
    final db = await database;
    return await db.query(
       'local_gallery_index', 
       orderBy: 'create_dt DESC', // Newest first
       limit: limit, 
       offset: offset
    );
  }

  Future<int> getGalleryIndexCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM local_gallery_index');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // --- Backup Operations ---

  Future<void> setBackupSetting(String key, String value) async {
    final db = await database;
    await db.insert('backup_settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getBackupSetting(String key) async {
    final db = await database;
    final res = await db.query('backup_settings', where: 'key = ?', whereArgs: [key]);
    if (res.isNotEmpty) return res.first['value'] as String;
    return null;
  }

  Future<void> logBackupStatus(String path, String status) async {
    final db = await database;
    await db.insert(
      'backup_log', 
      {'file_path': path, 'status': status, 'timestamp': DateTime.now().millisecondsSinceEpoch}, 
      conflictAlgorithm: ConflictAlgorithm.replace
    );
  }

  Future<bool> isBackedUp(String path) async {
    final db = await database;
    final res = await db.query('backup_log', where: 'file_path = ? AND status = ?', whereArgs: [path, 'UPLOADED']);
    return res.isNotEmpty;
  }

  // --- Journey Covers ---
  Future<void> setJourneyCover(String city, String imageId) async {
    final db = await database;
    await db.insert('journey_covers', {'city': city, 'image_id': imageId}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getJourneyCover(String city) async {
    final db = await database;
    final res = await db.query('journey_covers', where: 'city = ?', whereArgs: [city]);
    if (res.isNotEmpty) return res.first['image_id'] as String;
    return null;
  }

  // --- Journey Cache ---
  Future<void> saveJourneyCache(String jsonData) async {
    final db = await database;
    await db.insert('journey_cache', {
      'id': 'main',
      'data': jsonData,
      'timestamp': DateTime.now().millisecondsSinceEpoch
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getJourneyCache() async {
    final db = await database;
    final res = await db.query('journey_cache', where: 'id = ?', whereArgs: ['main']);
    if (res.isNotEmpty) {
      final timestamp = res.first['timestamp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      // 1 day validity threshold (24 * 60 * 60 * 1000 = 86400000)
      if (now - timestamp < 86400000) {
        return {'data': res.first['data'], 'timestamp': timestamp};
      } else {
        // Invalidate by wiping it out
        await db.delete('journey_cache', where: 'id = ?', whereArgs: ['main']);
      }
    }
    return null;
  }

  Future<void> invalidateJourneyCache() async {
    final db = await database;
    await db.delete('journey_cache', where: 'id = ?', whereArgs: ['main']);
  }

  // --- Face Operations ---

  Future<void> markImageAsProcessed(String imagePath) async {
    final db = await database;
    try {
      await db.insert(
        'processed_images', 
        {'image_path': imagePath},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
  }

  Future<bool> isImageProcessed(String imagePath) async {
    final db = await database;
    
    // Check processed_images table
    final processed = await db.query(
      'processed_images',
      where: 'image_path = ?',
      whereArgs: [imagePath],
      limit: 1,
    );
    if (processed.isNotEmpty) return true;

    // Check faces table (legacy check)
    final result = await db.query(
      'faces',
      columns: ['id'],
      where: 'image_path = ?',
      whereArgs: [imagePath],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<int> insertFace(String imagePath, String bbox, String? landmarks, Uint8List? embedding, Uint8List? thumbnail) async {
    final db = await database;
    return await db.insert('faces', {
      'image_path': imagePath,
      'bbox': bbox,
      'landmarks': landmarks,
      'embedding': embedding,
      'thumbnail': thumbnail,
    });
  }
  
  Future<void> updateFaceData(int faceId, Uint8List embedding, Uint8List thumbnail) async {
    final db = await database;
    await db.update(
      'faces',
      {
        'embedding': embedding,
        'thumbnail': thumbnail
      },
      where: 'id = ?',
      whereArgs: [faceId],
    );
  }

  Future<List<Map<String, dynamic>>> getFacesWithoutEmbedding() async {
    final db = await database;
    return await db.query(
      'faces',
      where: 'embedding IS NULL',
    );
  }

  Future<List<Map<String, dynamic>>> getAllFaces() async {
    final db = await database;
    return await db.query('faces');
  }

  Future<List<Map<String, dynamic>>> getUntrainedFaces({int limit = 40}) async {
    final db = await database;
    return await db.query(
      'faces',
      where: 'fl_trained = 0',
      limit: limit,
      orderBy: 'id ASC',
    );
  }

  Future<int> getTotalUntrainedCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM faces WHERE fl_trained = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> updateFaceCluster(int faceId, int clusterId) async {
    final db = await database;
    await db.update(
      'faces',
      {'cluster_id': clusterId},
      where: 'id = ?',
      whereArgs: [faceId],
    );
  }

  // --- Cluster Operations ---

  Future<int> createCluster({String? name, int? representativeFaceId, Uint8List? embedding}) async {
    final db = await database;
    return await db.insert('clusters', {
      'name': name,
      'representative_face_id': representativeFaceId,
      'embedding': embedding,
    });
  }

  Future<void> updateClusterName(int clusterId, String newName) async {
    final db = await database;
    await db.update(
      'clusters',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [clusterId],
    );
  }

  Future<List<String>> getPhotoPathsForCluster(int clusterId) async {
    final db = await database;
    final result = await db.query(
      'faces',
      distinct: true,
      columns: ['image_path'],
      where: 'cluster_id = ?',
      whereArgs: [clusterId],
    );
    return result.map((row) => row['image_path'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> getAllClusters() async {
    final db = await database;
    return await db.query('clusters');
  }

  Future<void> updateClusterEmbedding(int clusterId, Uint8List embedding) async {
    final db = await database;
    await db.update(
      'clusters',
      {'embedding': embedding},
      where: 'id = ?',
      whereArgs: [clusterId],
    );
  }

  /// Initial implementation to fetch cluster + representative face details
  Future<List<Map<String, dynamic>>> getAllClustersWithThumbnail() async {
    final db = await database;
    // Return cluster data, prioritizing its own thumbnail column, falling back to joined face thumbnail
    return await db.rawQuery('''
      SELECT 
        c.id, 
        c.name, 
        COALESCE(f.thumbnail, c.thumbnail) as thumbnail,
        c.representative_face_id
      FROM clusters c
      LEFT JOIN faces f ON c.representative_face_id = f.id
    ''');
  }

  Future<void> updateClusterRepresentative(int clusterId, int faceId) async {
    final db = await database;
    await db.update(
      'clusters',
      {'representative_face_id': faceId},
      where: 'id = ?',
      whereArgs: [clusterId],
    );
  }
  
  // Get all faces belonging to a cluster
  Future<List<Map<String, dynamic>>> getFacesInCluster(int clusterId) async {
    final db = await database;
    return await db.query(
      'faces',
      where: 'cluster_id = ?',
      whereArgs: [clusterId],
    );
  }

  // --- Semantic Search Operations ---

  Future<void> saveSemanticEmbedding(String id, List<double> embedding) async {
    final db = await database;
    final Float32List floatList = Float32List.fromList(embedding);
    await db.insert(
      'semantic_embeddings',
      {
        'id': id,
        'embedding': floatList.buffer.asUint8List(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> isSemanticIndexed(String id) async {
    final db = await database;
    final res = await db.query('semantic_embeddings', columns: ['id'], where: 'id = ?', whereArgs: [id]);
    return res.isNotEmpty;
  }
  
  Future<int> getSemanticIndexedCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM semantic_embeddings');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Set<String>> getAllSemanticIndexedIds() async {
    final db = await database;
    final res = await db.query('semantic_embeddings', columns: ['id']);
    return res.map((e) => e['id'] as String).toSet();
  }

  Future<void> clearSemanticEmbeddings() async {
    final db = await database;
    await db.delete('semantic_embeddings');
  }

  Future<List<Map<String, dynamic>>> searchSemantic(List<double> queryEmbedding, {int limit = 50, double minScore = 0.0}) async {
    final db = await database;
    final allEmbeddings = await db.query('semantic_embeddings');
    
    if (allEmbeddings.isEmpty) return [];

    // Pre-compute query L2 norm once
    double queryNorm = 0;
    for (final v in queryEmbedding) queryNorm += v * v;
    queryNorm = queryNorm > 0 ? sqrt(queryNorm) : 0;
    if (queryNorm == 0) return []; // zero query vector can't be compared
    
    final List<Map<String, dynamic>> results = [];
    
    for (var row in allEmbeddings) {
      final id = row['id'] as String;
      final rawBytes = row['embedding'] as Uint8List;
      // Android sqflite returns BLOBs at non-4-byte-aligned offsets (e.g. offset 79).
      // Both asFloat32List() and sublistView() require 4-byte alignment and throw RangeError.
      // Uint8List.fromList() copies into a fresh buffer at offsetInBytes==0, making it safe.
      final embedding = Uint8List.fromList(rawBytes).buffer.asFloat32List();
      
      final int len = queryEmbedding.length < embedding.length
          ? queryEmbedding.length
          : embedding.length;
      if (len == 0) continue;

      // Dot product
      double dot = 0;
      for (int i = 0; i < len; i++) {
        dot += queryEmbedding[i] * embedding[i];
      }

      // L2 norm of stored embedding
      double embNorm = 0;
      for (int i = 0; i < embedding.length; i++) embNorm += embedding[i] * embedding[i];
      embNorm = embNorm > 0 ? sqrt(embNorm) : 0;
      if (embNorm == 0) continue; // skip zero/corrupted embeddings

      // Cosine similarity in [-1, 1]
      final double cosine = dot / (queryNorm * embNorm);
      
      if (cosine >= minScore) {
        results.add({'id': id, 'score': cosine});
      }
    }

    results.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    return results.take(limit).toList();
  }
}
