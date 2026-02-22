import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../../services/database_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';
import '../../services/backup_service.dart';
import '../../models/remote_image.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/remote_photo_viewer.dart';
import 'package:extended_image/extended_image.dart';

class PersonDetailsPage extends StatefulWidget {
  final String personName;
  final int personId;

  const PersonDetailsPage({
    super.key,
    required this.personName,
    required this.personId,
  });

  @override
  State<PersonDetailsPage> createState() => _PersonDetailsPageState();
}

class _PersonDetailsPageState extends State<PersonDetailsPage> {
  final DatabaseService _dbService = DatabaseService();
  List<_FileGroup> _groupedFiles = [];
  bool _isLoading = true;
  late String _currentName;

  @override
  void initState() {
    super.initState();
    _currentName = widget.personName;
    _loadPersonAssets();
  }

  Future<void> _loadPersonAssets() async {
    final paths = await _dbService.getPhotoPathsForCluster(widget.personId);
    
    final List<File> localFiles = [];
    final List<String> cloudIds = [];

    for (final p in paths) {
      if (p.startsWith('cloud_')) {
        cloudIds.add(p.substring(6));
      } else {
        if (!kIsWeb) {
           final f = File(p);
           if (await f.exists()) {
             localFiles.add(f);
           }
        }
      }
    }

    // Group local files by Date
    final Map<DateTime, List<dynamic>> groups = {};
    
    for (final f in localFiles) {
      DateTime date;
      try {
        date = await f.lastModified();
      } catch (_) {
        date = DateTime.now();
      }
      final key = DateTime(date.year, date.month, date.day);
      if (!groups.containsKey(key)) groups[key] = [];
      groups[key]!.add(f);
    }

    final List<_FileGroup> sorted = groups.entries.map((e) => _FileGroup(e.key, e.value)).toList();
    sorted.sort((a, b) => b.date.compareTo(a.date));

    // Append a massive group for scattered Cloud Photos
    if (cloudIds.isNotEmpty) {
       sorted.insert(0, _FileGroup(DateTime.now(), cloudIds, isCloud: true));
    }

    if (mounted) {
      setState(() {
        _groupedFiles = sorted;
        _isLoading = false;
      });
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _currentName);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Person'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                 final newName = controller.text;
                 await _dbService.updateClusterName(widget.personId, newName);
                 if (mounted) setState(() => _currentName = newName);
                 Navigator.pop(context);
                 
                 // Trigger Cloud Sync
                 if (mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(
                     const SnackBar(content: Text('Name updated. Syncing to cloud...'), duration: Duration(seconds: 2)),
                   );
                 }
                 await BackupService().uploadFaceDatabase();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return DateFormat('EEE, d MMM yyyy').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_currentName),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: _editName),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedFiles.isEmpty
              ? const Center(child: Text('No photos found.'))
              : CustomScrollView(
                  slivers: [
                    for (var group in _groupedFiles) ...[
                      SliverPersistentHeader(
                        delegate: SectionHeaderDelegate(title: _formatDate(group.date)),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                        sliver: SliverGrid(
                          gridDelegate: kIsWeb
                              ? const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 6,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                )
                              : const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 220,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = group.items[index];
                            if (group.isCloud) {
                               return _CloudPhotoTile(imageId: item as String);
                            } else {
                               final file = item as File;
                               if (kIsWeb) return const SizedBox.shrink(); 
                               return GestureDetector(
                                  onTap: () {
                                     Navigator.push(context, MaterialPageRoute(builder: (_) => _SimplePhotoViewer(file: file)));
                                  },
                                  child: Stack(
                                     fit: StackFit.expand,
                                     children: [
                                        Image.file(file, fit: BoxFit.cover, cacheWidth: 600, filterQuality: FilterQuality.high),
                                        Positioned(
                                           bottom: 4, right: 4,
                                           child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                              child: const Icon(Icons.sd_storage, size: 16, color: Colors.white),
                                           ),
                                        ),
                                     ],
                                  ),
                               );
                            }
                          },
                          childCount: group.items.length,
                        ),
                      ),
                    ),
                  ]
                  ],
                ),
    );
  }
}

class _FileGroup {
  final DateTime date;
  final List<dynamic> items;
  final bool isCloud;
  _FileGroup(this.date, this.items, {this.isCloud = false});
}

class _CloudPhotoTile extends StatefulWidget {
  final String imageId;
  const _CloudPhotoTile({required this.imageId});
  @override
  State<_CloudPhotoTile> createState() => _CloudPhotoTileState();
}

class _CloudPhotoTileState extends State<_CloudPhotoTile> {
  RemoteImage? _remoteImage;
  Uint8List? _thumbBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
     final session = await AuthService().loadSession();
     if (session == null) return;
     final userId = session['username'] as String;
     final masterKeyBytes = session['masterKey'] as Uint8List;
     final key = SecureKey.fromList(CryptoService().sodium, masterKeyBytes);

     final r = await BackupService().fetchSingleRemoteImage(userId, widget.imageId);
     if (r != null && mounted) {
        setState(() => _remoteImage = r);
        var url = r.thumb256Url.isEmpty ? r.thumb64Url : r.thumb256Url;
        if (url.isNotEmpty) {
           final tb = await BackupService().fetchAndDecryptFromUrl(url, key);
           if (mounted) setState(() => _thumbBytes = tb);
        }
     }
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbBytes == null) {
        return Container(
            color: Colors.grey[900], 
            child: const Center(child: CircularProgressIndicator(strokeWidth: 2))
        );
    }
    return GestureDetector(
       onTap: () {
          if (_remoteImage != null) {
              Navigator.push(context, MaterialPageRoute(
                 builder: (_) => Scaffold(
                    extendBodyBehindAppBar: true,
                    appBar: AppBar(
                      backgroundColor: Colors.transparent, 
                      elevation: 0,
                      iconTheme: const IconThemeData(color: Colors.white),
                    ),
                    backgroundColor: Colors.black,
                    body: Center(
                      child: RemotePhotoViewer(remote: _remoteImage!, isActive: true),
                    ),
                 )
              ));
          }
       },
       child: Stack(
          fit: StackFit.expand,
          children: [
             Image.memory(_thumbBytes!, fit: BoxFit.cover, filterQuality: FilterQuality.high),
             Positioned(
                bottom: 4, right: 4,
                child: Container(
                   padding: const EdgeInsets.all(4),
                   decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                   child: const Icon(Icons.cloud, size: 16, color: Colors.white),
                ),
             ),
          ],
       )
    );
  }
}

class _SimplePhotoViewer extends StatelessWidget {
  final File file;
  const _SimplePhotoViewer({required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: kIsWeb 
            ? const Text('Not supported on Web', style: TextStyle(color: Colors.white)) 
            : ExtendedImage.file(
                file, 
                fit: BoxFit.contain,
                mode: ExtendedImageMode.gesture,
                onDoubleTap: (state) {
                   final double beginScale = state.gestureDetails?.totalScale ?? 1.0;
                   double targetScale = 1.0;
                   if (beginScale <= 1.001) targetScale = 3.0;
                   state.handleDoubleTap(scale: targetScale, doubleTapPosition: state.pointerDownPosition);
                },
                initGestureConfigHandler: (state) => GestureConfig(
                   inPageView: false,
                   minScale: 0.9,
                   maxScale: 10.0,
                   cacheGesture: true,
                ),
              ),
      ),
    );
  }
}
