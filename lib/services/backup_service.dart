import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:photo_manager/photo_manager.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:crypto/crypto.dart'; // Add crypto package
import 'package:image/image.dart' as img; // Handle thumbnails directly
import 'package:file_picker/file_picker.dart'; // Handle manual file picking
import '../models/remote_image.dart';
import 'database_service.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'api_config.dart';

import 'package:flutter/foundation.dart';

class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  final DatabaseService _db = DatabaseService();
  final AuthService _auth = AuthService();
  final CryptoService _crypto = CryptoService();
  
  bool _isBackupEnabled = false;
  List<String> _selectedAlbumIds = [];
  bool _isRunning = false;
  
  // URL Helper
  String get _baseUrl => ApiConfig().baseUrl;

  Uri _resolveUri(String url) {
    Uri uri = Uri.parse(url);
    if (kIsWeb) return uri;
    
    // If the URL points to localhost/127.0.0.1 but we are on a platform that needs the LAN IP
    if ((uri.host == '127.0.0.1' || uri.host == 'localhost')) {
       final base = _baseUrl;
       final baseUri = Uri.parse(base);
       if (baseUri.host != 'localhost' && baseUri.host != '127.0.0.1') {
          return uri.replace(host: baseUri.host);
       }
    }
    return uri;
  }

  // Initialize settings
  Future<void> init() async {
    final enabledStr = await _db.getBackupSetting('backup_enabled');
    _isBackupEnabled = enabledStr == 'true';
    
    final albumsStr = await _db.getBackupSetting('backup_albums');
    if (albumsStr != null) {
      try {
        _selectedAlbumIds = List<String>.from(jsonDecode(albumsStr));
      } catch (_) {}
    }
  }

  bool get isBackupEnabled => _isBackupEnabled;
  List<String> get selectedAlbumIds => _selectedAlbumIds;
  bool get isRunning => _isRunning;

  Future<void> toggleBackup(bool enabled) async {
    _isBackupEnabled = enabled;
    await _db.setBackupSetting('backup_enabled', enabled.toString());
    if (enabled) {
      startBackup();
    } else {
      _isRunning = false; // Graceful stop request
    }
  }

  Future<void> setSelectedAlbums(List<String> albumIds) async {
    _selectedAlbumIds = albumIds;
    await _db.setBackupSetting('backup_albums', jsonEncode(albumIds));
    if (_isBackupEnabled) {
      startBackup();
    }
  }

  Future<void> startBackup() async {
    if (_isRunning) return;
    if (!_isBackupEnabled) return;
    
    _isRunning = true;
    print('BackupService: Starting backup...');

    try {
      // 1. Get Session for keys
      final session = await _auth.loadSession();
      if (session == null) {
        print('BackupService: No session found (not logged in). Aborting.');
        _isRunning = false;
        return;
      }

      final username = session['username'] as String;
      final userId = username; // Assuming username is used as userId for now
      final masterKeyBytes = session['masterKey'] as Uint8List;
      
      // Recreate SecureKey from bytes
      final key = SecureKey.fromList(_crypto.sodium, masterKeyBytes);
      
      // 2. Fetch Cloud Source IDs and Checksums (Fast Deduplication)
      print('BackupService: Fetching existing metadata from cloud...');
      final cloudSourceIDs = await _fetchCloudSourceIDs(userId);
      final cloudChecksums = await _fetchCloudChecksums(userId);
      print('BackupService: Found ${cloudSourceIDs.length} source IDs and ${cloudChecksums.length} checksums in cloud.');

      // 3. Fetch Assets from selected albums
      if (_selectedAlbumIds.isEmpty) {
         print('BackupService: No albums selected.');
         _isRunning = false; 
         return; 
      }

      final Set<String> processedAssetIds = {};
      final Map<String, String> assetToAlbumName = {};
      final List<AssetEntity> assetsToBackup = [];

      final allAlbums = await PhotoManager.getAssetPathList(type: RequestType.common);
      
      for (var albumId in _selectedAlbumIds) {
          if (!_isBackupEnabled) break;
          try {
             final album = allAlbums.firstWhere((a) => a.id == albumId);
             final count = await album.assetCountAsync;
             
             for (int page = 0; page < (count / 50).ceil(); page++) {
                if (!_isBackupEnabled) break;
                final batch = await album.getAssetListPaged(page: page, size: 50);
                for (var asset in batch) {
                   if (processedAssetIds.contains(asset.id)) continue;
                   processedAssetIds.add(asset.id);
                   
                   final file = await asset.file;
                   if (file == null) continue;
                   if (await _db.isBackedUp(file.path)) continue;
                   
                   assetsToBackup.add(asset);
                   assetToAlbumName[asset.id] = album.name;
                }
             }
          } catch (e) {
             print('Error fetching album $albumId: $e');
          }
      }

      print('BackupService: Found ${assetsToBackup.length} pending files.');

      // 4. Process Uploads in Batches (Concurrency: 3)
      final int concurrency = 3;
      for (int i = 0; i < assetsToBackup.length; i += concurrency) {
         if (!_isBackupEnabled) break;

         final end = (i + concurrency < assetsToBackup.length) ? i + concurrency : assetsToBackup.length;
         final batch = assetsToBackup.sublist(i, end);
         
         await Future.wait(batch.map((asset) {
           final albumName = assetToAlbumName[asset.id];
           return _processSingleAsset(asset, userId, key, cloudSourceIDs, cloudChecksums, albumName: albumName);
         }));
         
         // Give UI loop a breather
         await Future.delayed(Duration.zero);
      }

    } catch (e) {
      print('BackupService Error: $e');
    } finally {
      _isRunning = false;
      print('BackupService: Backup run finished.');
    }
  }

  Future<void> _processSingleAsset(AssetEntity asset, String userId, SecureKey masterKey, Set<String> cloudSourceIDs, Set<String> cloudChecksums, {String? albumName}) async {
    try {
      final file = await asset.file;
      if (file == null) {
        print('BackupService: File is null for ${asset.id}');
        return;
      }

      // 1. Fast Deduplication (Metadata Check)
      if (cloudSourceIDs.contains(asset.id)) {
        print('BackupService: Skipping ${file.path} (Already on Cloud by ID)');
        await _db.logBackupStatus(file.path, 'UPLOADED');
        return;
      }
      
      // 2. Generate Checksum and Check Deduplication
      final fileBytes = await file.readAsBytes();
      final checksum = _calculateChecksum(fileBytes);
      
      if (cloudChecksums.contains(checksum)) {
        print('BackupService: Skipping ${file.path} (Already on Cloud by Checksum)');
        await _db.logBackupStatus(file.path, 'UPLOADED');
        // We might want to register this image with the new source_id too, but for simplicity we just skip
        return;
      }

      print('BackupService: Processing ${file.path}...');

      // 3. Generate ID (Only for new files)
      final imageId = _generateUUID();
      print('BackupService: Generated ID $imageId, Checksum $checksum');
      
      // 3. Generate Thumbnails
      print('BackupService: Generating thumbnails for $imageId...');
      final thumb256Bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(256, 256), quality: 80);
      final thumb64Bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(64, 64), quality: 60);

      // Note: If thumbnail generation fails for videos (e.g. MOV), we might want to skip or upload without thumbnails.
      // For now, valid requirement is thumbnails must exist.
      if (thumb256Bytes == null || thumb64Bytes == null) {
        print('BackupService: Failed to generate thumbnails for ${asset.id} (256: ${thumb256Bytes?.length}, 64: ${thumb64Bytes?.length})');
        return;
      }
      print('BackupService: Thumbnails generated. 256px: ${thumb256Bytes.length} bytes, 64px: ${thumb64Bytes.length} bytes.');
      
      // 4. Get Presigned URLs
      final variants = ['original', 'thumb_1024', 'thumb_256', 'thumb_64'];
      final urls = await _getUploadUrls(userId, imageId, variants);
      if (urls == null || urls.length != 4) {
        print('BackupService: Failed to get all upload URLs. Got: ${urls?.keys}');
        return;
      }
      print('BackupService: Received ${urls.length} upload URLs.');

      // 5. Encrypt and Upload in Parallel
      print('BackupService: Starting parallel uploads for $imageId (Original + 1024px + 256px + 64px)...');
      
      // Generate 1024px high-res JPEG thumbnail for Windows consoles
      final thumb1024Bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(1024, 1024), quality: 85);
      
      final uploads = [
        _encryptAndUpload(urls['original']!, fileBytes, masterKey, 'original'),
        if (thumb1024Bytes != null) _encryptAndUpload(urls['thumb_1024']!, thumb1024Bytes, masterKey, 'thumb_1024'),
        _encryptAndUpload(urls['thumb_256']!, thumb256Bytes, masterKey, 'thumb_256'),
        _encryptAndUpload(urls['thumb_64']!, thumb64Bytes, masterKey, 'thumb_64'),
      ];

      final results = await Future.wait(uploads);
      if (results.contains(false)) {
        print('BackupService: Upload failed for $imageId. Results: $results');
        return;
      }
      print('BackupService: All uploads successful for $imageId.');

      // 6. Register Metadata
      print('BackupService: Registering metadata for $imageId...');
      final success = await _registerImage(
        imageId: imageId,
        userId: userId,
        asset: asset,
        fileSize: fileBytes.length,
        checksum: checksum,
        width: asset.width,
        height: asset.height,
        albumName: albumName,
      );

      // 7. Mark Locally
      if (success) {
        await _db.logBackupStatus(file.path, 'UPLOADED');
        print('BackupService: Successfully backed up and registered ${file.path}');
      } else {
        print('BackupService: Failed to register metadata for ${file.path}');
        await _db.logBackupStatus(file.path, 'FAILED');
      }

    } catch (e, stack) {
      print('BackupService Asset Error (${asset.id}): $e');
      print(stack);
    }
  }

  Future<Set<String>> _fetchCloudChecksums(String userId) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/checksums?user_id=$userId');
      final response = await http.get(uri);
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final list = List<String>.from(json['checksums']);
        return list.toSet();
      }
    } catch (e) {
      print('BackupService: Error fetching cloud checksums: $e');
    }
    return <String>{};
  }

  Future<Set<String>> _fetchCloudSourceIDs(String userId) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/source_ids?user_id=$userId');
      final response = await http.get(uri);
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final list = List<String>.from(json['source_ids']);
        return list.toSet();
      }
    } catch (e) {
      print('BackupService: Error fetching cloud source IDs: $e');
    }
    return <String>{};
  }

  Future<Map<String, String>?> _getUploadUrls(String userId, String imageId, List<String> variants) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/upload_urls');
      final body = jsonEncode({
        'user_id': userId,
        'image_id': imageId,
        'variants': variants,
      });

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final urls = Map<String, String>.from(json['urls']);
        return urls;
      }
      return null;
    } catch (e) {
      print('GetUploadUrls Error: $e');
      return null;
    }
  }

  Future<bool> _encryptAndUpload(String url, Uint8List data, SecureKey masterKey, String variant) async {
    try {
      final uri = _resolveUri(url);
      final String originalAuthority = Uri.parse(url).authority;
      
      print('BackupService: Encrypting and uploading $variant (${data.length} bytes) to ${uri.host}:${uri.port} (Header Host: $originalAuthority)...');
      // Encrypt
      final result = _crypto.encrypt(data, masterKey);
      
      // Concat Nonce + Cipher
      final encryptedBytes = Uint8List(result.nonce.length + result.cipherText.length);
      encryptedBytes.setAll(0, result.nonce);
      encryptedBytes.setAll(result.nonce.length, result.cipherText);

      // PUT to Presigned URL
      final response = await http.put(
        uri,
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': encryptedBytes.length.toString(),
          'Host': originalAuthority, // Critical for MinIO signature validation
        },
        body: encryptedBytes,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        print('BackupService: Upload success for $variant');
        return true;
      } else {
        print('BackupService: Upload failed for $variant. Status: ${response.statusCode}, Body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('BackupService: EncryptAndUpload Error ($variant): $e');
      return false;
    }
  }

  Future<bool> _registerImage({
    required String imageId,
    required String userId,
    required AssetEntity asset,
    required int fileSize,
    required String checksum,
    required int width,
    required int height,
    String? albumName,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/register');
      
      final latlng = await asset.latlngAsync();
      final mimeType = await asset.mimeTypeAsync;

      final body = jsonEncode({
        'image_id': imageId,
        'user_id': userId,
        'created_at': asset.createDateTime.toUtc().toIso8601String(),
        'modified_at': asset.modifiedDateTime.toUtc().toIso8601String(), // AssetEntity usually has this
        'width': width,
        'height': height,
        'size': fileSize,
        'checksum': checksum,
        'source_id': asset.id,
        'latitude': latlng?.latitude ?? 0.0,
        'longitude': latlng?.longitude ?? 0.0,
        'mime_type': mimeType ?? '',
        'album': albumName ?? '',
        'is_deleted': false,
      });

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        print('RegisterImage Failed: ${response.statusCode}, Body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('RegisterImage Error: $e');
      return false;
    }
  }

  Future<void> uploadManualFiles(List<PlatformFile> files, String albumName) async {
    print('BackupService: Starting manual upload for ${files.length} files to album $albumName');

    final session = await _auth.loadSession();
    if (session == null) {
      print('BackupService: No session found (not logged in). Aborting.');
      return;
    }

    final userId = session['username'] as String;
    final masterKeyBytes = session['masterKey'] as Uint8List;
    final masterKey = SecureKey.fromList(_crypto.sodium, masterKeyBytes);

    // Fetch existing checksums for manual deduplication
    final cloudChecksums = await _fetchCloudChecksums(userId);

    for (var file in files) {
      try {
        final Uint8List? fileBytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
        if (fileBytes == null) {
          print('BackupService: Could not read bytes for file ${file.name}');
          continue;
        }

        final checksum = _calculateChecksum(fileBytes);
        if (cloudChecksums.contains(checksum)) {
           print('BackupService: Skipping manual file ${file.name} (Already on Cloud by Checksum)');
           continue;
        }

        final imageId = _generateUUID();

        // Try to decode image to fetch sizes and create thumbnails naturally
        final decodedImage = img.decodeImage(fileBytes);
        int width = 0;
        int height = 0;
        Uint8List? thumb256Bytes;
        Uint8List? thumb64Bytes;

        if (decodedImage != null) {
          width = decodedImage.width;
          height = decodedImage.height;

          // Generating thumbnails natively with `package:image`
          final thumb256 = img.copyResizeCropSquare(decodedImage, size: 256);
          thumb256Bytes = Uint8List.fromList(img.encodeJpg(thumb256, quality: 80));

          final thumb64 = img.copyResizeCropSquare(decodedImage, size: 64);
          thumb64Bytes = Uint8List.fromList(img.encodeJpg(thumb64, quality: 60));
        } else {
             print('BackupService: Could not decode image natively for thumbnails, it may be a video. Skipping thumbnail generation.');
             continue; // Ente backend logic currently relies on having thumbs, handle differently if supporting videos
        }

        final variants = ['original', 'thumb_256', 'thumb_64'];
        final urls = await _getUploadUrls(userId, imageId, variants);

        if (urls == null || urls.length != 3) {
          print('BackupService: Failed to get upload URLs for manual file $imageId');
          continue;
        }

        final uploads = [
          _encryptAndUpload(urls['original']!, fileBytes, masterKey, 'original'),
          _encryptAndUpload(urls['thumb_256']!, thumb256Bytes, masterKey, 'thumb_256'),
          _encryptAndUpload(urls['thumb_64']!, thumb64Bytes, masterKey, 'thumb_64'),
        ];

        final results = await Future.wait(uploads);
        if (results.contains(false)) {
          print('BackupService: Upload failed for manual file $imageId');
          continue;
        }

        // Register Metadata
        final uri = Uri.parse('$_baseUrl/images/register');
        final now = DateTime.now().toUtc().toIso8601String();
        
        final body = jsonEncode({
          'image_id': imageId,
          'user_id': userId,
          'created_at': now,
          'modified_at': now,
          'width': width,
          'height': height,
          'size': fileBytes.length,
          'checksum': checksum,
          'source_id': imageId, 
          'latitude': 0.0,
          'longitude': 0.0,
          'mime_type': file.extension != null ? 'image/${file.extension}' : 'image/jpeg',
          'album': albumName,
          'is_deleted': false,
        });

        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: body,
        );

        if (response.statusCode == 200) {
           print('BackupService: Successfully manually uploaded and registered ${file.name} to album $albumName');
        }

      } catch (e) {
          print('BackupService: Error manual uploading file ${file.name}: $e');
      }
    }
  }


  String _generateUUID() {
    final bytes = _crypto.sodium.randombytes.buf(16);
    return _toHex(bytes);
  }

  String _calculateChecksum(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  String _toHex(Uint8List bytes) {
    return bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
  }

  Future<RemoteImageResponse?> fetchRemoteImages(String userId, {String? cursor, String? album}) async {
    try {
      var uriStr = '$_baseUrl/images?user_id=$userId';
      if (cursor != null) {
        uriStr += '&cursor=$cursor';
      }
      if (album != null && album.isNotEmpty) {
        uriStr += '&album=${Uri.encodeComponent(album)}';
      }

      final uri = Uri.parse(uriStr);
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return RemoteImageResponse.fromJson(json);
      }
      return null;
    } catch (e) {
      print('FetchRemoteImages Error: $e');
      return null;
    }
  }

  Future<RemoteSyncResponse?> syncImages(String userId, String modifiedAfter) async {
    try {
      final uri = Uri.parse('$_baseUrl/sync?user_id=$userId&modified_after=${Uri.encodeComponent(modifiedAfter)}');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return RemoteSyncResponse.fromJson(json);
      }
      return null;
    } catch (e) {
      print('SyncImages Error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchAlbums(String userId) async {
    try {
      final uri = Uri.parse('$_baseUrl/albums?user_id=$userId');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final list = json['albums'] as List<dynamic>;
        return list.map((e) => e as Map<String, dynamic>).toList();
      }
      return [];
    } catch (e) {
      print('FetchAlbums Error: $e');
      return [];
    }
  }

  Future<Uint8List?> fetchAndDecryptFromUrl(String url, SecureKey masterKey) async {
    try {
      final uri = _resolveUri(url);
      final String originalAuthority = Uri.parse(url).authority;

      final response = await http.get(
        uri,
        headers: {
          'Host': originalAuthority, // Critical for MinIO signature validation
        },
      ).timeout(const Duration(seconds: 120));
      
      if (response.statusCode != 200) {
        print('FetchImage Error: Status ${response.statusCode} for $url');
        return null; // Return early on failure
      }

      if (response.statusCode == 200) {
        final encryptedBytes = response.bodyBytes;
        
        final nonceLen = _crypto.sodium.crypto.secretBox.nonceBytes;
        if (encryptedBytes.length < nonceLen) return null;
        
        final nonce = Uint8List.fromList(encryptedBytes.sublist(0, nonceLen));
        final cipher = Uint8List.fromList(encryptedBytes.sublist(nonceLen));
        
        try {
           final decrypted = _crypto.decrypt(cipher, nonce, masterKey);
           return decrypted;
        } catch (e) {
           print('FetchImage Decryption Error: $e');
           return null;
        }
      }
      return null;
    } catch (e) {
      print('FetchImage Error: $e');
      return null;
    }
  }

  Future<RemoteImage?> fetchSingleRemoteImage(String userId, String imageId) async {
    try {
      final uriStr = '$_baseUrl/images/$imageId?user_id=$userId';
      final uri = Uri.parse(uriStr);
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return RemoteImage.fromJson(json['image']);
      }
      return null;
    } catch (e) {
      print('FetchSingleRemoteImage Error: $e');
      return null;
    }
  }

  Future<bool> uploadFaceDatabase() async {
      final session = await _auth.loadSession();
      if (session == null) return false;
      final userId = session['username'] as String;
      final masterKeyBytes = session['masterKey'] as Uint8List;
      final masterKey = SecureKey.fromList(_crypto.sodium, masterKeyBytes);

      final faces = await _db.getAllFaces();
      final clusters = await _db.getAllClustersWithThumbnail();
      final processed = await (await _db.database).query('processed_images');
      
      final Map<String, dynamic> exportData = {
         'faces': [],
         'clusters': clusters.map((c) => {
            'id': c['id'],
            'name': c['name'],
            'thumbnail': c['thumbnail'] != null ? base64Encode(c['thumbnail'] as Uint8List) : null,
            'representative_face_id': c['representative_face_id'],
         }).toList(),
         'processed_images': processed.map((p) => p['image_path']).toList(),
      };

      for (var f in faces) {
         final blob = f['embedding'] as Uint8List?;
         List<double>? vector;
         if (blob != null) {
            var buffer = blob.buffer;
            var offset = blob.offsetInBytes;
            if (offset % 4 != 0) {
                 final copy = Uint8List.fromList(blob);
                 buffer = copy.buffer;
                 offset = 0;
            }
            vector = Float32List.view(buffer, offset, blob.lengthInBytes ~/ 4).toList();
         }

         exportData['faces'].add({
            'id': f['id'],
            'cluster_id': f['cluster_id'],
            'image_path': f['image_path'],
            'bbox': f['bbox'],
            'landmarks': f['landmarks'], 
            'embedding': vector,
            'thumbnail': f['thumbnail'] != null ? base64Encode(f['thumbnail'] as Uint8List) : null,
            'fl_trained': f['fl_trained'] ?? 0,
         });
      }

      final jsonBytes = utf8.encode(jsonEncode(exportData));
      
      final urls = await _getUploadUrls(userId, 'faces_blob', ['faces']);
      if (urls == null || !urls.containsKey('faces')) return false;

      final success = await _encryptAndUpload(urls['faces']!, Uint8List.fromList(jsonBytes), masterKey, 'faces');
      if (!success) return false;

      // Register new version
      try {
          final uri = Uri.parse('$_baseUrl/images/faces/register?user_id=$userId');
          final response = await http.post(uri);
          if (response.statusCode == 200) {
              final newVersion = jsonDecode(response.body)['version'] as int;
              await _db.setBackupSetting('people_data_version', newVersion.toString());
              print('BackupService: People version registered: $newVersion');
          }
      } catch (e) {
          print('BackupService: Error registering people version: $e');
      }
      
      return true;
  }

  Future<int> getRemotePeopleVersion(String userId) async {
      try {
          final uri = Uri.parse('$_baseUrl/images/faces/version?user_id=$userId');
          final response = await http.get(uri);
          if (response.statusCode == 200) {
              return jsonDecode(response.body)['version'] as int;
          }
      } catch (e) {
          print('BackupService: Error getting remote people version: $e');
      }
      return -1;
  }

  // --- Deletion Features ---
  
  /// Deletes specified image IDs permanently from the cloud backend.
  Future<bool> deleteCloudImages(String userId, List<String> imageIds) async {
    try {
      final uri = Uri.parse('$_baseUrl/images?user_id=$userId');
      final requestBody = jsonEncode({
        'image_ids': imageIds,
      });

      final response = await http.delete(
        uri, 
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        print('BackupService: Successfully deleted ${imageIds.length} images from cloud.');
        return true;
      } else {
        print('BackupService: Failed to delete cloud images. Code: ${response.statusCode}, Body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('BackupService: Error during deleteCloudImages: $e');
      return false;
    }
  }

  /// Updates the geographic location of specified cloud images.
  Future<bool> updateCloudLocation(String userId, List<String> imageIds, double latitude, double longitude) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/location?user_id=$userId');
      final requestBody = jsonEncode({
        'image_ids': imageIds,
        'latitude': latitude,
        'longitude': longitude,
      });

      final response = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      );

      if (response.statusCode == 200) {
        print('BackupService: Successfully updated location for ${imageIds.length} images.');
        return true;
      } else {
        print('BackupService: Failed to update location. Code: ${response.statusCode}, Body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('BackupService: Error during updateCloudLocation: $e');
      return false;
    }
  }

  /// Updates the assigned album for specified cloud images.
  Future<bool> updateCloudAlbum(String userId, List<String> imageIds, String albumName) async {
    try {
      final uri = Uri.parse('$_baseUrl/images/album?user_id=$userId');
      final requestBody = jsonEncode({
        'image_ids': imageIds,
        'album_name': albumName,
      });

      final response = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      );

      if (response.statusCode == 200) {
        print('BackupService: Successfully updated album for ${imageIds.length} images.');
        return true;
      } else {
        print('BackupService: Failed to update album. Code: ${response.statusCode}, Body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('BackupService: Error during updateCloudAlbum: $e');
      return false;
    }
  }

  Future<bool> downloadFaceDatabase({bool inMemoryOnly = false}) async {
      final session = await _auth.loadSession();
      if (session == null) return false;
      final userId = session['username'] as String;
      final masterKeyBytes = session['masterKey'] as Uint8List;
      final masterKey = SecureKey.fromList(_crypto.sodium, masterKeyBytes);

      final uri = Uri.parse('$_baseUrl/images/faces?user_id=$userId');
      final response = await http.get(uri);
      if (response.statusCode != 200) return false;

      final resBody = jsonDecode(response.body);
      final url = resBody['url'] as String;
      final version = resBody['version'] as int;

      final bytes = await fetchAndDecryptFromUrl(url, masterKey);
      if (bytes == null) return false;

      final jsonStr = utf8.decode(bytes);
      final data = jsonDecode(jsonStr);

      if (inMemoryOnly) {
         // Optionally you can keep it just in memory and replace standard getters.
      }

      final db = await _db.database;
      await db.delete('faces');
      await db.delete('clusters');
      await db.delete('processed_images');

      final clusters = data['clusters'] as List<dynamic>;
      for (var c in clusters) {
         Uint8List? thumbBytes;
         if (c['thumbnail'] != null) {
            if (c['thumbnail'] is String) {
               thumbBytes = base64Decode(c['thumbnail']);
            } else {
               thumbBytes = Uint8List.fromList(List<int>.from(c['thumbnail']));
            }
         }
         await db.insert('clusters', {
             'id': c['id'],
             'name': c['name'],
             'thumbnail': thumbBytes,
             'representative_face_id': c['representative_face_id'],
         });
      }

      if (data.containsKey('processed_images')) {
          final processed = data['processed_images'] as List<dynamic>;
          for (var path in processed) {
              await db.insert('processed_images', {'image_path': path}, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
      }

      final importedFaces = data['faces'] as List<dynamic>;
      for (var f in importedFaces) {
         Uint8List? embBytes;
         if (f['embedding'] != null) {
            final List<dynamic> dlist = f['embedding'];
            embBytes = Float32List.fromList(dlist.map((e) => e.toDouble()).toList().cast<double>()).buffer.asUint8List();
         }
         Uint8List? thumbBytes;
         if (f['thumbnail'] != null) {
            if (f['thumbnail'] is String) {
               thumbBytes = base64Decode(f['thumbnail']);
            } else {
               thumbBytes = Uint8List.fromList(List<int>.from(f['thumbnail']));
            }
         }

         await db.insert('faces', {
             'id': f['id'],
             'cluster_id': f['cluster_id'],
             'image_path': f['image_path'],
             'bbox': f['bbox'],
             'landmarks': f['landmarks'],
             'embedding': embBytes,
             'thumbnail': thumbBytes,
             'fl_trained': f['fl_trained'] ?? 0,
         });
      }

      // Mark version locally
      await _db.setBackupSetting('people_data_version', version.toString());

      return true;
  }
}
