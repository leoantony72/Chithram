import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../models/photo_group.dart';
import '../services/backup_service.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import 'package:exif/exif.dart';

import '../models/gallery_item.dart';
import '../models/remote_image.dart';

class PhotoProvider with ChangeNotifier {
  List<AssetPathEntity> _paths = [];
  List<AssetEntity> _allAssets = [];
  List<RemoteImage> _remoteImages = []; 
  List<Map<String, dynamic>> _remoteAlbums = []; 

  // Combined List
  List<GalleryItem> _allItems = [];
  
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
  List<RemoteImage> get remoteImages => _remoteImages;
  List<Map<String, dynamic>> get remoteAlbums => _remoteAlbums;
  List<GalleryItem> get allItems => _allItems;
  
  List<PhotoGroup> get groupedByDay => _groupedByDay;
  List<PhotoGroup> get groupedByMonth => _groupedByMonth;
  List<PhotoGroup> get groupedByYear => _groupedByYear;

  Map<String, latlong.LatLng> get locationCache => _locationCache;
  bool get isLocationScanning => _isLocationScanning;
  double get locationScanProgress => _locationScanProgress;
  
  bool get hasPermission => _hasPermission;
  bool get isLoading => _isLoading;
  
  Future<void> fetchRemotePhotos() async {
    final session = await AuthService().loadSession();
    if (session != null) {
      final username = session['username'] as String;
      debugPrint("PhotoProvider: Fetching remote photos for $username...");
      
      List<RemoteImage> allRemoteImages = [];
      String? currentCursor;
      bool hasMore = true;

      while (hasMore) {
        final imgResponse = await BackupService().fetchRemoteImages(username, cursor: currentCursor);
        if (imgResponse != null) {
          allRemoteImages.addAll(imgResponse.images);
          currentCursor = imgResponse.nextCursor;
          hasMore = imgResponse.nextCursor != null && imgResponse.nextCursor!.isNotEmpty;
          
          // Optionally update sync cursor
          if (imgResponse.nextCursor != null) {
             await DatabaseService().setBackupSetting('last_remote_sync', imgResponse.nextCursor!);
          }
        } else {
          debugPrint("PhotoProvider: Failed to fetch remote images page.");
          hasMore = false;
        }
      }

      debugPrint("PhotoProvider: Received ${allRemoteImages.length} total remote images.");
      _remoteImages = allRemoteImages;

      // Fetch Albums
      debugPrint("PhotoProvider: Fetching remote albums...");
      _remoteAlbums = await BackupService().fetchAlbums(username);
      debugPrint("PhotoProvider: Received ${_remoteAlbums.length} remote albums.");

      // Re-group with new data
      _groupAssets();
      notifyListeners();
    } else {
      debugPrint("PhotoProvider: Cannot fetch remote photos - No session found.");
    }
  }

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    try {
      final session = await AuthService().loadSession();
      if (session == null) return;
      final username = session['username'] as String;

      // 1. Local Refresh
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
         _hasPermission = await PhotoManager.requestPermissionExtend().then((ps) => ps.isAuth);
         await fetchAssets();
      } else if (!kIsWeb && Platform.isWindows) {
         _hasPermission = true;
         await fetchAssets();
      } else {
         await fetchRemotePhotos();
      }

      // If we want TRUE incremental sync for Pull-to-Refresh:
      final lastSync = await DatabaseService().getBackupSetting('last_remote_sync') ?? '';
      final syncResponse = await BackupService().syncImages(username, lastSync);

      if (syncResponse != null && syncResponse.updates.isNotEmpty) {
          // Merge updates (highly simplified: just append for now, or replace by ID)
          final Map<String, RemoteImage> map = { for (var e in _remoteImages) e.imageId : e };
          for (var up in syncResponse.updates) {
             map[up.imageId] = up; 
          }
          _remoteImages = map.values.toList();
          
          if (syncResponse.nextCursor != null) {
             await DatabaseService().setBackupSetting('last_remote_sync', syncResponse.nextCursor!);
          }
          
          _groupAssets();
          notifyListeners();
      }
    } catch (e) {
      debugPrint("Refresh Error: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> checkPermission() async {
    if (kIsWeb) {
      _hasPermission = true;
      await fetchAssets();
      notifyListeners();
      return;
    }
    // Platform check is safe here because we returned if kIsWeb
    if (Platform.isWindows) {
      _hasPermission = true;
      await fetchAssets();
      notifyListeners();
      return;
    }

    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth) {
      _hasPermission = true;
      var status = await Permission.accessMediaLocation.status;
      if (!status.isGranted) {
         await Permission.accessMediaLocation.request();
      }
    } else {
      _hasPermission = false;
    }
    
    await fetchAssets();
    notifyListeners();
  }
  
  Future<void> fetchAssets() async {
    _isLoading = true;
    _allAssets = [];
    notifyListeners();

    try {
      // Only attempt to fetch local assets on mobile platforms
      bool isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
      
      if (isMobile && _hasPermission) {
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
          notifyListeners(); 

          // Background Load rest
          if (totalCount > initialFetch) {
             await _fetchRemainingAssets(initialFetch, totalCount);
          }
           
           await startLocationScan(); 
        }
      } 
      
      // Always fetch remote photos regardless of platform or local assets
      await fetchRemotePhotos(); 

    } catch (e) {
      debugPrint("Error fetching assets: $e");
    } finally {
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
      // notifyListeners(); // Avoid too many updates
      
      startLocationScan();
      
    } catch (e) {
      debugPrint("Error fetching remaining assets: $e");
    }
  }

  // Update _groupAssets to merge and group
  void _groupAssets() {
    // Deduplication: Only show remote images that are NOT present locally
    final Set<String> localIds = _allAssets.map((e) => e.id).toSet();
    
    final List<RemoteImage> uniqueRemote = _remoteImages.where((remote) {
       // If sourceId matches a local asset ID, we skip the remote one (prefer local)
       if (remote.sourceId != null && localIds.contains(remote.sourceId)) {
          return false; 
       }
       return true;
    }).toList();

    // 1. Combine
    _allItems = [
      ..._allAssets.map((e) => GalleryItem.local(e)),
      ...uniqueRemote.map((e) => GalleryItem.remote(e))
    ];
    
    // 2. Sort DESC
    _allItems.sort((a, b) => b.date.compareTo(a.date));

    // 3. Group
    // Group by Day
    final Map<DateTime, List<GalleryItem>> dayGroups = groupBy(_allItems, (GalleryItem e) {
       return DateTime(e.date.year, e.date.month, e.date.day);
    });

    _groupedByDay = dayGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, items: entry.value);
    }).toList();
    _groupedByDay.sort((a, b) => b.date.compareTo(a.date));

    // Group by Month
    final Map<DateTime, List<GalleryItem>> monthGroups = groupBy(_allItems, (GalleryItem e) {
      return DateTime(e.date.year, e.date.month);
    });

    _groupedByMonth = monthGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, items: entry.value);
    }).toList();
    _groupedByMonth.sort((a, b) => b.date.compareTo(a.date));

    // Group by Year
    final Map<DateTime, List<GalleryItem>> yearGroups = groupBy(_allItems, (GalleryItem e) {
      return DateTime(e.date.year);
    });

    _groupedByYear = yearGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, items: entry.value);
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
             latlong.LatLng? pos;
             // 1. Try native
             final data = await asset.latlngAsync(); 
             if (data != null && (data.latitude != 0 || data.longitude != 0)) {
                pos = latlong.LatLng(data.latitude!, data.longitude!);
             }
             
             // 2. Windows Fallback (Read EXIF using dedicated package)
             if (pos == null && !kIsWeb && Platform.isWindows) {
                final file = await asset.file;
                if (file != null) {
                   final bytes = await file.readAsBytes();
                   final tags = await readExifFromBytes(bytes);
                   
                   if (tags.containsKey('GPS GPSLatitude') && tags.containsKey('GPS GPSLongitude')) {
                      final latValue = _parseExifDMS(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']?.toString());
                      final lonValue = _parseExifDMS(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']?.toString());
                      
                      if (latValue != null && lonValue != null) {
                        pos = latlong.LatLng(latValue, lonValue);
                      }
                   }
                }
             }

             if (pos != null) {
                _locationCache[asset.id] = pos;
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
    if (kIsWeb) return;
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
    if (kIsWeb) return;
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

  double? _parseExifDMS(IfdTag? tag, String? ref) {
    if (tag == null || tag.values is! List || tag.values.length < 3) return null;
    
    try {
      final values = tag.values.toList();
      double degrees = 0;
      double minutes = 0;
      double seconds = 0;

      // EXIF rational conversion
      if (values[0] is Ratio) {
        degrees = (values[0] as Ratio).toDouble();
      } else {
        degrees = double.parse(values[0].toString());
      }

      if (values[1] is Ratio) {
        minutes = (values[1] as Ratio).toDouble();
      } else {
        minutes = double.parse(values[1].toString());
      }

      if (values[2] is Ratio) {
        seconds = (values[2] as Ratio).toDouble();
      } else {
        seconds = double.parse(values[2].toString());
      }

      double decimal = degrees + (minutes / 60.0) + (seconds / 3600.0);
      
      if (ref == 'S' || ref == 'W') {
        decimal = -decimal;
      }
      return decimal;
    } catch (e) {
      return null;
    }
  }
}
