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
import '../services/places_service.dart';
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
  bool _isJourneyProcessing = false;
  double _journeyProgress = 0.0;
  
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
  bool get isJourneyProcessing => _isJourneyProcessing;
  double get journeyProgress => _journeyProgress;
  
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
          // Merge updates or remove soft-deleted ones
          final Map<String, RemoteImage> map = { for (var e in _remoteImages) e.imageId : e };
          for (var up in syncResponse.updates) {
             if (up.isDeleted) {
                map.remove(up.imageId);
             } else {
                map[up.imageId] = up; 
             }
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

    // 4. Group by Place (Async due to Geocoding)
    _groupPlacesAsync();
  }

  Map<String, List<GalleryItem>> _placesVisited = {};
  Map<String, List<GalleryItem>> get placesVisited => _placesVisited;

  int _journeyProcessingId = 0;

  Future<void> _groupPlacesAsync() async {
    final int processId = ++_journeyProcessingId;
    _isJourneyProcessing = true;
    _journeyProgress = 0.0;
    notifyListeners();
    
    try {
      final cacheObj = await DatabaseService().getJourneyCache();
    if (cacheObj != null) {
      try {
        final Map<String, dynamic> parsed = jsonDecode(cacheObj['data']);
        final Map<String, List<GalleryItem>> tempPlaces = {};
        
        final Map<String, GalleryItem> itemsMap = {
          for (var item in _allItems) item.id: item
        };

        for (var city in parsed.keys) {
          final List<dynamic> idList = parsed[city];
          final List<GalleryItem> matched = [];
          for (var id in idList) {
            if (itemsMap.containsKey(id)) {
               matched.add(itemsMap[id]!);
            }
          }
          if (matched.isNotEmpty) {
             tempPlaces[city] = matched;
          }
        }
        
        // Apply custom covers
        for (var city in tempPlaces.keys) {
          final customCoverId = await DatabaseService().getJourneyCover(city);
          if (customCoverId != null) {
            final photos = tempPlaces[city]!;
            final coverIndex = photos.indexWhere((item) => item.id == customCoverId);
            if (coverIndex > 0) {
               final coverItem = photos.removeAt(coverIndex);
               photos.insert(0, coverItem);
            }
          }
        }
        
        // Anti-poison mechanism: If cache is completely empty but we have geotagged photos, ignore the cache
        final hasGeotaggedPhotos = _allItems.any((item) => 
            (item.type == GalleryItemType.local && ((item.local!.latitude ?? 0) != 0 || _locationCache.containsKey(item.local!.id))) || 
            (item.type == GalleryItemType.remote && item.remote!.latitude != 0)
        );

        if (tempPlaces.isEmpty && hasGeotaggedPhotos) {
            debugPrint("Cache is empty but geotagged photos exist. Ignoring cache and recalculating.");
            await DatabaseService().invalidateJourneyCache();
            // Do NOT return here. Let it fall through to the recalculation loop.
        } else {
            _placesVisited = tempPlaces;
            _journeyProgress = 1.0;
            
            if (processId == _journeyProcessingId) {
               _isJourneyProcessing = false;
               notifyListeners();
            }
            return;
        }
      } catch (e) {
        debugPrint("Error reading journey cache: $e");
      }
    }

    final Map<String, List<GalleryItem>> tempPlaces = {};
    
    // Group by coordinate first to minimize Geocoding API lookups
    final Map<String, List<GalleryItem>> coordGroups = {};

    for (var item in _allItems) {
       latlong.LatLng? loc;
       if (item.type == GalleryItemType.local) {
          loc = _locationCache[item.local!.id];
          if (loc == null && (item.local!.latitude ?? 0) != 0) {
             loc = latlong.LatLng(item.local!.latitude!, item.local!.longitude!);
          }
       } else if (item.type == GalleryItemType.remote) {
          if (item.remote!.latitude != 0) {
             loc = latlong.LatLng(item.remote!.latitude, item.remote!.longitude);
          }
       }

       if (loc != null) {
          // Use coordinate rounded to 2 decimal places to bucket nearby photos
          final String cacheKey = '${loc.latitude.toStringAsFixed(2)}_${loc.longitude.toStringAsFixed(2)}';
          if (!coordGroups.containsKey(cacheKey)) {
             coordGroups[cacheKey] = [];
          }
          coordGroups[cacheKey]!.add(item);
       }
    }

    int processedCount = 0;
    final totalSteps = coordGroups.keys.length;
    final keysToProcess = coordGroups.keys.toList();
    bool hasApiError = false;

    for (int i = 0; i < totalSteps; i++) {
       if (processId != _journeyProcessingId) return; // Cancelled by newer run

       final key = keysToProcess[i];
       final items = coordGroups[key]!;
       
       // Just pick the location of the first item in the group
       latlong.LatLng? groupLoc;
       final firstItem = items.first;
       if (firstItem.type == GalleryItemType.local) {
          groupLoc = _locationCache[firstItem.local!.id] ?? latlong.LatLng(firstItem.local!.latitude!, firstItem.local!.longitude!);
       } else {
          groupLoc = latlong.LatLng(firstItem.remote!.latitude, firstItem.remote!.longitude);
       }

       try {
         final place = await PlacesService().getPlaceName(groupLoc.latitude, groupLoc.longitude);
         if (place != null) {
            if (!tempPlaces.containsKey(place.city)) {
               tempPlaces[place.city] = [];
            }
            tempPlaces[place.city]!.addAll(items);
         }
       } catch (e) {
         hasApiError = true;
         print("Geocoding API block hit - will not cache incomplete results");
       }
       
       processedCount++;
       _journeyProgress = processedCount / (totalSteps > 0 ? totalSteps : 1);
       notifyListeners();

       // Small delay to prevent rate limit blocks on nominatim if we do actual requests
       await Future.delayed(const Duration(milliseconds: 50));
    }

    if (processId != _journeyProcessingId) return;

    // Sort items by date within each place
    for (var city in tempPlaces.keys) {
      tempPlaces[city]!.sort((a, b) => b.date.compareTo(a.date));
    }

    if (!hasApiError) {
      // Save to Cache ONLY if we successfully checked everything
      final Map<String, List<String>> toCache = {};
      tempPlaces.forEach((city, list) {
         toCache[city] = list.map((e) => e.id).toList();
      });
      await DatabaseService().saveJourneyCache(jsonEncode(toCache));
    }

    // Apply custom covers from database
    for (var city in tempPlaces.keys) {
      final customCoverId = await DatabaseService().getJourneyCover(city);
      if (customCoverId != null) {
        final photos = tempPlaces[city]!;
        final coverIndex = photos.indexWhere((item) => item.id == customCoverId);
        if (coverIndex > 0) { // If it exists and isn't already first
           final coverItem = photos.removeAt(coverIndex);
           photos.insert(0, coverItem);
        }
      }
    }

    _placesVisited = tempPlaces;

    } finally {
      if (processId == _journeyProcessingId) {
        _isJourneyProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<void> setJourneyCover(String city, GalleryItem coverItem) async {
     await DatabaseService().setJourneyCover(city, coverItem.id);
     // Re-run grouping to apply the new cover sorting
     await _groupPlacesAsync();
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

  // --- Multi-Select Deletion Logic ---
  
  /// Smartly handles deleting local and remote images, including prompting the user.
  Future<void> deleteSelectedPhotos(BuildContext context, List<GalleryItem> selectedItems) async {
    if (selectedItems.isEmpty) return;

    final session = await AuthService().loadSession();
    final username = session?['username'] as String?;

    final List<GalleryItem> localOnly = [];
    final List<GalleryItem> remoteOnly = [];
    final List<GalleryItem> mixedSync = [];

    // Analyze selection topology
    final Set<String> localIds = _allAssets.map((e) => e.id).toSet();
    
    for (final item in selectedItems) {
      if (item.type == GalleryItemType.remote) {
        // Technically pure remote
        remoteOnly.add(item);
      } else if (item.type == GalleryItemType.local) {
        // Find if this local asset ALSO exists on the cloud
        final bool existsInCloud = _remoteImages.any((r) => r.sourceId == item.id);
        if (existsInCloud && username != null) {
          mixedSync.add(item);
        } else {
          localOnly.add(item);
        }
      }
    }

    bool deleteFromCloud = true; // Default intent for remote-only items
    
    // Prompt the user if they are deleting mixed/synced items
    if (mixedSync.isNotEmpty) {
      final bool? result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Delete from Cloud?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text(
            '${mixedSync.length} of the selected photos are backed up to your cloud.\n\nDo you want to permanently delete them from the cloud as well, or keep them backed up and just remove them from this device?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false), // Keep in cloud
              child: const Text('Device Only', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => Navigator.pop(ctx, true), // Delete cloud
              child: const Text('Delete Everywhere'),
            ),
          ],
        ),
      );

      if (result == null) return; // User cancelled
      deleteFromCloud = result;
    } else if (localOnly.isNotEmpty && remoteOnly.isEmpty) {
        // Standard local deletion prompt
        final bool? result = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('Delete Photos?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              content: Text('Are you sure you want to delete ${localOnly.length} photos from your device?', style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete'),
                ),
              ],
            )
        );
        if (result != true) return;
    }

    // Execute Operations
    _isLoading = true;
    notifyListeners();

    try {
      // 1. MinIO Cloud Deletion (if applicable and logged in)
      final List<String> cloudIdsToDelete = [];
      if (username != null) {
        cloudIdsToDelete.addAll(remoteOnly.map((e) => e.remote!.imageId));
        
        if (deleteFromCloud) {
           for (final mixed in mixedSync) {
              final remoteRef = _remoteImages.firstWhereOrNull((r) => r.sourceId == mixed.id);
              if (remoteRef != null) cloudIdsToDelete.add(remoteRef.imageId);
           }
        }
        
        if (cloudIdsToDelete.isNotEmpty) {
           final success = await BackupService().deleteCloudImages(username, cloudIdsToDelete);
           if (success) {
              // Remove locally cached remote tracking
              _remoteImages.removeWhere((img) => cloudIdsToDelete.contains(img.imageId));
           }
        }
      }

      // 2. Local OS Deletion
      final List<String> localOsIdsToDelete = [];
      localOsIdsToDelete.addAll(localOnly.map((e) => e.id));
      localOsIdsToDelete.addAll(mixedSync.map((e) => e.id));

      if (localOsIdsToDelete.isNotEmpty && !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
         final deletedIds = await PhotoManager.editor.deleteWithIds(localOsIdsToDelete);
         // Update state variables for remaining assets
         _allAssets.removeWhere((asset) => deletedIds.contains(asset.id));
      } else if (localOsIdsToDelete.isNotEmpty && !kIsWeb && Platform.isWindows) {
         // Specialized windows deletion
         for (final asset in [...localOnly, ...mixedSync]) {
            try {
               final file = await asset.local?.file;
               if (file != null && await file.exists()) {
                  await file.delete();
               }
               _allAssets.removeWhere((a) => a.id == asset.id);
            } catch(e) { print('Failed deleting Windows file: $e'); }
         }
      }

      // Regroup and hydrate UI
      _groupAssets();
      
      // Explicitly remove from _allItems cache manually if any leaked past _groupAssets rebuilding
      final allDeletedIds = [
         ...cloudIdsToDelete,
         ...localOsIdsToDelete
      ];
      _allItems.removeWhere((item) => allDeletedIds.contains(item.id));

    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Bulk updates the map location coordinates for the selected items.
  Future<void> updateLocationForSelected(List<GalleryItem> selectedItems, double lat, double lng) async {
    if (selectedItems.isEmpty) return;
    
    _isLoading = true;
    notifyListeners();
    
    try {
       final session = await AuthService().loadSession();
       final username = session?['username'] as String?;
       
       if (username != null) {
          final List<String> cloudIdsToUpdate = [];
          for (final item in selectedItems) {
             if (item.type == GalleryItemType.remote) {
                cloudIdsToUpdate.add(item.remote!.imageId);
             } else if (item.type == GalleryItemType.local) {
                final cloudEquiv = _remoteImages.firstWhereOrNull((r) => r.sourceId == item.id);
                if (cloudEquiv != null) {
                   cloudIdsToUpdate.add(cloudEquiv.imageId);
                }
             }
          }
          
          if (cloudIdsToUpdate.isNotEmpty) {
             final success = await BackupService().updateCloudLocation(username, cloudIdsToUpdate, lat, lng);
             if (success) {
                // Update Runtime Cache
                for (int i = 0; i < _remoteImages.length; i++) {
                   if (cloudIdsToUpdate.contains(_remoteImages[i].imageId)) {
                      // Needs mutable mapping since we don't have copyWith
                      final old = _remoteImages[i];
                      _remoteImages[i] = RemoteImage(
                         imageId: old.imageId, userId: old.userId, album: old.album,
                         width: old.width, height: old.height, size: old.size,
                         latitude: lat, longitude: lng,
                         originalUrl: old.originalUrl, thumb256Url: old.thumb256Url, thumb64Url: old.thumb64Url,
                         sourceId: old.sourceId, createdAt: old.createdAt, isDeleted: old.isDeleted
                      );
                   }
                }
             }
          }
       }
       
       // Update Local Map Cache for instant UI feedback regardless of backend
       for (final item in selectedItems) {
          _locationCache[item.id] = latlong.LatLng(lat, lng);
       }
       
       await DatabaseService().invalidateJourneyCache();
       // Re-trigger Grouping to pass new props down
       _groupAssets();
    } catch (e) {
       print("Error updating locations: $e");
    } finally {
       _isLoading = false;
       notifyListeners();
    }
  }

  /// Moves selected items to the target album. 
  /// For Cloud items, simply changes the label.
  /// For Local items, performs a native OS Copy-then-Delete to simulate a move.
  Future<String?> addSelectedToAlbum(List<GalleryItem> selectedItems, AssetPathEntity? localTarget, String? cloudTarget) async {
     if (selectedItems.isEmpty) return null;
     if (localTarget == null && cloudTarget == null) return null;
     
     _isLoading = true;
     notifyListeners();
     
     try {
         final session = await AuthService().loadSession();
         final username = session?['username'] as String?;
         
         // 1. Process Cloud Items (if we have a cloud target and users are logged in)
         if (username != null && cloudTarget != null) {
            final List<String> cloudIdsToUpdate = [];
            for (final item in selectedItems) {
               if (item.type == GalleryItemType.remote) {
                  cloudIdsToUpdate.add(item.remote!.imageId);
               } else if (item.type == GalleryItemType.local) {
                  final cloudEquiv = _remoteImages.firstWhereOrNull((r) => r.sourceId == item.id);
                  if (cloudEquiv != null) {
                     cloudIdsToUpdate.add(cloudEquiv.imageId);
                  }
               }
            }
            
            if (cloudIdsToUpdate.isNotEmpty) {
               final success = await BackupService().updateCloudAlbum(username, cloudIdsToUpdate, cloudTarget);
               if (success) {
                  for (int i = 0; i < _remoteImages.length; i++) {
                     if (cloudIdsToUpdate.contains(_remoteImages[i].imageId)) {
                        final old = _remoteImages[i];
                        _remoteImages[i] = RemoteImage(
                           imageId: old.imageId, userId: old.userId, album: cloudTarget,
                           width: old.width, height: old.height, size: old.size,
                           latitude: old.latitude, longitude: old.longitude,
                           originalUrl: old.originalUrl, thumb256Url: old.thumb256Url, thumb64Url: old.thumb64Url,
                           sourceId: old.sourceId, createdAt: old.createdAt, isDeleted: old.isDeleted
                        );
                     }
                  }
               }
            }
         }
         
         // 2. Process Local OS Items (if we have an OS target)
         if (localTarget != null) {
            final List<AssetEntity> localAssets = [];
            for (final item in selectedItems) {
               if (item.type == GalleryItemType.local && item.local != null) {
                  localAssets.add(item.local!);
               }
            }
            
            if (localAssets.isNotEmpty && !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
               for (final asset in localAssets) {
                   // A true Move in OS MediaStores requires copying to target, then deleting original.
                   final copiedAsset = await PhotoManager.editor.copyAssetToPath(asset: asset, pathEntity: localTarget);
                   if (copiedAsset != null) {
                       // Delete original
                       await PhotoManager.editor.deleteWithIds([asset.id]);
                       // Remove old from our in-memory un-grouped cache
                       _allAssets.removeWhere((a) => a.id == asset.id);
                       // Add the new one so the grid doesn't blink out
                       _allAssets.insert(0, copiedAsset);
                   }
               }
            }
         }
         
         // Regroup UI
         _groupAssets();
         return null; // Success
     } catch (e) {
         print("Error adding to album: $e");
         final errStr = e.toString();
         if (errStr.contains("allowed directories are")) {
            return "Android OS restricts moving images to this folder. Please choose DCIM or Pictures.";
         }
         return "Failed to move photos: $errStr";
     } finally {
         _isLoading = false;
         notifyListeners();
     }
  }
}
