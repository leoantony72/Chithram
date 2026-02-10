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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE faces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            image_path TEXT NOT NULL,
            bbox TEXT NOT NULL,
            embedding BLOB NOT NULL,
            cluster_id INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE clusters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            representative_face_id INTEGER,
            FOREIGN KEY (representative_face_id) REFERENCES faces (id)
          )
        ''');
      },
    );
  }

  // --- Face Operations ---

  Future<int> insertFace(String imagePath, String bbox, Uint8List embedding) async {
    final db = await database;
    return await db.insert('faces', {
      'image_path': imagePath,
      'bbox': bbox,
      'embedding': embedding,
    });
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

  Future<int> createCluster({String? name, int? representativeFaceId}) async {
    final db = await database;
    return await db.insert('clusters', {
      'name': name,
      'representative_face_id': representativeFaceId,
    });
  }

  Future<List<Map<String, dynamic>>> getAllClusters() async {
    final db = await database;
    return await db.query('clusters');
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
