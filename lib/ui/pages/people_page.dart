import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/model_service.dart';
import '../../services/database_service.dart';
import '../../services/face_service.dart';
import '../../services/cluster_service.dart';

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  final ModelService _modelService = ModelService();
  final DatabaseService _dbService = DatabaseService();
  final FaceService _faceService = FaceService();
  final ClusterService _clusterService = ClusterService();

  List<Map<String, dynamic>> _clusters = [];
  bool _isScanning = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _loadClusters();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    final success = await _modelService.ensureModelsDownloaded();
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to connect to backend. Is it running?'),
          duration: Duration(seconds: 5),
          backgroundColor: Colors.red,
        ),
      );
    }
    await _faceService.initialize();
  }

  Future<void> _loadClusters() async {
    final clusters = await _dbService.getAllClustersWithThumbnail();
    setState(() {
      _clusters = clusters;
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _statusMessage = 'Initializing...';
    });

    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      setState(() => _isScanning = false);
      return;
    }

    final modelsReady = await _modelService.ensureModelsDownloaded();
    if (!modelsReady) {
      if (mounted) {
        setState(() => _isScanning = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Model Error')));
      }
      return;
    }

    await _faceService.initialize();

    // Pipeline Execution
    await _scanDetectionPhase();
    await _scanEmbeddingPhase();
    if (_statusMessage != 'Scan Complete') {
       await _scanClusteringPhase();
    }
    
    setState(() {
      _isScanning = false;
      _statusMessage = 'Scan Complete';
    });
    _loadClusters();
  }

  Future<void> _scanClusteringPhase() async {
    setState(() => _statusMessage = 'Phase 3: Clustering Faces...');
    await _clusterService.runClustering();
  }
  
  // Phase 1: Detect faces from new images and store BBoxes
  Future<void> _scanDetectionPhase() async {
    setState(() => _statusMessage = 'Phase 1: Detecting Faces...');
    
    // Fetch recent photos
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(type: RequestType.image);
    if (paths.isEmpty) return;
    
    final recentAlbum = paths[0]; 
    final int totalAssets = await recentAlbum.assetCountAsync;
    
    // Process in pages of 50
    const int pageSize = 50; 
    int totalPages = (totalAssets / pageSize).ceil();
    int processedCount = 0;

    for (int page = 0; page < totalPages; page++) {
        if (!mounted || !_isScanning) break;

        final List<AssetEntity> entities = await recentAlbum.getAssetListPaged(page: page, size: pageSize);
        
        // Process this page in smaller concurrent batches (e.g., 5 at a time)
        // ML Kit might handle 5 concurrent requests okay. 
        // Too many might cause memory pressure or native thread contention.
        const int concurrentBatchSize = 5;
        
        for (var i = 0; i < entities.length; i += concurrentBatchSize) {
            if (!mounted || !_isScanning) break;

            final int end = min(i + concurrentBatchSize, entities.length);
            final batch = entities.sublist(i, end);
            
            await Future.wait(batch.map((entity) => _processDetectionForEntity(entity)));
            
            processedCount += batch.length;
            setState(() => _statusMessage = 'Detecting: $processedCount/$totalAssets');
        }
    }
  }

  Future<void> _processDetectionForEntity(AssetEntity entity) async {
      final file = await entity.file;
      if (file == null) return;

      if (await _dbService.isImageProcessed(file.path)) return;

      try {
        final faces = await _faceService.detectFaces(file);
        for (final face in faces) {
            String? landmarksStr;
            final le = face.landmarks[FaceLandmarkType.leftEye];
            final re = face.landmarks[FaceLandmarkType.rightEye];
            if (le != null && re != null) {
              landmarksStr = '${le.position.x},${le.position.y};${re.position.x},${re.position.y}';
            }

            await _dbService.insertFace(
              file.path, 
              face.boundingBox.toString(),
              landmarksStr,
              null,
              null
            );
        }
        await _dbService.markImageAsProcessed(file.path);
      } catch (e) {
        print('Error detecting ${file.path}: $e');
      }
  }

  // Phase 2: Generate Embeddings for stored faces
  Future<void> _scanEmbeddingPhase() async {
    final faces = await _dbService.getFacesWithoutEmbedding();
    if (faces.isEmpty) return;

    for (var i = 0; i < faces.length; i++) {
       final face = faces[i];
       setState(() => _statusMessage = 'Embedding: ${i+1}/${faces.length}');
       
       final int faceId = face['id'];
       final String path = face['image_path'];
       final String bboxStr = face['bbox'];
       final String? landmarksStr = face['landmarks'];
       
       final regex = RegExp(r'Rect.fromLTRB\(([^,]+), ([^,]+), ([^,]+), ([^)]+)\)');
       final match = regex.firstMatch(bboxStr);
       if (match == null) continue;

       final rect = Rect.fromLTRB(
          double.parse(match.group(1)!),
          double.parse(match.group(2)!),
          double.parse(match.group(3)!),
          double.parse(match.group(4)!),
       );

       Point<int>? leftEye;
       Point<int>? rightEye;
       if (landmarksStr != null) {
          try {
             final parts = landmarksStr.split(';');
             if (parts.length == 2) {
                final leParts = parts[0].split(',');
                final reParts = parts[1].split(',');
                leftEye = Point(int.parse(leParts[0]), int.parse(leParts[1]));
                rightEye = Point(int.parse(reParts[0]), int.parse(reParts[1]));
             }
          } catch (_) {}
       }

       try {
         final data = await _faceService.getEmbeddingFromData(File(path), rect, leftEye: leftEye, rightEye: rightEye);
         
         if (data != null) {
            final embeddingBytes = Float32List.fromList(data.embedding).buffer.asUint8List();
            
            await _dbService.updateFaceData(faceId, embeddingBytes, data.thumbnail);
         }
       } catch (e) {
         print('Error embedding face $faceId: $e');
       }
    }
  }
  @override
  void dispose() {
    _faceService.dispose();
    super.dispose();
  }

  Future<void> _exportFaceData() async {
    // 1. Get Faces
    final faces = await _dbService.getAllFaces();
    
    // 2. Prepare Data
    final List<Map<String, dynamic>> exportList = [];
    for (var f in faces) {
       final blob = f['embedding'] as Uint8List?;
       if (blob != null) {
          // Fix alignment issues (offset 237 etc)
          var buffer = blob.buffer;
          var offset = blob.offsetInBytes;
          if (offset % 4 != 0) {
              final copy = Uint8List.fromList(blob);
              buffer = copy.buffer;
              offset = 0;
          }
          final vec = Float32List.view(buffer, offset, blob.lengthInBytes ~/ 4).toList();
          
          exportList.add({
             'id': f['id'],
             'cluster_id': f['cluster_id'],
             'path': f['image_path'],
             'embedding': vec,
          });
       }
    }

    // 3. Write File
    try {
      // Android Downloads folder or similar
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      
      final file = File('${dir.path}/face_vectors_dump.json');
      // Simple manual JSON stringify to avoid importing dart:convert if not present (thought it usually is)
      // Actually, let's just use dart:convert.
      // Wait, need to check imports. 
      // I'll do a simple string build for safety if imports are tight, but dart:convert is standard.
      // Assuming import 'dart:convert'; is needed. I'll add the import in a separate step or just use a raw string builder.
      // Let's use a manual builder for the list to be safe without adding imports at top of file right now.
      
      final buffer = StringBuffer();
      buffer.write('[');
      for (int i = 0; i < exportList.length; i++) {
         final item = exportList[i];
         buffer.write('{"id":${item['id']},"cluster_id":${item['cluster_id']},"path":"${item['path']}","vector":[');
         final vec = item['embedding'] as List<double>;
         buffer.write(vec.join(','));
         buffer.write(']}');
         if (i < exportList.length - 1) buffer.write(',');
      }
      buffer.write(']');
      
      await file.writeAsString(buffer.toString());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported to ${file.path}')));
        print('Exported to ${file.path}');
      }
    } catch (e) {
      print('Export error: $e');
    }
  }

  Future<void> _resetDatabase() async {
    try {
      final db = await _dbService.database;
      await db.delete('faces');
      await db.delete('clusters');
      await db.delete('processed_images');
      
      setState(() {
        _clusters = [];
        _statusMessage = 'Database Cleared';
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Database Reset. Please Scan Again.')),
        );
      }
    } catch (e) {
      print('Reset Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                 if (v == 'export') _exportFaceData();
                 if (v == 'clear_db') _resetDatabase();
              },
              itemBuilder: (context) => [
                 const PopupMenuItem(value: 'export', child: Text('Export Vectors JSON')),
                 const PopupMenuItem(value: 'clear_db', child: Text('Reset People Database')),
              ],
            ),
          if (_isScanning)
// ... existing code ...
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(_statusMessage, style: const TextStyle(fontSize: 12)),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: _startScan,
            ),
        ],
      ),
      body: _clusters.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.people_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No people found yet.', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _startScan,
                    child: const Text('Scan Photos'),
                  ),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 24,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
              ),
              itemCount: _clusters.length,
              itemBuilder: (context, index) {
                final cluster = _clusters[index];
                return GestureDetector(
                  onTap: () {
                    context.push(
                      '/person_details',
                      extra: {
                        'name': cluster['name'] ?? 'Person ${cluster['id']}',
                        'id': cluster['id'],
                      },
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.grey[800],
                            ),
                            child: _buildFaceThumbnail(cluster['thumbnail'] as Uint8List?), 
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        cluster['name'] ?? 'Person ${cluster['id']}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildFaceThumbnail(Uint8List? thumbBytes) {
    if (thumbBytes != null && thumbBytes.isNotEmpty) {
        return Image.memory(thumbBytes, fit: BoxFit.cover);
    }
    return const Icon(Icons.person, color: Colors.white);
  }
} // End of _PeoplePageState


