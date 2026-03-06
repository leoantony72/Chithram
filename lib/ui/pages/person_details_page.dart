import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/photo_provider.dart';
import '../../models/gallery_item.dart';
import '../../services/database_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';
import '../../services/backup_service.dart';
import '../../models/remote_image.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/section_header_delegate.dart';

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
    
    // Access provider once
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final List<GalleryItem> items = [];

    for (final p in paths) {
      if (p.startsWith('cloud_')) {
        final cloudId = p.substring(6);
        // Find existing remote item or create temporary one
        final remote = provider.remoteImages.firstWhereOrNull((r) => r.imageId == cloudId);
        if (remote != null) {
          items.add(GalleryItem.remote(remote));
        } else {
          // If not in provider yet, we'll mark it as a "placeholder" remote
          items.add(GalleryItem.remote(RemoteImage(
              imageId: cloudId, 
              userId: '', 
              width: 0, 
              height: 0, 
              originalUrl: '', 
              thumb1024Url: '', 
              thumb256Url: '', 
              thumb64Url: '',
              mimeType: '', 
              size: 0
          )));
        }
      } else {
        // Find local item in provider
        final asset = provider.allItems.firstWhereOrNull((item) {
          if (item.type != GalleryItemType.local || item.local == null) return false;
          final title = item.local!.title;
          return title != null && title.isNotEmpty && p.endsWith('/$title');
        });
        if (asset != null) {
          items.add(asset);
        } else if (!kIsWeb) {
          // Fallback if not in provider yet (unlikely for indexed faces)
          final f = io.File(p);
          if (await f.exists()) {
             // We don't have the AssetEntity, so we can't easily make a GalleryItem.local
             // This case is rare if the face index is in sync.
          }
        }
      }
    }

    // Sort all by date descending
    items.sort((a, b) => b.date.compareTo(a.date));

    // Group by Date for UI headers
    final Map<DateTime, List<GalleryItem>> groups = {};
    for (final item in items) {
      final date = item.date;
      final key = DateTime(date.year, date.month, date.day);
      if (!groups.containsKey(key)) groups[key] = [];
      groups[key]!.add(item);
    }

    final List<_FileGroup> sortedGroups = groups.entries
        .map((e) => _FileGroup(e.key, e.value))
        .toList();
    sortedGroups.sort((a, b) => b.date.compareTo(a.date));

    if (mounted) {
      setState(() {
        _groupedFiles = sortedGroups;
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
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'rename') {
                _editName();
              } else if (value == 'set_cover') {
                _showCoverPhotoSelector();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'rename',
                child: Text('Rename Person'),
              ),
              const PopupMenuItem<String>(
                value: 'set_cover',
                child: Text('Set Cover Photo'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedFiles.isEmpty
              ? const Center(child: Text('No photos found.'))
              : Consumer<PhotoProvider>(
                  builder: (context, provider, _) {
                    // Collect all items in this cluster for viewer navigation
                    final List<GalleryItem> allItems = [];
                    for (final group in _groupedFiles) {
                      allItems.addAll(group.items);
                    }

                    return CustomScrollView(
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
                                    return ThumbnailWidget(
                                      item: item,
                                      onTap: () {
                                        context.push('/viewer', extra: {
                                          'item': item,
                                          'items': allItems.isNotEmpty ? List<GalleryItem>.from(allItems) : null,
                                        });
                                      },
                                    );
                                  },
                                  childCount: group.items.length,
                                ),
                            ),
                          ),
                        ]
                      ],
                    );
                  },
                ),
    );
  }

  Future<void> _showCoverPhotoSelector() async {
    // Show loading dialog or bottom sheet 
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return _CoverPhotoSelectorSheet(
          personId: widget.personId,
          dbService: _dbService,
          onFaceSelected: (int faceId) async {
            await _dbService.updateClusterRepresentative(widget.personId, faceId);
            if (mounted) {
               Navigator.pop(context); // Close sheet
               ScaffoldMessenger.of(context).showSnackBar(
                 const SnackBar(content: Text('Cover photo updated! Syncing to cloud...'), duration: Duration(seconds: 2)),
               );
            }
            // Trigger Cloud Backup
            await BackupService().uploadFaceDatabase();
          },
        );
      },
    );
  }
}

class _CoverPhotoSelectorSheet extends StatefulWidget {
  final int personId;
  final DatabaseService dbService;
  final Function(int faceId) onFaceSelected;

  const _CoverPhotoSelectorSheet({
    required this.personId,
    required this.dbService,
    required this.onFaceSelected,
  });

  @override
  State<_CoverPhotoSelectorSheet> createState() => _CoverPhotoSelectorSheetState();
}

class _CoverPhotoSelectorSheetState extends State<_CoverPhotoSelectorSheet> {
  List<Map<String, dynamic>> _faces = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    final allFaces = await widget.dbService.getFacesInCluster(widget.personId);
    
    // Only show cover photos where the thumbnail is actually present/valid
    final validFaces = allFaces.where((f) {
      final thumbBytes = f['thumbnail'] as Uint8List?;
      return thumbBytes != null && thumbBytes.isNotEmpty;
    }).toList();

    if (mounted) {
       setState(() {
         _faces = validFaces;
         _isLoading = false;
       });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        if (_isLoading) {
           return const Center(child: CircularProgressIndicator());
        }
        if (_faces.isEmpty) {
           return const Center(child: Text('No faces found.', style: TextStyle(color: Colors.white)));
        }
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Select Cover Photo',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: GridView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _faces.length,
                itemBuilder: (context, index) {
                  final face = _faces[index];
                  final Uint8List? thumbBytes = face['thumbnail'] as Uint8List?;
                  
                  return GestureDetector(
                    onTap: () => widget.onFaceSelected(face['id'] as int),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: thumbBytes != null && thumbBytes.isNotEmpty
                              ? Image.memory(
                                  thumbBytes, 
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (context, error, stackTrace) => Container(
                                      color: Colors.grey[800],
                                      child: const Icon(Icons.broken_image, color: Colors.white54),
                                  ),
                                )
                              : Container(
                                color: Colors.grey[800],
                                child: const Icon(Icons.person, color: Colors.white54),
                              ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FileGroup {
  final DateTime date;
  final List<GalleryItem> items;
  _FileGroup(this.date, this.items);
}
