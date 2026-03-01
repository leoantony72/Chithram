import 'dart:io';
import 'dart:ui';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:extended_image/extended_image.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import '../../providers/photo_provider.dart';
import '../../models/gallery_item.dart';
import '../widgets/video_viewer.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/remote_photo_viewer.dart';

class AssetViewerPage extends StatefulWidget {
  final GalleryItem item; 
  final List<GalleryItem>? items;

  const AssetViewerPage({super.key, required this.item, this.items});

  @override
  State<AssetViewerPage> createState() => _AssetViewerPageState();
}

class _AssetViewerPageState extends State<AssetViewerPage> {
  late ExtendedPageController _pageController;
  late int _currentIndex;
  late List<GalleryItem> _items; 
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInit) {
      if (widget.items != null) {
        _items = widget.items!;
      } else {
        final provider = Provider.of<PhotoProvider>(context, listen: false);
        _items = provider.allItems; // Use unified list
      }
      
      // Find initial index
      final index = _items.indexWhere((e) => e.id == widget.item.id);
      _currentIndex = index != -1 ? index : 0;
      
      _pageController = ExtendedPageController(initialPage: _currentIndex);
      _isInit = true;
      
      // Precache neighbors
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _precacheImages(_currentIndex);
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _precacheImages(index);
  }

  void _precacheImages(int index) {
    // Proactively decode neighbor local images
    final indexesToCache = [index - 1, index + 1];
    
    for (final i in indexesToCache) {
       if (i >= 0 && i < _items.length) {
          final item = _items[i];
          if (item.type == GalleryItemType.local && item.local!.type == AssetType.image) {
             _precacheSingleAsset(item.local!);
          }
          // Note: Remote image precaching is complex due to encryption, skipped for now
       }
    }
  }

  Future<void> _precacheSingleAsset(AssetEntity asset) async {
      final mediaQuery = MediaQuery.of(context);
      final pixelRatio = mediaQuery.devicePixelRatio;
      final targetWidth = (mediaQuery.size.width * pixelRatio).toInt();
      final targetHeight = (mediaQuery.size.height * pixelRatio).toInt();
      
      final provider = AssetEntityImageProvider(
        asset,
        isOriginal: false,
        thumbnailSize: ThumbnailSize(targetWidth, targetHeight),
        thumbnailFormat: ThumbnailFormat.jpeg,
      );
      
      await precacheImage(provider, context);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) return const Scaffold(backgroundColor: Colors.black);
    
    if (_items.isEmpty) {
        return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.transparent),
            body: const Center(child: Text("No photos", style: TextStyle(color: Colors.white)))
        );
    }
    
    final currentItem = _items[_currentIndex];
    final provider = Provider.of<PhotoProvider>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
           _formatDateTime(currentItem.date),
           style: const TextStyle(
             color: Colors.white70, 
             fontSize: 14,
             shadows: [Shadow(color: Colors.black, blurRadius: 4)]
           ),
        ),
        actions: [
          // Favorite Toggle
          IconButton(
            icon: Icon(
              currentItem.isFavorite ? Icons.favorite : Icons.favorite_border,
              color: currentItem.isFavorite ? Colors.redAccent : Colors.white,
            ),
            onPressed: () {
              provider.toggleFavorite(currentItem);
              // Force local UI refresh if needed, but PhotoProvider.notifyListeners should catch it
              setState(() {}); 
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'About') {
                _showDetails(context, currentItem);
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'About',
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.black87),
                      SizedBox(width: 8),
                      Text('About'),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            _pageController.previousPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            _pageController.nextPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              ScrollConfiguration(
                behavior: const _GalleryScrollBehavior(),
                child: ExtendedImageGesturePageView.builder(
                  controller: _pageController,
                  itemCount: _items.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return _buildItem(item, index);
                  },
                ),
              ),
              // Navigation Buttons (Hidden on Android/Touch)
              if (_currentIndex > 0 && (kIsWeb || !Platform.isAndroid))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16.0),
                    child: IconButton(
                      onPressed: () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 30),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withOpacity(0.3),
                        hoverColor: Colors.black.withOpacity(0.5),
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ),
              if (_currentIndex < _items.length - 1 && (kIsWeb || !Platform.isAndroid))
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16.0),
                    child: IconButton(
                      onPressed: () {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                      icon: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 30),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withOpacity(0.3),
                        hoverColor: Colors.black.withOpacity(0.5),
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ),

              // Modern Bottom Action Bar
              Align(
                alignment: Alignment.bottomCenter,
                child: _buildBottomActions(context, currentItem, provider),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActions(BuildContext context, GalleryItem item, PhotoProvider provider) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _actionIcon(Icons.share_outlined, "Share", () => _onShare(item)),
          _actionIcon(Icons.edit_outlined, "Edit", () => _onEdit(item)),
          _actionIcon(Icons.library_add_outlined, "Album", () => _onAddToAlbum(context, item, provider)),
          _actionIcon(Icons.delete_outline, "Delete", () => _onDelete(context, item, provider)),
        ],
      ),
    );
  }

  Widget _actionIcon(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Future<void> _onShare(GalleryItem item) async {
    if (item.type == GalleryItemType.local) {
      final file = await item.local!.file;
      if (file != null) {
        await Share.shareXFiles([XFile(file.path)], text: 'Check out this photo!');
      }
    } else {
      // Remote - share URL
      await Share.share(item.remote!.originalUrl, subject: 'Shared from Ninta');
    }
  }

  void _onEdit(GalleryItem item) async {
    if (item.type == GalleryItemType.local) {
      final bool? edited = await context.push<bool>('/edit', extra: item.local);
      if (edited == true) {
        // Refresh the whole gallery because IDs or file paths have changed
        PhotoProvider provider = Provider.of<PhotoProvider>(context, listen: false);
        await provider.fetchAssets(force: true);
        
        if (context.mounted) {
          // It's safest to pop back to the gallery since the current viewer 
          // state (indices) might no longer match the updated asset list.
          Navigator.pop(context); 
        }
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Editing remote images is coming soon!")),
      );
    }
  }

  void _onAddToAlbum(BuildContext context, GalleryItem item, PhotoProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return _AlbumPickerSheet(item: item, provider: provider);
      },
    );
  }

  void _onDelete(BuildContext context, GalleryItem item, PhotoProvider provider) async {
    await provider.deleteSelectedPhotos(context, [item]);
    // If the list is now empty or the index changed, the provider logic handles it.
    // If the index was the last one, we might need to go back.
    if (_items.isEmpty) {
      if (mounted) context.pop();
    }
  }
  
  Widget _buildItem(GalleryItem item, int index) {
    final isActive = index == _currentIndex;

    if (item.type == GalleryItemType.local) {
       final asset = item.local!;
       if (asset.type == AssetType.video) {
         return VideoViewer(asset: asset, isActive: isActive);
       }
       return PhotoViewer(asset: asset, isActive: isActive);
    } else {
       // Remote
       final remote = item.remote!;
       // TODO: RemoteVideoViewer implementation if desired
       return RemotePhotoViewer(remote: remote, isActive: isActive);
    }
  }

  String _formatDateTime(DateTime date) {
    return DateFormat('d MMM yyyy, HH:mm').format(date);
  }

  void _showDetails(BuildContext context, GalleryItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _DetailsSheet(item: item),
    );
  }
}

class _GalleryScrollBehavior extends MaterialScrollBehavior {
  const _GalleryScrollBehavior(); // Add const constructor

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}

class _DetailsSheet extends StatefulWidget {
  final GalleryItem item;
  const _DetailsSheet({required this.item});

  @override
  State<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<_DetailsSheet> {
  String? _filePath;
  int? _fileSize;
  int? _width;
  int? _height;
  latlong.LatLng? _location;
  String? _album;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    final item = widget.item;
    if (item.type == GalleryItemType.local) {
      final asset = item.local!;
      final file = await asset.file;
      final latlng = await asset.latlngAsync();
      final double? lat = latlng?.latitude;
      final double? lng = latlng?.longitude;
      
      if (mounted) {
        setState(() {
          _filePath = file?.path;
          _fileSize = file != null ? file.lengthSync() : 0;
          _width = asset.width;
          _height = asset.height;
          if (lat != null && lng != null && (lat != 0 || lng != 0)) {
            _location = latlong.LatLng(lat, lng);
          }
          _album = "Local Album"; // AssetEntity doesn't easily expose parent path name here without extra lookup
          _loading = false;
        });
      }
    } else {
      final remote = item.remote!;
      if (mounted) {
        setState(() {
          _fileSize = remote.size;
          _width = remote.width;
          _height = remote.height;
          if (remote.latitude != 0 || remote.longitude != 0) {
            _location = latlong.LatLng(remote.latitude, remote.longitude);
          }
          _album = remote.album;
          _loading = false;
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                const Text(
                  "Information",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_loading)
                    const Center(child: Padding(
                      padding: EdgeInsets.all(40.0),
                      child: CircularProgressIndicator(color: Colors.white70),
                    ))
                  else ...[
                    // Date and Time Section
                    _buildSectionHeader("DATE & TIME"),
                    _buildDetailItem(
                      icon: Icons.calendar_today_rounded,
                      title: DateFormat('EEEE, d MMMM yyyy').format(item.date),
                      subtitle: DateFormat('HH:mm').format(item.date),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // File details Section
                    _buildSectionHeader("FILE DETAILS"),
                    _buildDetailItem(
                      icon: Icons.image_rounded,
                      title: item.type == GalleryItemType.local ? (item.local?.title ?? "Unknown") : "Cloud Image",
                      subtitle: "${_width ?? 0} x ${_height ?? 0} • ${_fileSize != null ? _formatBytes(_fileSize!) : 'Unknown size'}",
                    ),
                    if (_album != null && _album!.isNotEmpty)
                      _buildDetailItem(
                        icon: Icons.folder_open_rounded,
                        title: _album!,
                        subtitle: "Album",
                      ),
                    if (_filePath != null)
                      _buildDetailItem(
                        icon: Icons.description_rounded,
                        title: _filePath!.split('/').last,
                        subtitle: _filePath!,
                      ),

                    const SizedBox(height: 24),

                    // Location Section
                    if (_location != null) ...[
                      _buildSectionHeader("LOCATION"),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          height: 180,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: _location!,
                              initialZoom: 13,
                              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.ninta.app',
                                tileDisplay: const TileDisplay.fadeIn(),
                                // Dark mode filter for map
                                tileBuilder: (context, tileWidget, tile) {
                                  return ColorFiltered(
                                    colorFilter: const ColorFilter.matrix([
                                      -1.0, 0.0, 0.0, 0.0, 255.0,
                                      0.0, -1.0, 0.0, 0.0, 255.0,
                                      0.0, 0.0, -1.0, 0.0, 255.0,
                                      0.0, 0.0, 0.0, 1.0, 0.0,
                                    ]),
                                    child: tileWidget,
                                  );
                                },
                              ),
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: _location!,
                                    width: 40,
                                    height: 40,
                                    child: const Icon(Icons.location_on, color: Colors.blue, size: 40),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "${_location!.latitude.toStringAsFixed(6)}, ${_location!.longitude.toStringAsFixed(6)}",
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white.withOpacity(0.3),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildDetailItem({required IconData icon, required String title, required String subtitle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white70, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumPickerSheet extends StatelessWidget {
  final GalleryItem item;
  final PhotoProvider provider;
  const _AlbumPickerSheet({required this.item, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, child) {
        final localAlbums = provider.paths;
        final remoteAlbums = provider.remoteAlbums;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Add to Album",
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (localAlbums.isNotEmpty) ...[
                      const Text("Local Albums",
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ...localAlbums.map((album) => ListTile(
                            leading: const Icon(Icons.folder_outlined, color: Colors.blueAccent),
                            title: Text(album.name, style: const TextStyle(color: Colors.white)),
                            onTap: () async {
                              final error = await provider.addSelectedToAlbum([item], album, null);
                              if (context.mounted) {
                                Navigator.pop(context);
                                if (error != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Added to local album")));
                                }
                              }
                            },
                          )),
                      const SizedBox(height: 16),
                    ],
                    if (remoteAlbums.isNotEmpty) ...[
                      const Text("Cloud Albums",
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ...remoteAlbums.map((album) {
                        final String name = album['name'] ?? 'Unnamed';
                        return ListTile(
                          leading: const Icon(Icons.cloud_outlined, color: Colors.greenAccent),
                          title: Text(name, style: const TextStyle(color: Colors.white)),
                          onTap: () async {
                            final error = await provider.addSelectedToAlbum([item], null, name);
                            if (context.mounted) {
                              Navigator.pop(context);
                              if (error != null) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Added to cloud album")));
                              }
                            }
                          },
                        );
                      }),
                    ],
                    if (localAlbums.isEmpty && remoteAlbums.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: Text("No albums found", style: TextStyle(color: Colors.white54))),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
}
