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
import 'dart:math' as math;
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../models/photo_group.dart';
import '../services/backup_service.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/places_service.dart';
import '../services/thumbnail_cache.dart';
import '../services/api_config.dart';
import '../services/crypto_service.dart';
import '../services/model_service.dart';
import 'package:exif/exif.dart';
import 'package:system_info2/system_info2.dart';

import '../models/gallery_item.dart';
import '../models/remote_image.dart';
import '../services/semantic/semantic_service.dart';

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
  
  bool _isSemanticIndexing = false;
  double _semanticProgress = 0.0;
  int _semanticIndexedCount = 0;
  
  // Offline Hydration State
  bool _isOfflineHydrated = false;
  
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
  List<GalleryItem> get favoriteItems => _allItems.where((e) => e.isFavorite).toList();

  Map<String, latlong.LatLng> get locationCache => _locationCache;
  bool get isLocationScanning => _isLocationScanning;
  double get locationScanProgress => _locationScanProgress;
  
  bool get hasPermission => _hasPermission;
  bool get isLoading => _isLoading;
  bool get isJourneyProcessing => _isJourneyProcessing;
  double get journeyProgress => _journeyProgress;
  
  bool get isSemanticIndexing => _isSemanticIndexing;
  double get semanticProgress => _semanticProgress;
  int get semanticIndexedCount => _semanticIndexedCount;
  
  // Calculate total cloud bytes
  int get totalCloudStorageBytes {
    int sum = 0;
    for (var img in _remoteImages) {
      sum += img.size;
    }
    return sum;
  }
  
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
      await _groupAssets();
      await initSemanticStats();
      notifyListeners();
      // Now that _allItems is populated, kick off indexing if not already running
      startSemanticIndexing();
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
         await initSemanticStats();
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
      await initSemanticStats();
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
    await initSemanticStats();
    notifyListeners();
  }
  
  Future<void> fetchAssets({bool force = false}) async {
    _isLoading = true;
    if (force) {
      _allAssets = [];
      _allItems = [];
      _isOfflineHydrated = false;
    }
    notifyListeners();

    try {
      bool isDesktopOrMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows);
      
      if (isDesktopOrMobile && _hasPermission) {
         // Phase 1: SQLite HYDRATION
         final cachedIndex = await DatabaseService().getGalleryIndex(limit: 1000000, offset: 0);
         if (cachedIndex.isNotEmpty && !force) {
            
            // Offload heavy parsing & grouping to background isolate
            final parsedGroups = await compute(_parseAndGroupAssets, {
               'cachedIndex': cachedIndex,
               'remoteImages': _remoteImages.map((e) => e.toJson()).toList(), // pass serializable data
            });
            
            _allAssets = parsedGroups['allAssets'] as List<AssetEntity>;
            _allItems = parsedGroups['allItems'] as List<GalleryItem>;
            _groupedByDay = parsedGroups['day'] as List<PhotoGroup>;
            _groupedByMonth = parsedGroups['month'] as List<PhotoGroup>;
            _groupedByYear = parsedGroups['year'] as List<PhotoGroup>;
            
            _isOfflineHydrated = true;
            
            _isLoading = false; // Release UI lock instantly, full scrollbar rendered
            notifyListeners();
            
            // Warm up the RAM cache with the first 100 images so the initial viewport is instant
            if (_allAssets.isNotEmpty) {
                final int preloadCount = _allAssets.length > 100 ? 100 : _allAssets.length;
                ThumbnailCache().preCache(_allAssets.sublist(0, preloadCount));
            }
            
            await startLocationScan();
            _groupPlacesAsync(); // Fire places grouping async
         }
         
         // Phase 2: SILENT BACKGROUND OS SYNC
         _syncWithOS(force: force);
      } 
      
      await fetchRemotePhotos();
    } catch (e) {
      debugPrint("Error fetching assets: $e");
    } finally {
      if (!_isOfflineHydrated) {
         _isLoading = false;
         notifyListeners();
      }
    }
  }

  Future<void> _syncWithOS({bool force = false}) async {
    try {
        final FilterOptionGroup option = FilterOptionGroup(
          imageOption: const FilterOption(
            needTitle: true,
            sizeConstraint: SizeConstraint(ignoreSize: true),
          ),
          orders: [ OrderOption(type: OrderOptionType.createDate, asc: false) ],
        );

        _paths = await PhotoManager.getAssetPathList(type: RequestType.common, filterOption: option);
        notifyListeners();

        if (_paths.isNotEmpty) {
          final totalCount = await _paths.first.assetCountAsync;
          List<AssetEntity> backgroundLoadedEntities = [];
          
          if (totalCount > 0) {
             // If we didn't have a cache (first launch ever or cleared data)
             if (!_isOfflineHydrated) {
                // Fetch first 500 immediately to unblock the user's splash screen
                final int initialFetch = totalCount < 500 ? totalCount : 500;
                _allAssets = await _paths.first.getAssetListRange(start: 0, end: initialFetch);
                await _groupAssets();
                notifyListeners(); 
             }

             // Background: Cache ALL native OS items in SQLite so next launch is instant (limit memory during processing chunking)
             final sqliteCount = await DatabaseService().getGalleryIndexCount();
             
             // Check if the most recent asset ID has changed (heuristic for sync needed)
             String? latestIdInDb;
             if (sqliteCount > 0) {
               final firstItem = await DatabaseService().getGalleryIndex(limit: 1, offset: 0);
               if (firstItem.isNotEmpty) latestIdInDb = firstItem.first['id'];
             }
             final latestAssetId = (await _paths.first.getAssetListRange(start: 0, end: 1)).firstOrNull?.id;

             if (totalCount != sqliteCount || force || latestIdInDb != latestAssetId) {
                 // Fetch existing favorites to preserve them during re-index
                 final existingFavs = await DatabaseService().getFavoritesIds();
                 await DatabaseService().clearGalleryIndex();

                 // Chunk size prevents the Platform Channel from stuttering the main UI thread during sync
                 const int chunkSize = 1000;
                 int processed = 0;
                 
                 while (processed < totalCount) {
                    final int fetchC = (processed + chunkSize < totalCount) ? chunkSize : (totalCount - processed);
                    final entities = await _paths.first.getAssetListRange(start: processed, end: processed + fetchC);
                    if (!_isOfflineHydrated) {
                        backgroundLoadedEntities.addAll(entities);
                    }

                    final List<Map<String, dynamic>> cacheObjects = entities.map((e) => {
                        'id': e.id,
                        'title': e.title ?? '',
                        'type_int': e.typeInt,
                        'width': e.width,
                        'height': e.height,
                        'create_dt': e.createDateSecond,
                        'modify_dt': e.modifiedDateSecond,
                        'relative_path': '',
                        'is_favorite': existingFavs.contains(e.id) ? 1 : (e.isFavorite ? 1 : 0)
                    }).toList();

                    await DatabaseService().saveGalleryIndex(cacheObjects);
                    processed += fetchC;

                    // Yield to the event queue longer to let scroll frames render
                    await Future.delayed(const Duration(milliseconds: 30));
                 }
                 
                 // Re-group because the background sync might have added items
                 await _groupAssets();
                 notifyListeners();
             }
    
                 // If the UI was completely unhydrated on this run (First Launch), instantly hot-swap the UI to the full array to expand the scrollbar
                 if (!_isOfflineHydrated) {
                    _allAssets = backgroundLoadedEntities;
                    _isOfflineHydrated = true;
                    await _groupAssets();
                    notifyListeners();
                    await startLocationScan();
                    startSemanticIndexing();
                 }
                 
                 debugPrint("PhotoProvider: Fully cached $totalCount native OS images into SQLite offline index.");
             }
          }
    } catch (e) {
       debugPrint("Background OS Sync Error: $e");
    }
  }




  // Top-level function for compute() so 10,000 mapping operations don't freeze main thread
  static Map<String, dynamic> _parseAndGroupAssets(Map<String, dynamic> params) {
      final cachedIndex = params['cachedIndex'] as List<Map<String, dynamic>>;
      final remoteJson = params['remoteImages'] as List<dynamic>;
      
      final remoteImages = remoteJson.map((e) => RemoteImage.fromJson(e)).toList();
      
      final allAssets = cachedIndex.map((row) {
         return AssetEntity(
            id: row['id'] as String,
            typeInt: row['type_int'] as int,
            width: row['width'] as int,
            height: row['height'] as int,
            createDateSecond: row['create_dt'] as int,
            modifiedDateSecond: row['modify_dt'] as int,
            title: row['title'] as String?,
            // Avoid relativePath in compute to prevent platform channel checks locally inside mock
         );
      }).toList();

      final Set<String> localIds = allAssets.map((e) => e.id).toSet();
      final List<RemoteImage> uniqueRemote = remoteImages.where((remote) {
         if (remote.sourceId != null && localIds.contains(remote.sourceId)) {
            return false; 
         }
         return true;
      }).toList();

      final allItems = [
        ...allAssets.asMap().entries.map((entry) {
           final row = cachedIndex[entry.key];
           final isFav = (row['is_favorite'] ?? 0) == 1;
           return GalleryItem.local(entry.value, isFavorite: isFav);
        }),
        ...uniqueRemote.map((e) => GalleryItem.remote(e))
      ];
      
      allItems.sort((a, b) => b.date.compareTo(a.date));

      final Map<DateTime, List<GalleryItem>> dayGroups = {};
      final Map<DateTime, List<GalleryItem>> monthGroups = {};
      final Map<DateTime, List<GalleryItem>> yearGroups = {};

      for (var e in allItems) {
          final d = DateTime(e.date.year, e.date.month, e.date.day);
          final m = DateTime(e.date.year, e.date.month);
          final y = DateTime(e.date.year);
          dayGroups.putIfAbsent(d, () => []).add(e);
          monthGroups.putIfAbsent(m, () => []).add(e);
          yearGroups.putIfAbsent(y, () => []).add(e);
      }

      var dayList = dayGroups.entries.map((e) => PhotoGroup(date: e.key, items: e.value)).toList();
      var monthList = monthGroups.entries.map((e) => PhotoGroup(date: e.key, items: e.value)).toList();
      var yearList = yearGroups.entries.map((e) => PhotoGroup(date: e.key, items: e.value)).toList();

      dayList.sort((a, b) => b.date.compareTo(a.date));
      monthList.sort((a, b) => b.date.compareTo(a.date));
      yearList.sort((a, b) => b.date.compareTo(a.date));

      return {
         'allAssets': allAssets,
         'allItems': allItems,
         'day': dayList,
         'month': monthList,
         'year': yearList,
      };
  }

  // Update _groupAssets to merge and group
  Future<void> _groupAssets() async {
    // Deduplication: Only show remote images that are NOT present locally
    final Set<String> localIds = _allAssets.map((e) => e.id).toSet();
    
    final List<RemoteImage> uniqueRemote = _remoteImages.where((remote) {
       // If sourceId matches a local asset ID, we skip the remote one (prefer local)
       if (remote.sourceId != null && localIds.contains(remote.sourceId)) {
          return false; 
       }
       return true;
    }).toList();

    // Fetch favorites to overlay them onto the local assets
    final favIds = await DatabaseService().getFavoritesIds();

    // 1. Combine
    _allItems = [
      ..._allAssets.map((e) => GalleryItem.local(e, isFavorite: favIds.contains(e.id))),
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
          await _groupAssets();
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

  /// Toggles the favorite status of a photo (Local or Remote)
  Future<void> toggleFavorite(GalleryItem item) async {
    try {
      if (item.type == GalleryItemType.local) {
        final asset = item.local!;
        final bool newState = !asset.isFavorite;
        
        bool success = false;
        if (Platform.isIOS || Platform.isMacOS) {
          try {
            await PhotoManager.editor.darwin.favoriteAsset(
              favorite: newState,
              entity: asset,
            );
          } catch (e) {
             debugPrint("Native favorite failed: $e");
          }
        } 
        
        // Secondary persistence to our SQLite index for all platforms (Windows/Android fallback)
        await DatabaseService().updateFavoriteStatus(asset.id, newState);
        item.isFavorite = newState; // Update in-memory override
        success = true;
        
        if (success) {
           notifyListeners();
        }
      } else {
        // Remote
        final remote = item.remote!;
        final bool newState = !remote.isFavorite;
        
        // Update in-memory state
        for (int i = 0; i < _remoteImages.length; i++) {
          if (_remoteImages[i].imageId == remote.imageId) {
            final old = _remoteImages[i];
            _remoteImages[i] = RemoteImage(
              imageId: old.imageId,
              userId: old.userId,
              album: old.album,
              width: old.width,
              height: old.height,
              size: old.size,
              latitude: old.latitude,
              longitude: old.longitude,
              originalUrl: old.originalUrl,
              thumb256Url: old.thumb256Url,
              thumb64Url: old.thumb64Url,
              sourceId: old.sourceId,
              createdAt: old.createdAt,
              isDeleted: old.isDeleted,
              isFavorite: newState,
            );
            break;
          }
        }
        await _groupAssets();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error toggling favorite: $e");
    }
  }
  // --- Semantic Indexing & Search ---

  final SemanticService _semanticService = SemanticService();

  Future<void> initSemanticStats() async {
    if (_allItems.isEmpty) return;
    
    final indexedCount = await DatabaseService().getSemanticIndexedCount();
    final indexableItems = _allItems.where((item) => 
        item.type == GalleryItemType.local || item.type == GalleryItemType.remote
    ).length;
    
    _semanticIndexedCount = indexedCount;
    if (indexableItems > 0) {
      _semanticProgress = (indexedCount / indexableItems).clamp(0.0, 1.0);
    }
    notifyListeners();
  }

  Future<void> startSemanticIndexing() async {
    debugPrint("PhotoProvider: startSemanticIndexing called. _isSemanticIndexing: $_isSemanticIndexing, _allItems length: ${_allItems.length}");
    if (_isSemanticIndexing || _allItems.isEmpty) {
      debugPrint("PhotoProvider: startSemanticIndexing aborted (already indexing or empty list)");
      return;
    }
    
    _isSemanticIndexing = true;
    _semanticProgress = 0.0;
    notifyListeners();

    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        debugPrint("PhotoProvider: Ensuring models are downloaded for mobile...");
        final modelsReady = await ModelService().ensureModelsDownloaded();
        if (!modelsReady) {
          debugPrint("PhotoProvider: Model download failed. Aborting semantic indexing.");
          _isSemanticIndexing = false;
          notifyListeners();
          return;
        }
      }
      
      await _semanticService.initialize();
      
      final indexableItems = _allItems.where((item) => 
        item.type == GalleryItemType.local || item.type == GalleryItemType.remote
      ).toList();
      debugPrint("PhotoProvider: Total indexable items: ${indexableItems.length}");
      
      // Batch fetch already indexed IDs to avoid individual DB queries in loop
      Set<String> indexedIds = await DatabaseService().getAllSemanticIndexedIds();
      debugPrint("PhotoProvider: Already indexed count from DB: ${indexedIds.length}");

      // --- Embedding Schema Version Check ---
      // v1 = old wrong OpenAI CLIP normalization (mean/std subtraction)
      // v2 = correct MobileCLIP2 S0 normalization (pixel/255 only)
      // v3 = MobileCLIP2-S2 upgrade + surgical ArgMax fix + thumbnail-based indexing
      // If version is missing or stale, wipe and re-index from scratch.
      const String embeddingVersion = '3';
      final storedVersion = await DatabaseService().getBackupSetting('embedding_version');
      if (storedVersion != embeddingVersion && indexedIds.isNotEmpty) {
        debugPrint("PhotoProvider: Embedding version mismatch (stored=$storedVersion, expected=$embeddingVersion). Clearing stale embeddings and re-indexing.");
        await DatabaseService().clearSemanticEmbeddings();
        indexedIds = {};
      }
      if (storedVersion != embeddingVersion) {
        await DatabaseService().setBackupSetting('embedding_version', embeddingVersion);
      }

      int processed = 0;
      int newlyIndexed = 0;
      _semanticIndexedCount = indexedIds.length;

      // --- Adaptive Memory Budget ---
      // Calculate the desired processing speed based on device RAM.
      // Re-evaluated every 25 images so it can speed up if user frees RAM
      // or slow down if memory gets tight.
      int indexingDelayMs = _getIndexingBudget();
      debugPrint("PhotoProvider: Initial indexing budget: ${indexingDelayMs}ms delay per image.");

      // Prepare cloud decryption if needed
      SecureKey? masterKey;
      String? userId;
      if (indexableItems.any((i) => i.type == GalleryItemType.remote)) {
        final session = await AuthService().loadSession();
        if (session != null) {
          userId = session['username'] as String;
          final masterKeyBytes = session['masterKey'] as Uint8List;
          masterKey = SecureKey.fromList(CryptoService().sodium, masterKeyBytes);
        }
      }

      for (var item in indexableItems) {
        if (!_isSemanticIndexing) break; // Allow stopping
        
        if (indexedIds.contains(item.id)) {
          processed++;
          continue;
        }

        Uint8List? imageBytes;
        
        if (item.type == GalleryItemType.local) {
          // Optimization: Use 512px thumbnail instead of full file.
          // This is much faster and prevents OOM on large JPEGs.
          try {
            imageBytes = await item.local?.thumbnailDataWithOption(
              const ThumbnailOption(
                size: ThumbnailSize(512, 512),
                quality: 85,
              ),
            );
          } catch (e) {
            debugPrint('PhotoProvider: Thumbnail fetch failed for ${item.id}: $e');
            // Fallback to full file if thumbnail fails
            final file = await item.local?.file;
            if (file != null && await file.exists()) {
              imageBytes = await file.readAsBytes();
            }
          }
        } else if (item.type == GalleryItemType.remote && item.remote != null && masterKey != null && userId != null) {
          // Use backend proxy instead of direct MinIO presigning to avoid hostname signature mismatches (403s).
          // The Go server fetches from MinIO internally using its local address.
          final proxyUrl = '${ApiConfig().baseUrl}/images/download/${item.id}?user_id=$userId&variant=thumb_256';
          try {
            imageBytes = await BackupService().fetchAndDecryptFromUrl(proxyUrl, masterKey);
          } catch (e) {
            debugPrint('PhotoProvider: Proxy fetch failed for ${item.id}: $e');
          }
        }

        if (imageBytes != null && imageBytes.isNotEmpty) {
          debugPrint("PhotoProvider: Generating embedding for ${item.id} (${item.type})");
          final embedding = await _semanticService.generateImageEmbeddingFromBytes(imageBytes);
          if (embedding.isNotEmpty) {
            await DatabaseService().saveSemanticEmbedding(item.id, embedding);
            newlyIndexed++;
            _semanticIndexedCount++;
            debugPrint("PhotoProvider: Successfully indexed ${item.id}. Count: $_semanticIndexedCount");
          } else {
            debugPrint("PhotoProvider: Embedding generation failed/returned empty for ${item.id}");
          }
        } else {
           debugPrint("PhotoProvider: imageBytes null or empty for ${item.id}");
        }
        
        processed++;
        _semanticProgress = processed / indexableItems.length;
        if (processed % 10 == 0 || newlyIndexed % 5 == 0) notifyListeners();
        
        // Re-evaluate memory budget every 25 processed images so the loop
        // can speed up if the user frees RAM, or throttle if memory gets tight.
        if (processed % 25 == 0) {
          final int newBudget = _getIndexingBudget();
          if (newBudget != indexingDelayMs) {
            debugPrint("PhotoProvider: Memory budget updated: ${indexingDelayMs}ms → ${newBudget}ms.");
            indexingDelayMs = newBudget;
          }
        }
        
        // Yield — delay is dynamically adjusted by memory budget
        if (indexingDelayMs > 0) {
          await Future.delayed(Duration(milliseconds: indexingDelayMs));
        } else {
          await Future.delayed(Duration.zero);
        }
      }
      
      debugPrint("Semantic Indexing Complete. Total indexed: $_semanticIndexedCount. Newly indexed: $newlyIndexed.");
    } catch (e) {
      debugPrint("Semantic Indexing Error: $e");
    } finally {
      _isSemanticIndexing = false;
      notifyListeners();
    }
  }

  Future<List<GalleryItem>> performSemanticSearch(String query) async {
    if (query.trim().isEmpty) return [];
    
    try {
      // CLIP Prompt Engineering: Use "a photo of X" template to match training distribution.
      // MobileCLIP2 was trained on image captions — this single template consistently
      // outperforms raw keyword queries without adding extra inference cost.
      final promptedQuery = 'a photo of ${query.trim().toLowerCase()}';
      final queryEmbedding = await _semanticService.generateTextEmbedding(promptedQuery);
      debugPrint("SemanticSearch: Query='$query' → prompted='$promptedQuery' size=${queryEmbedding.length}");
      if (queryEmbedding.isEmpty) {
        debugPrint("SemanticSearch: Text embedding empty — model may not be loaded.");
        return [];
      }

      // Log actual DB row count — should be > 0 after indexing completes
      final dbCount = await DatabaseService().getSemanticIndexedCount();
      debugPrint("SemanticSearch: DB has $dbCount indexed embeddings.");

      // minScore: 0.0, limit: 20 — always return top-20 most relevant photos.
      // MobileCLIP2 S0 scores typically land in 0.20–0.26; a hard threshold
      // would be too fragile. Top-N ranking is more robust for a small model.
      final results = await DatabaseService().searchSemantic(queryEmbedding, minScore: 0.0, limit: 20);
      debugPrint("SemanticSearch: DB returned ${results.length} raw results.");
      if (results.isNotEmpty) {
        final scoreLog = results.take(5).map((r) => (r['score'] as double).toStringAsFixed(3)).join(', ');
        debugPrint("SemanticSearch: Top 5 scores: [$scoreLog]");
      }

      // Relative threshold: only keep results within 0.04 of the top score.
      // This filters weak/irrelevant matches (e.g. manga for "red dress") without
      // needing a hard absolute cutoff that varies per model/query.
      final List<Map<String, dynamic>> filteredResults;
      if (results.isEmpty) {
        filteredResults = [];
      } else {
        final double topScore = results.first['score'] as double;
        final double cutoff = topScore - 0.04;
        filteredResults = results.where((r) => (r['score'] as double) >= cutoff).take(15).toList();
        debugPrint("SemanticSearch: After relative filter (top-0.04=$cutoff): ${filteredResults.length} results remain.");
      }

      final Map<String, GalleryItem> itemsMap = {
        for (var item in _allItems) item.id: item
      };
      debugPrint("SemanticSearch: _allItems has ${itemsMap.length} items to match against.");

      final List<GalleryItem> matchedItems = [];
      int missCount = 0;
      for (var res in filteredResults) {
        final id = res['id'] as String;
        if (itemsMap.containsKey(id)) {
          matchedItems.add(itemsMap[id]!);
        } else {
          missCount++;
        }
      }
      debugPrint("SemanticSearch: Found ${matchedItems.length} matches, $missCount IDs not in _allItems.");

      return matchedItems;
    } catch (e) {
      debugPrint("Semantic Search Error: $e");
      return [];
    }
  }


  /// Reads the truly available memory on Android/Linux by parsing `MemAvailable`
  /// from `/proc/meminfo`. Unlike `MemFree`, `MemAvailable` includes reclaimable
  /// page cache — it matches what Android reports as "available RAM" in Settings.
  int _getAvailableMemoryMb() {
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isLinux)) {
        final meminfo = File('/proc/meminfo').readAsStringSync();
        int? availKb;
        int? totalKb;
        for (final line in meminfo.split('\n')) {
          if (line.startsWith('MemAvailable:')) {
            availKb = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '');
          } else if (line.startsWith('MemTotal:')) {
            totalKb = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '');
          }
          if (availKb != null && totalKb != null) break;
        }
        if (availKb != null) return availKb ~/ 1024; // kB → MB
      }
    } catch (_) {}
    // Fallback for non-Android platforms
    return SysInfo.getFreePhysicalMemory() ~/ (1024 * 1024);
  }

  /// Calculates a per-image delay in milliseconds based on the device's total and available RAM.
  ///
  /// Uses `MemAvailable` from `/proc/meminfo` on Android (not `MemFree`) so that
  /// reclaimable page cache is correctly counted as usable memory.
  int _getIndexingBudget() {
    try {
      final int totalBytes = SysInfo.getTotalPhysicalMemory();
      final double totalMb = totalBytes / (1024 * 1024);
      final double availMb = _getAvailableMemoryMb().toDouble();
      final double availRatio = totalMb > 0 ? availMb / totalMb : 0;

      debugPrint("PhotoProvider: Memory Budget — Total: ${totalMb.toStringAsFixed(0)}MB, "
                 "Available: ${availMb.toStringAsFixed(0)}MB (${(availRatio * 100).toStringAsFixed(0)}%)");

      // Critically low available RAM — throttle hard
      if (availMb < 300 || availRatio < 0.10) {
        debugPrint("PhotoProvider: Memory Budget — CRITICAL. Throttling heavily (2000ms).");
        return 2000;
      }
      if (availMb < 600 || availRatio < 0.20) {
        debugPrint("PhotoProvider: Memory Budget — LOW. Throttling moderately (750ms).");
        return 750;
      }

      // Scale primarily on total RAM (device tier)
      if (totalMb >= 8192) {
        debugPrint("PhotoProvider: Memory Budget — HIGH-END device. Full speed (0ms delay).");
        return 0;
      } else if (totalMb >= 4096) {
        debugPrint("PhotoProvider: Memory Budget — MID-HIGH device. Fast speed (10ms delay).");
        return 10;
      } else if (totalMb >= 2048) {
        debugPrint("PhotoProvider: Memory Budget — MID device. Normal speed (50ms delay).");
        return 50;
      } else if (totalMb >= 1024) {
        debugPrint("PhotoProvider: Memory Budget — LOW-MID device. Reduced speed (250ms delay).");
        return 250;
      } else {
        debugPrint("PhotoProvider: Memory Budget — LOW-END device. Careful speed (1000ms delay).");
        return 1000;
      }
    } catch (e) {
      debugPrint("PhotoProvider: Memory Budget — Failed to read system info. Using safe default (100ms).");
      return 100;
    }
  }
}
