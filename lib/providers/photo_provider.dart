import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../models/photo_group.dart';

class PhotoProvider with ChangeNotifier {
  List<AssetPathEntity> _paths = [];
  List<AssetEntity> _allAssets = [];
  
  // Grouped data
  List<PhotoGroup> _groupedByDay = [];
  List<PhotoGroup> _groupedByMonth = [];
  List<PhotoGroup> _groupedByYear = [];
  
  // Location Data
  Map<String, latlong.LatLng> _locationCache = {};
  bool _isLocationScanning = false;
  double _locationScanProgress = 0.0;
  
  bool _hasPermission = false;
  bool _isLoading = false;
  
  // Expose status for UI
  final ValueNotifier<String?> backgroundStatus = ValueNotifier(null);

  List<AssetPathEntity> get paths => _paths;
  List<AssetEntity> get allAssets => _allAssets;
  
  List<PhotoGroup> get groupedByDay => _groupedByDay;
  List<PhotoGroup> get groupedByMonth => _groupedByMonth;
  List<PhotoGroup> get groupedByYear => _groupedByYear;
  
  Map<String, latlong.LatLng> get locationCache => _locationCache;
  bool get isLocationScanning => _isLocationScanning;
  double get locationScanProgress => _locationScanProgress;
  
  bool get hasPermission => _hasPermission;
  bool get isLoading => _isLoading;

  Future<void> checkPermission() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth) {
      _hasPermission = true;
      var status = await Permission.accessMediaLocation.status;
      if (!status.isGranted) {
         await Permission.accessMediaLocation.request();
      }
      
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
        imageOption: const FilterOption(
          needTitle: true,
          sizeConstraint: SizeConstraint(ignoreSize: true),
        ),
        orders: [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      );

      _paths = await PhotoManager.getAssetPathList(
        type: RequestType.common, 
        filterOption: option,
      );

      if (_paths.isNotEmpty) {
        final totalCount = await _paths.first.assetCountAsync;
        
        // Fast Start
        final int firstBatchSize = 500;
        final int initialFetch = totalCount < firstBatchSize ? totalCount : firstBatchSize;
        
        _allAssets = await _paths.first.getAssetListRange(start: 0, end: initialFetch);
        _groupAssets();
        
        _isLoading = false;
        notifyListeners(); 

        // Background Load rest
        if (totalCount > initialFetch) {
           _fetchRemainingAssets(initialFetch, totalCount);
        } else {
           startLocationScan(); 
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

  Future<void> _fetchRemainingAssets(int start, int total) async {
    try {
      const int outputChunk = 2000;
      
      int current = start;
      while (current < total) {
        final int nextFetch = (current + outputChunk < total) ? outputChunk : (total - current);
        final List<AssetEntity> more = await _paths.first.getAssetListRange(start: current, end: current + nextFetch);
        
        _allAssets.addAll(more);
        current += nextFetch;
      }
      
      _groupAssets();
      notifyListeners();
      
      startLocationScan();
      
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
    _groupedByDay.sort((a, b) => b.date.compareTo(a.date));

    // Group by Month
    final Map<DateTime, List<AssetEntity>> monthGroups = groupBy(_allAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year, e.createDateTime.month);
    });

    _groupedByMonth = monthGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    _groupedByMonth.sort((a, b) => b.date.compareTo(a.date));

    // Group by Year
    final Map<DateTime, List<AssetEntity>> yearGroups = groupBy(_allAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year);
    });

    _groupedByYear = yearGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    _groupedByYear.sort((a, b) => b.date.compareTo(a.date));
  }

  // --- LOCATION SCANNING LOGIC ---

  bool _locationScanStarted = false;

  Future<void> startLocationScan() async {
    if (_locationScanStarted || _allAssets.isEmpty) return;
    _locationScanStarted = true;
    
    await _loadLocationCache();
    
    // Identify what needs scanning (not in cache AND not available in native)
    final toScan = _allAssets.where((a) {
       if (_locationCache.containsKey(a.id)) return false;
       if ((a.latitude ?? 0) != 0) {
          _locationCache[a.id] = latlong.LatLng(a.latitude!, a.longitude!);
          return false;
       }
       return true; 
    }).toList();
    
    if (toScan.isEmpty) {
       _locationScanStarted = false;
       return; 
    }
    
    _isLocationScanning = true;
    _locationScanProgress = 0.0;
    notifyListeners();
    
    int processed = 0;
    bool needsSave = false;
    const int batchSize = 20;
    
    for (int i = 0; i < toScan.length; i += batchSize) {
       int end = (i + batchSize < toScan.length) ? i + batchSize : toScan.length;
       final batch = toScan.sublist(i, end);
       
       await Future.wait(batch.map((asset) async {
          try {
             final data = await asset.latlngAsync(); 
             if (data != null && (data.latitude != 0 || data.longitude != 0)) {
                _locationCache[asset.id] = latlong.LatLng(data.latitude!, data.longitude!);
                needsSave = true;
             }
          } catch(e) {
             // ignore
          }
       }));
       
       processed += batch.length;
       _locationScanProgress = processed / toScan.length;
       
       if (processed % 100 == 0) notifyListeners();
       
       if (needsSave && processed % 100 == 0) {
          await _saveLocationCache();
          needsSave = false;
       }
       
       // Yield to UI
       await Future.delayed(const Duration(milliseconds: 100));
    }
    
    if (needsSave) await _saveLocationCache();
    
    _isLocationScanning = false;
    _locationScanStarted = false;
    notifyListeners();
  }
  
  Future<void> _loadLocationCache() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/location_cache.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> json = jsonDecode(content);
        json.forEach((key, value) {
           if (value is Map) {
             _locationCache[key] = latlong.LatLng(value['lat'], value['lng']);
           }
        });
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Cache load error: $e");
    }
  }

  Future<void> _saveLocationCache() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/location_cache.json');
      final Map<String, dynamic> output = {};
      _locationCache.forEach((key, val) {
         output[key] = {'lat': val.latitude, 'lng': val.longitude};
      });
      await file.writeAsString(jsonEncode(output));
    } catch (e) {
      debugPrint("Cache save error: $e");
    }
  }
}
