import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

class ThumbnailCache {
  static final ThumbnailCache _instance = ThumbnailCache._internal();
  factory ThumbnailCache() => _instance;
  ThumbnailCache._internal();

  // 300 MB Memory Cache Limit (Increased from 150MB to prevent thrashing on high-density 120Hz grids)
  final int _maxMemorySizeBytes = 300 * 1024 * 1024; 
  int _currentMemorySizeBytes = 0;

  final LinkedHashMap<String, Uint8List> _memoryCache = LinkedHashMap();
  final Set<String> _protectedIds = {};

  // Disk Cache
  Directory? _cacheDir;
  Directory? _convertedDir;
  final Set<String> _diskCacheKeys = {};
  bool _isInitialized = false;
  bool _isInitStarted = false;
  final Completer<void> _initCompleter = Completer<void>();

  // Init method to prepare disk directory and index
  Future<void> init() async {
    if (_isInitialized) return;
    
    if (_isInitStarted) {
       await _initCompleter.future;
       return;
    }
    
    _isInitStarted = true;

    try {
      if (kIsWeb) {
        _isInitialized = true;
        _initCompleter.complete();
        return;
      }
      final root = await getApplicationSupportDirectory();
      _cacheDir = Directory('${root.path}/thumbnails');
      _convertedDir = Directory('${root.path}/converted_highres');
      
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      if (!await _convertedDir!.exists()) {
        await _convertedDir!.create(recursive: true);
      }
      
      _isInitialized = true;
      _initCompleter.complete();
      debugPrint("ThumbnailCache initialized at: ${_cacheDir!.path}");
      
      // Load index immediately
      await _loadIndex();

    } catch (e) {
      debugPrint("ThumbnailCache init error: $e");
      _isInitStarted = false;
      _initCompleter.completeError(e);
    }
  }

  Future<void> _loadIndex() async {
     try {
       final indexFile = File('${_cacheDir!.path}/index.txt');
       if (await indexFile.exists()) {
           final lines = await indexFile.readAsLines();
           _diskCacheKeys.addAll(lines);
           debugPrint("Loaded usage index with ${_diskCacheKeys.length} items.");
       } else {
           _buildIndex();
       }
     } catch(e) {
        _buildIndex();
     }
  }

  Future<void> _buildIndex() async {
     try {
        if (_cacheDir == null) return;
        
        final indexFile = File('${_cacheDir!.path}/index.txt');
        final sink = indexFile.openWrite(); // Overwrite

        await for (final entity in _cacheDir!.list()) {
           if (entity is File && !entity.path.endsWith('index.txt')) {
             final filename = entity.uri.pathSegments.last;
             _diskCacheKeys.add(filename);
             sink.writeln(filename);
           }
        }
        await sink.close();
        debugPrint("Rebuilt disk index: ${_diskCacheKeys.length}");
     } catch (e) {
        debugPrint("Error building cache index: $e");
     }
  }
  
  // ... (getThumbnail omitted) ...

  // ... (getMemory/putMemory omitted) ...

  // ... (hasInDisk omitted) ...

  // ... (getDiskCacheSize omitted) ...


  
  /// Generates a full-resolution JPEG conversion on disk for unsupported native formats (HEIC, RAW)
  Future<File?> getConvertedHighResFile(AssetEntity entity) async {
    if (kIsWeb) return null;
    
    if (!_isInitialized) {
       await init();
    } else if (!_initCompleter.isCompleted) {
       await _initCompleter.future;
    }

    if (_convertedDir == null) return null;
    
    // Hash the ID to make a safe filename
    final safeName = base64Url.encode(utf8.encode(entity.id)).replaceAll('=', '') + '.jpg';
    final targetFile = File('${_convertedDir!.path}/$safeName');
    
    // 1. Check if already converted and cached on disk
    if (await targetFile.exists()) {
       return targetFile;
    }
    
    // 2. Not cached. Instruct photo_manager to tap into the OS decoders 
    // to extract the full resolution image natively as a pure JPEG byte sequence.
    try {
      debugPrint("extracting lossless JPEG for ${entity.id}...");
      final bytes = await entity.thumbnailDataWithSize(
         ThumbnailSize(entity.width, entity.height),
         quality: 100, // Lossless JPEG conversion
         format: ThumbnailFormat.jpeg,
      );
      
      if (bytes != null && bytes.isNotEmpty) {
        // 3. Write directly to disk to prevent RAM bloat
        await targetFile.writeAsBytes(bytes);
        return targetFile;
      }
    } catch (e) {
      debugPrint("Error performing lossless format conversion: $e");
    }
    return null;
  }
  
  // The main method widgets should use
  Future<Uint8List?> getThumbnail(AssetEntity entity) async {
    // 1. Memory Check (Fastest, Synchronous-like access)
    final memBytes = getMemory(entity.id);
    if (memBytes != null) return memBytes;

    // Ensure initialized
    if (!_isInitialized) {
       await init();
    } else if (!_initCompleter.isCompleted) {
       await _initCompleter.future;
    }

    // 2. Disk Check
    final file = _getFile(entity.id);
    if (await file.exists()) {
      try {
        final diskBytes = await file.readAsBytes();
        if (diskBytes.isNotEmpty) {
           putMemory(entity.id, diskBytes);
           // debugPrint("Disk HIT for ${entity.id}");
           return diskBytes;
        }
      } catch (e) {
        debugPrint("Error reading thumbnail from disk: $e");
      }
    } else {
        // debugPrint("Disk MISS for ${entity.id}");
    }

    // 3. Generate from System
    try {
      debugPrint("Generating thumbnail for ${entity.id}...");
      final bytes = await entity.thumbnailDataWithSize(
         const ThumbnailSize.square(150),
         quality: 60,
      );
      
      if (bytes != null) {
        // 4. Save to Memory and Disk
        putMemory(entity.id, bytes);
        // Fire and forget disk write to avoid blocking UI too much
        _saveToDisk(file, bytes); 
        return bytes;
      }
    } catch (e) {
       debugPrint("Error generating thumbnail: $e");
    }
    
    return null;
  }

  // Synchronous memory check
  Uint8List? getMemory(String id) {
    final bytes = _memoryCache[id];
    if (bytes != null) {
      // LRU Logic: Move to end
      _memoryCache.remove(id);
      _memoryCache[id] = bytes;
    }
    return bytes;
  }

  void putMemory(String id, Uint8List bytes) {
    if (_memoryCache.containsKey(id)) {
      _currentMemorySizeBytes -= _memoryCache[id]!.lengthInBytes;
      _memoryCache.remove(id);
    }

    _memoryCache[id] = bytes;
    _currentMemorySizeBytes += bytes.lengthInBytes;
    
    _evictMemoryIfNeeded();
  }

  bool hasInDisk(String id) {
    if (!_isInitialized) return false;
    final safeId = base64Url.encode(utf8.encode(id));
    return _diskCacheKeys.contains(safeId);
  }

  int get diskCacheCount => _diskCacheKeys.length;

  Future<int> getDiskCacheSize() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return 0;
    int totalSize = 0;
    try {
      await for (final entity in _cacheDir!.list()) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
    } catch (e) {
      debugPrint("Error calculating cache size: $e");
    }
    return totalSize;
  }

  Future<void> _saveToDisk(File file, Uint8List bytes) async {
    try {
      await file.writeAsBytes(bytes);
      final filename = file.uri.pathSegments.last;
      
      if (!_diskCacheKeys.contains(filename)) {
          _diskCacheKeys.add(filename);
          // Append to index file
          try {
             final indexFile = File('${_cacheDir!.path}/index.txt');
             await indexFile.writeAsString('$filename\n', mode: FileMode.append);
          } catch (_) {}
      }
    } catch (e) {
      debugPrint("Failed to write thumbnail to disk: $e");
    }
  }
  
  File _getFile(String id) {
    // Sanitize ID for filename using Base64
    final safeId = base64Url.encode(utf8.encode(id));
    return File('${_cacheDir!.path}/$safeId');
  }

  void _evictMemoryIfNeeded() {
    if (_currentMemorySizeBytes <= _maxMemorySizeBytes) return;

    final keysToRemove = <String>[];
    for (final entry in _memoryCache.entries) {
      if (_currentMemorySizeBytes <= _maxMemorySizeBytes) break;
      if (_protectedIds.contains(entry.key)) continue;

      keysToRemove.add(entry.key);
      _currentMemorySizeBytes -= entry.value.lengthInBytes;
    }

    for (final key in keysToRemove) {
      _memoryCache.remove(key);
    }
  }

  void clearMemory() {
    _memoryCache.clear();
    _currentMemorySizeBytes = 0;
  }
  
  Future<void> preCache(List<AssetEntity> assets) async {
    await init();
    
    int loaded = 0;
    for (final asset in assets) {
      // Mark as protected so they don't get evicted from memory
      _protectedIds.add(asset.id);
      
      // If already in memory, skip
      if (_memoryCache.containsKey(asset.id)) {
        loaded++;
        continue;
      }

      // Try load from disk directly to memory
      // This bypasses the full 'getThumbnail' logic to just warm up RAM
      final file = _getFile(asset.id);
      if (await file.exists()) {
          try {
             final bytes = await file.readAsBytes();
             if (bytes.isNotEmpty) {
                 putMemory(asset.id, bytes);
                 loaded++;
             }
          } catch (e) {
             debugPrint("Pre-cache error reading ${asset.id}: $e");
          }
      }
    }
    
    debugPrint("Pre-cached complete: $loaded/${assets.length} loaded into RAM.");
  }

  Future<void> clearDisk() async {
    if (_cacheDir != null && await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    _diskCacheKeys.clear();
  }

  Future<void> generateBatch(List<AssetEntity> assets) async {
    for (final asset in assets) {
      if (hasInDisk(asset.id)) continue;
      
      try {
        // Generate
        final bytes = await asset.thumbnailDataWithSize(
           const ThumbnailSize.square(150),
           quality: 60,
        );
        
        // Save to disk index
        if (bytes != null) {
          final file = _getFile(asset.id);
          await _saveToDisk(file, bytes);
          // Note: we DO NOT put it in memory cache here. 
          // We want the memory cache reserved for what the user is actually looking at.
        }
      } catch (e) {
         debugPrint("Bg gen error: $e");
      }
    }
  }
}
