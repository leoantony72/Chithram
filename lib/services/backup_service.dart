import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:photo_manager/photo_manager.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:crypto/crypto.dart'; // Add crypto package
import '../models/remote_image.dart';
import 'database_service.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

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
  String get _baseUrl {
     if (kIsWeb) return 'http://localhost:8080';
     if (Platform.isAndroid) {
       return 'http://192.168.18.11:8080';
     }
     return 'http://localhost:8080';
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
      
      // 2. Fetch Cloud Source IDs (Fast Deduplication)
      print('BackupService: Fetching existing source IDs from cloud...');
      final cloudSourceIDs = await _fetchCloudSourceIDs(userId);
      print('BackupService: Found ${cloudSourceIDs.length} existing items in cloud.');

      // 3. Fetch Assets from selected albums
      if (_selectedAlbumIds.isEmpty) {
         print('BackupService: No albums selected.');
         _isRunning = false; 
         return; 
      }

      final Set<String> processedAssetIds = {};
      final List<AssetEntity> assetsToBackup = [];

      final allAlbums = await PhotoManager.getAssetPathList(type: RequestType.common);
      
      for (var albumId in _selectedAlbumIds) {
          if (!_isBackupEnabled) break;
          try {
             final album = allAlbums.firstWhere((a) => a.id == albumId);
             final count = await album.assetCountAsync;
             
             // Check all pages
             for (int page = 0; page < (count / 50).ceil(); page++) {
                if (!_isBackupEnabled) break;
                final batch = await album.getAssetListPaged(page: page, size: 50);
                for (var asset in batch) {
                   if (processedAssetIds.contains(asset.id)) continue;
                   processedAssetIds.add(asset.id);
                   
                   final file = await asset.file;
                   if (file == null) continue;
                   if (await _db.isBackedUp(file.path)) continue; // Skip if done
                   
                   assetsToBackup.add(asset);
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
         
         await Future.wait(batch.map((asset) => _processSingleAsset(asset, userId, key, cloudSourceIDs)));
         
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

  Future<void> _processSingleAsset(AssetEntity asset, String userId, SecureKey masterKey, Set<String> cloudSourceIDs) async {
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
      
      print('BackupService: Processing ${file.path}...');

      // 2. Generate ID and Checksum (Only for new files)
      final imageId = _generateUUID();
      final fileBytes = await file.readAsBytes();
      final checksum = _calculateChecksum(fileBytes);
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
      final variants = ['original', 'thumb_256', 'thumb_64'];
      final urls = await _getUploadUrls(userId, imageId, variants);
      if (urls == null || urls.length != 3) {
        print('BackupService: Failed to get all upload URLs. Got: ${urls?.keys}');
        return;
      }
      print('BackupService: Received ${urls.length} upload URLs.');

      // 5. Encrypt and Upload in Parallel
      print('BackupService: Starting parallel uploads for $imageId...');
      final uploads = [
        _encryptAndUpload(urls['original']!, fileBytes, masterKey, 'original'),
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
      Uri uri = Uri.parse(url);
      final String originalAuthority = uri.authority; // e.g., 127.0.0.1:9000
      
      // Fix for Android Emulator/Device: Replace localhost with host IP
      if (Platform.isAndroid && (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
         // Use the same IP as _baseUrl
         uri = uri.replace(host: '192.168.18.11'); 
      }

      print('BackupService: Encrypting and uploading $variant (${data.length} bytes) to ${uri.host}:${uri.port} (Host: $originalAuthority)...');
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
      );

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

  Future<RemoteImageResponse?> fetchRemoteImages(String userId, {String? cursor}) async {
    try {
      var uriStr = '$_baseUrl/images?user_id=$userId';
      if (cursor != null) {
        uriStr += '&cursor=$cursor';
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

  Future<Uint8List?> fetchAndDecryptFromUrl(String url, SecureKey masterKey) async {
    try {
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final encryptedBytes = response.bodyBytes;
        
        final nonceLen = _crypto.sodium.crypto.secretBox.nonceBytes;
        if (encryptedBytes.length < nonceLen) return null;
        
        final nonce = Uint8List.fromList(encryptedBytes.sublist(0, nonceLen));
        final cipher = Uint8List.fromList(encryptedBytes.sublist(nonceLen));
        
        final decrypted = _crypto.decrypt(cipher, nonce, masterKey);
        return decrypted;
      }
      return null;
    } catch (e) {
      print('FetchImage Error: $e');
      return null;
    }
  }
}
