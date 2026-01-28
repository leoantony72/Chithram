import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import '../models/photo_group.dart';
import '../services/thumbnail_cache.dart';

class PhotoProvider with ChangeNotifier {
  List<AssetPathEntity> _paths = [];
  List<AssetEntity> _allAssets = [];
  
  // Grouped data
  List<PhotoGroup> _groupedByDay = [];
  List<PhotoGroup> _groupedByMonth = [];
  List<PhotoGroup> _groupedByYear = [];
  
  bool _hasPermission = false;
  bool _isLoading = false;

  List<AssetPathEntity> get paths => _paths;
  List<AssetEntity> get allAssets => _allAssets;
  
  List<PhotoGroup> get groupedByDay => _groupedByDay;
  List<PhotoGroup> get groupedByMonth => _groupedByMonth;
  List<PhotoGroup> get groupedByYear => _groupedByYear;
  
  bool get hasPermission => _hasPermission;
  bool get isLoading => _isLoading;

  Future<void> checkPermission() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth) {
      _hasPermission = true;
      await fetchAssets();
    } else {
      _hasPermission = false;
      await PhotoManager.openSetting();
    }
    notifyListeners();
  }
  
  Future<void> fetchAssets() async {
    _isLoading = true;
    _allAssets = [];
    notifyListeners();

    try {
      final FilterOptionGroup option = FilterOptionGroup(
        orders: [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      );

      // Fetch albums (AssetPathEntity)
      _paths = await PhotoManager.getAssetPathList(
        type: RequestType.common, 
        filterOption: option,
      );

      // Fetch all photos from the "Recent" (usually first) album
      if (_paths.isNotEmpty) {
        final totalCount = await _paths.first.assetCountAsync;
        
        // Step 1: Instant Load (First Batch)
        // Load enough to fill a few screens, but not too much to block the UI
        final int firstBatchSize = 80;
        final int fetchCount = totalCount < firstBatchSize ? totalCount : firstBatchSize;
        
        _allAssets = await _paths.first.getAssetListRange(start: 0, end: fetchCount);
        _groupAssets();
        
        _isLoading = false;
        notifyListeners();

        // Step 2: Background Tasks
        debugPrint("📊 TOTAL ASSETS FOUND: $totalCount");

        // Ensure we have the disk index loaded so we can skip already generated thumbnails
        await ThumbnailCache().init();
        
        final sizeBytes = await ThumbnailCache().getDiskCacheSize();
        final sizeMB = (sizeBytes / (1024 * 1024)).toStringAsFixed(2);
        final count = ThumbnailCache().diskCacheCount;
        debugPrint("💾 INITIAL THUMBNAIL CACHE: $count items ($sizeMB MB)");

        // Stream the rest of the assets if any
        if (totalCount > fetchCount) {
           _fetchRemainingAssets(fetchCount, totalCount);
        }
      }
    } catch (e) {
      debugPrint("Error fetching assets: $e");
      _isLoading = false;
      notifyListeners();
    } finally {
      // already handled
    }
  }

  // Background generation queue
  final List<AssetEntity> _thumbnailQueue = [];
  bool _isGeneratingThumbnails = false;
  int _generatedCount = 0;
  
  // Expose status for UI without rebuilding the whole provider
  final ValueNotifier<String?> backgroundStatus = ValueNotifier(null);

  Future<void> _fetchRemainingAssets(int startIndex, int totalCount) async {
    const int chunkSize = 5000; 
    
    for (int start = startIndex; start < totalCount; start += chunkSize) {
      if (!_hasPermission) break;

      int end = start + chunkSize;
      if (end > totalCount) end = totalCount;
      
      try {
        final chunk = await _paths.first.getAssetListRange(start: start, end: end);
        if (chunk.isNotEmpty) {
           _allAssets.addAll(chunk);
           _groupAssets();
           notifyListeners();
           
           // Queue this chunk for background thumb generation
           _queueThumbnails(chunk);
        }
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (e) {
        debugPrint("Error fetching chunk $start-$end: $e");
      }
    }
  }

  void _queueThumbnails(List<AssetEntity> assets) {
    // Filter BEFORE adding to queue.
    // This ensures that on app restart, we ignore the images already in the index.txt
    // preventing them from clogging the queue.
    final needed = assets.where((e) => !ThumbnailCache().hasInDisk(e.id)).toList();
    
    if (needed.isEmpty) return;

    _thumbnailQueue.addAll(needed);
    if (!_isGeneratingThumbnails) {
      _processThumbnailQueue();
    }
  }

  Future<void> _processThumbnailQueue() async {
    if (_thumbnailQueue.isEmpty) {
      _isGeneratingThumbnails = false;
      backgroundStatus.value = null; // Hide status
      return;
    }
    _isGeneratingThumbnails = true;

    // Process in small batches to not lock the UI thread
    // Isolate does heavy lifting, but platform channel traffic can still stutter UI.
    const int batchSize = 10;
    
    // Take a batch
    final count = _thumbnailQueue.length < batchSize ? _thumbnailQueue.length : batchSize;
    final batch = _thumbnailQueue.sublist(0, count);
    _thumbnailQueue.removeRange(0, count);

    // Filter for items needing generation (not on disk)
    final needed = batch.where((e) => !ThumbnailCache().hasInDisk(e.id)).toList();
    
    if (needed.isNotEmpty) {
       await ThumbnailCache().generateBatch(needed);
       _generatedCount += needed.length;
       
       if (_generatedCount % 50 == 0 || _generatedCount < 50) {
         final sizeBytes = await ThumbnailCache().getDiskCacheSize();
         final sizeMB = (sizeBytes / (1024 * 1024)).toStringAsFixed(2);
         // Log to console
         debugPrint("🖼️ Background Gen: $_generatedCount encoded. Total Cache: $sizeMB MB. (${_thumbnailQueue.length} pending)");
       }
       
       // Update UI status slightly less frequently to avoid flicker, or just every batch
       backgroundStatus.value = "Optimizing library... ${_thumbnailQueue.length} items remaining";
    }

    // Yield to UI
    await Future.delayed(const Duration(milliseconds: 100)); // Gentle background pace
    
    // Recursive loop
    _processThumbnailQueue();
  }



  void _groupAssets() {
    // Group by Day
    final Map<DateTime, List<AssetEntity>> dayGroups = groupBy(_allAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year, e.createDateTime.month, e.createDateTime.day);
    });

    _groupedByDay = dayGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    
    // Sort groups by date descending
    _groupedByDay.sort((a, b) => b.date.compareTo(a.date));


    // Group by Month
    final Map<DateTime, List<AssetEntity>> monthGroups = groupBy(_allAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year, e.createDateTime.month);
    });

    _groupedByMonth = monthGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    
    // Sort groups by date descending
    _groupedByMonth.sort((a, b) => b.date.compareTo(a.date));

    // Group by Year
    final Map<DateTime, List<AssetEntity>> yearGroups = groupBy(_allAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year);
    });

    _groupedByYear = yearGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    
    // Sort groups by date descending (Newest year first)
    _groupedByYear.sort((a, b) => b.date.compareTo(a.date));
  }

  Future<List<AssetEntity>> getAssetsFromPath(AssetPathEntity path) async {
     return await path.getAssetListRange(start: 0, end: 10000);
  }
}
