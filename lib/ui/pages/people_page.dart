import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../../services/model_service.dart';
import '../../services/database_service.dart';
import '../../services/face_service.dart';
import '../../services/cluster_service.dart';
import '../../services/federated_learning_service.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/crypto_service.dart';

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
  bool _isTraining = false;
  double _trainingProgress = 0.0;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _loadClusters();
    _checkSync();
    _initializeServices();
  }

  Future<void> _checkSync() async {
    final session = await AuthService().loadSession();
    if (session == null) return;
    final userId = session['username'] as String;

    final remoteVersion = await BackupService().getRemotePeopleVersion(userId);
    if (remoteVersion == -1) return;

    final localVersionStr = await _dbService.getBackupSetting('people_data_version');
    final localVersion = int.tryParse(localVersionStr ?? '0') ?? 0;

    if (remoteVersion > localVersion) {
      debugPrint('Sync: Remote version ($remoteVersion) > Local ($localVersion). Downloading...');
      setState(() {
        _isScanning = true;
        _statusMessage = 'Syncing from Cloud...';
      });
      final success = await BackupService().downloadFaceDatabase(inMemoryOnly: kIsWeb);
      if (success) {
        await _loadClusters();
      }
      setState(() {
        _isScanning = false;
        _statusMessage = success ? 'Sync Complete' : 'Sync Failed';
      });
    }
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
    
    // Sort: People with actual names first
    final sortedClusters = List<Map<String, dynamic>>.from(clusters);
    final personPattern = RegExp(r'^Person \d+$');

    sortedClusters.sort((a, b) {
      final nameA = a['name'] as String? ?? '';
      final nameB = b['name'] as String? ?? '';
      
      final isDefaultA = nameA.isEmpty || personPattern.hasMatch(nameA);
      final isDefaultB = nameB.isEmpty || personPattern.hasMatch(nameB);
      
      if (!isDefaultA && isDefaultB) return -1;
      if (isDefaultA && !isDefaultB) return 1;
      return nameA.compareTo(nameB); // Secondary sort alphabetically
    });

    setState(() {
      _clusters = sortedClusters;
    });
  }

  Future<void> _startScan() async {
    if (kIsWeb) return;

    setState(() {
      _isScanning = true;
      _statusMessage = 'Initializing...';
    });

    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        final PermissionState ps = await PhotoManager.requestPermissionExtend();
        if (!ps.isAuth) {
          setState(() => _isScanning = false);
          return;
        }
      }
    } catch (e) {
      debugPrint("PhotoManager permission check error (ignoring on Desktop): $e");
    }

    final modelsReady = await _modelService.ensureModelsDownloaded();
    if (!modelsReady) {
      if (mounted) {
        setState(() => _isScanning = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Model Error')));
      }
      return;
    }

    await _faceService.reset();
    await _faceService.initialize();

    // Pipeline Execution
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
       await _scanDetectionPhase();
       await _scanEmbeddingPhase();
    }
    
    // Always scan cloud photos to ensure all images are used
    await _scanCloudPhotos();

    if (_statusMessage != 'Scan Complete') {
       await _scanClusteringPhase();
    }
    
    setState(() => _statusMessage = 'Uploading to Cloud...');
    final uploadSuccess = await BackupService().uploadFaceDatabase();
    
    setState(() {
      _isScanning = false;
      _statusMessage = uploadSuccess ? 'Scan & Cloud Sync Complete' : 'Scan Complete (Upload Failed)';
    });
    _loadClusters();
  }

  Future<void> _scanClusteringPhase() async {
    setState(() => _statusMessage = 'Phase 3: Clustering Faces...');
    await _clusterService.runClustering();
  }

  Future<void> _scanCloudPhotos() async {
    setState(() => _statusMessage = 'Fetching from Cloud...');
    
    final auth = AuthService();
    final crypto = CryptoService();
    final backup = BackupService();
    
    final session = await auth.loadSession();
    if (session == null) {
      setState(() => _statusMessage = 'Not logged in');
      return;
    }
    
    final userId = session['username'] as String;
    final masterKeyBytes = session['masterKey'] as Uint8List;
    final masterKey = SecureKey.fromList(crypto.sodium, masterKeyBytes);
    
    String? cursor;
    int processedCount = 0;
    
    while (_isScanning) {
      final response = await backup.fetchRemoteImages(userId, cursor: cursor);
      if (response == null || response.images.isEmpty) break;
      
      final tempDir = await getTemporaryDirectory();
      
      for (final image in response.images) {
         if (!_isScanning) break;
         
         final uniqueId = 'cloud_${image.imageId}';
         if (await _dbService.isImageProcessed(uniqueId)) {
            continue;
         }
         
         setState(() => _statusMessage = 'Downloading / Scanning: ${image.imageId.substring(0,8)}...');
         
         // Download and decrypt Original explicitly
         final bytes = await backup.fetchAndDecryptFromUrl(image.originalUrl, masterKey);
         if (bytes != null) {
            final tempFile = File('${tempDir.path}/${image.imageId}.jpg');
            await tempFile.writeAsBytes(bytes);
            
            await _processImageComplete(tempFile, uniqueId);
            
            // Delete massive original files to enforce local footprint
            if (await tempFile.exists()) {
               await tempFile.delete();
            }
         }
         processedCount++;
      }
      
      
      final newCursor = response.nextCursor;
      if (newCursor == null || newCursor.isEmpty || newCursor == cursor) {
          break;
      }
      cursor = newCursor;
    }
  }

  Future<void> _processImageComplete(File file, String uniqueId) async {
      try {
        final faces = await _faceService.detectFaces(file);
        for (final face in faces) {
            String? landmarksStr;
            final le = face.leftEye;
            final re = face.rightEye;
            if (le != null && re != null) {
              landmarksStr = '${le.x},${le.y};${re.x},${re.y}';
            }

            final data = await _faceService.getEmbeddingFromData(
                 file, 
                 face.boundingBox, 
                 leftEye: le, 
                 rightEye: re
            );
            
            Uint8List? embeddingBytes;
            Uint8List? thumbBytes;
            if (data != null) {
                embeddingBytes = Float32List.fromList(data.embedding).buffer.asUint8List();
                thumbBytes = data.thumbnail;
            }

            await _dbService.insertFace(
              uniqueId, 
              face.boundingBox.toString(),
              landmarksStr,
              embeddingBytes,
              thumbBytes
            );
        }
        await _dbService.markImageAsProcessed(uniqueId);
      } catch (e) {
        print('Error processing complete $uniqueId: $e');
      }
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
      // Fetch the true original image file, bypass thumbnail cache entirely
      final file = await entity.originFile;
      if (file == null) return;

      if (await _dbService.isImageProcessed(file.path)) return;

      try {
        final faces = await _faceService.detectFaces(file);
        for (final face in faces) {
            String? landmarksStr;
            final le = face.leftEye;
            final re = face.rightEye;
            if (le != null && re != null) {
              landmarksStr = '${le.x},${le.y};${re.x},${re.y}';
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

  Future<void> _uploadDb() async {
      setState(() => _isScanning = true);
      setState(() => _statusMessage = 'Uploading DB to MinIO...');
      final s = await BackupService().uploadFaceDatabase();
      setState(() {
         _statusMessage = s ? 'Backup Complete' : 'Backup Failed';
         _isScanning = false;
      });
  }

  Future<void> _downloadDb() async {
      setState(() => _isScanning = true);
      setState(() => _statusMessage = 'Downloading DB from MinIO...');
      final s = await BackupService().downloadFaceDatabase(inMemoryOnly: kIsWeb);
      
      // Temporary Web logic, fully refresh local state from DB if written, or notify user.
      setState(() {
         _statusMessage = s ? 'Restore Complete' : 'Restore Failed';
         _isScanning = false;
      });
      _loadClusters();
  }

  void _triggerTrain() {
      setState(() {
        _isTraining = true;
        _trainingProgress = 0.0;
        _statusMessage = 'Initializing Training...';
      });
      FederatedLearningService().trainAndUpload(onProgress: (p, s) {
        if (mounted) {
            setState(() {
              if (p >= 0) _trainingProgress = p;
              _statusMessage = s;
            });
        }
      }).then((_) {
        if (mounted) {
            setState(() {
              _isTraining = false;
            });
        }
      });
  }

  Future<void> _showCustomMenu(BuildContext context) async {
    showGeneralDialog(
      context: context,
      pageBuilder: (ctx, a1, a2) => const SizedBox(),
      barrierDismissible: true,
      barrierLabel: "Menu",
      barrierColor: Colors.black.withOpacity(0.2),
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return Stack(
          children: [
            Positioned(
              top: kToolbarHeight + 8,
              right: 16,
              width: 260,
              child: ScaleTransition(
                scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: anim1,
                  child: Material(
                    color: Colors.transparent,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withOpacity(0.15)),
                            boxShadow: const [
                              BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 10))
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _MenuActionItem(
                                icon: Icons.model_training_rounded, 
                                label: 'Improve Models (AI Train)',
                                iconColor: Colors.blueAccent,
                                onTap: () { Navigator.pop(ctx); _triggerTrain(); }
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Divider(height: 1, color: Colors.white.withOpacity(0.1)),
                              ),
                              _MenuActionItem(
                                icon: Icons.cloud_download_rounded, 
                                label: 'Restore AI from Cloud',
                                onTap: () { Navigator.pop(ctx); _downloadDb(); }
                              ),
                              _MenuActionItem(
                                icon: Icons.cloud_upload_rounded, 
                                label: 'Backup AI to Cloud',
                                onTap: () { Navigator.pop(ctx); _uploadDb(); }
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Divider(height: 1, color: Colors.white.withOpacity(0.1)),
                              ),
                              _MenuActionItem(
                                icon: Icons.data_object_rounded, 
                                label: 'Export Vectors JSON',
                                onTap: () { Navigator.pop(ctx); _exportFaceData(); }
                              ),
                              _MenuActionItem(
                                icon: Icons.delete_forever_rounded, 
                                label: 'Reset People Database',
                                iconColor: Colors.redAccent,
                                onTap: () { Navigator.pop(ctx); _resetDatabase(); }
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Pure black background
      appBar: AppBar(
        title: const Text('People', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: IconButton(
              icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
              onPressed: () => _showCustomMenu(context),
            ),
          ),
          if (_isScanning || _isTraining)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(_statusMessage, style: const TextStyle(fontSize: 12, color: Colors.amber)),
              ),
            )
          else if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.sync_rounded),
              tooltip: 'Scan Local & Cloud Photos',
              onPressed: _startScan,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isTraining)
            LinearProgressIndicator(
              value: _trainingProgress,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
            ),
          Expanded(
            child: _clusters.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                     padding: const EdgeInsets.all(24),
                     decoration: BoxDecoration(
                         shape: BoxShape.circle,
                         color: Colors.white.withOpacity(0.05)
                     ),
                     child: const Icon(Icons.people_outline, size: 64, color: Colors.white54),
                  ),
                  const SizedBox(height: 24),
                  const Text('No people found yet.', style: TextStyle(color: Colors.white54, fontSize: 18)),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _downloadDb,
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('Load from Cloud'),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!kIsWeb)
                      TextButton.icon(
                        onPressed: _startScan,
                        icon: const Icon(Icons.document_scanner),
                        label: const Text('Scan Local Photos'),
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                      ),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: MediaQuery.of(context).size.width < 600 ? 3 : 6,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.75,
              ),
              itemCount: _clusters.length,
              itemBuilder: (context, index) {
                final cluster = _clusters[index];
                final String name = cluster['name'] ?? 'Person ${cluster['id']}';
                final Uint8List? thumb = cluster['thumbnail'] as Uint8List?;

                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      await context.push(
                        '/person_details',
                        extra: {
                          'name': name,
                          'id': cluster['id'],
                        },
                      );
                      _loadClusters();
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: AspectRatio(
                                aspectRatio: 1,
                              child: Hero(
                                tag: 'person_${cluster['id']}',
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.4),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: ClipOval(
                                    child: _buildFaceThumbnail(thumb),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                        const SizedBox(height: 12),
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceThumbnail(Uint8List? thumbBytes) {
    if (thumbBytes != null && thumbBytes.isNotEmpty) {
        return Image.memory(
           thumbBytes, 
           fit: BoxFit.cover,
           filterQuality: FilterQuality.medium,
           gaplessPlayback: true,
           isAntiAlias: true,
        );
    }
    return Container(
        color: Colors.grey[800],
        child: const Icon(Icons.person_rounded, color: Colors.white54, size: 48)
    );
  }
} // End of _PeoplePageState

class _MenuActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color iconColor;

  const _MenuActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.white.withOpacity(0.1),
      highlightColor: Colors.white.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

