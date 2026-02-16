import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

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
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'chithram_faces.db');

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
            cluster_id INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE clusters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            representative_face_id INTEGER,
            embedding BLOB, -- Centroid embedding
            FOREIGN KEY (representative_face_id) REFERENCES faces (id)
          )
        ''');

        await db.execute('''
          CREATE TABLE processed_images (
            image_path TEXT PRIMARY KEY
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
      },
      version: 5, 
    );
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
    // Join clusters with faces to get thumbnail info
    return await db.rawQuery('''
      SELECT 
        c.id, 
        c.name, 
        f.thumbnail
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
}
