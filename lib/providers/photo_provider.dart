import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import '../models/photo_group.dart';

class PhotoProvider with ChangeNotifier {
  List<AssetPathEntity> _paths = [];
  List<AssetEntity> _allAssets = [];
  
  // Grouped data
  List<PhotoGroup> _groupedByDay = [];
  List<PhotoGroup> _groupedByMonth = [];
  List<PhotoGroup> _groupedByYear = [];
  
  bool _hasPermission = false;
  bool _isLoading = false;
  
  // Expose status for UI (now unused but kept to avoid breaking consumers if any)
  final ValueNotifier<String?> backgroundStatus = ValueNotifier(null);

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
        
        // Step 1: Fast Start - Load first 500 items immediately
        // This puts pixels on the screen in <1 sec so the app feels responsive.
        final int firstBatchSize = 500;
        final int initialFetch = totalCount < firstBatchSize ? totalCount : firstBatchSize;
        
        _allAssets = await _paths.first.getAssetListRange(start: 0, end: initialFetch);
        _groupAssets();
        
        _isLoading = false;
        notifyListeners(); // UI is now visible/interactive with recent photos

        // Step 2: Background Load - Fetch the REST of the library
        // We do this in one big chunk (or large chunks) to minimize "scrollbar jumping".
        // It will update only once more after the complete library is ready.
        if (totalCount > initialFetch) {
           _fetchRemainingAssets(initialFetch, totalCount);
        }
      } else {
        _isLoading = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error fetching assets: $e");
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _fetchRemainingAssets(int startIndex, int totalCount) async {
    // Optimization: Fetch everything else in ONE go.
    // This blocks the background thread for a bit, but ensures the UI only "jumps" ONCE.
    // If the library is HUGE (>20k), we might want to split, but for 5-10k, one shot is cleaner.
    int end = totalCount;
    
    try {
      final chunk = await _paths.first.getAssetListRange(start: startIndex, end: end);
      if (chunk.isNotEmpty) {
         _allAssets.addAll(chunk);
         _groupAssets();
         notifyListeners();
      }
    } catch (e) {
      debugPrint("Error fetching remaining assets: $e");
    }
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
