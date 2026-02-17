import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:photo_manager/photo_manager.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'database_service.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

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
      final masterKeyBytes = session['masterKey'] as Uint8List;
      
      // Recreate SecureKey from bytes
      // Access sodium instance directly via CryptoService singleton
      final key = SecureKey.fromList(_crypto.sodium, masterKeyBytes);
      
      // 2. Fetch Assets from selected albums
      if (_selectedAlbumIds.isEmpty) {
         print('BackupService: No albums selected.');
         _isRunning = false; 
         return; // Nothing to backup
      }

      // We need to fetch ALL assets from the selected albums to check against DB
      // Start with first album for simplicity or iterate all
      // To avoid duplicates if an asset is in multiple albums (e.g. Recent + Favorites),
      // we use a Set of IDs.
      final Set<String> processedAssetIds = {};
      final List<AssetEntity> assetsToBackup = [];

      final allAlbums = await PhotoManager.getAssetPathList(type: RequestType.common);
      
      for (var albumId in _selectedAlbumIds) {
          if (!_isBackupEnabled) break;
          
          try {
             final album = allAlbums.firstWhere((a) => a.id == albumId);
             final count = await album.assetCountAsync;
             // Process in batches to avoid memory issues if album is huge
             // For implementation simplicity, fetching pages of 50
             
             for (int page = 0; page < (count / 50).ceil(); page++) {
                if (!_isBackupEnabled) break;
                
                final batch = await album.getAssetListPaged(page: page, size: 50);
                
                for (var asset in batch) {
                   if (processedAssetIds.contains(asset.id)) continue;
                   processedAssetIds.add(asset.id);
                   
                   // Check if backed up
                   final file = await asset.file;
                   if (file == null) continue;
                   
                   if (await _db.isBackedUp(file.path)) continue;
                   
                   assetsToBackup.add(asset);
                }
             }
          } catch (e) {
             print('Error fetching album $albumId: $e');
          }
      }

      print('BackupService: Found ${assetsToBackup.length} pending files.');

      // 3. Process Uploads
      for (var asset in assetsToBackup) {
         if (!_isBackupEnabled) break;

         final file = await asset.file;
         if (file == null) continue;
         
         print('BackupService: Backing up ${file.path}...');
         final success = await _uploadFile(file, username, key);
         
         if (success) {
            await _db.logBackupStatus(file.path, 'UPLOADED');
         } else {
            await _db.logBackupStatus(file.path, 'FAILED');
            // Continue to next file, retry later
         }
         
         // Yield slightly to not block UI thread heavily
         await Future.delayed(Duration.zero);
      }

    } catch (e) {
      print('BackupService Error: $e');
    } finally {
      _isRunning = false;
      print('BackupService: Backup run finished.');
    }
  }

  Future<bool> _uploadFile(File file, String username, SecureKey masterKey) async {
    try {
      final bytes = await file.readAsBytes();
      
      // Encrypt
      final result = _crypto.encrypt(bytes, masterKey);
      
      // Concat Nonce (24 bytes) + CipherText
      final encryptedBytes = Uint8List(result.nonce.length + result.cipherText.length);
      encryptedBytes.setAll(0, result.nonce);
      encryptedBytes.setAll(result.nonce.length, result.cipherText);
      
      // Create Request
      final uri = Uri.parse('$_baseUrl/upload');
      final request = http.MultipartRequest('POST', uri);
      
      request.fields['username'] = username;
      request.files.add(http.MultipartFile.fromBytes(
        'files', 
        encryptedBytes,
        filename: path.basename(file.path) // Original filename
      ));
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        // Parse JSON to confirm success
        final json = jsonDecode(response.body);
        final failedCount = json['failed_count'] as int? ?? 0;
        return failedCount == 0;
      } else {
        print('Upload failed: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      print('Upload Error: $e');
      print('Upload Error: $e');
      return false;
    }
  }

  Future<List<String>> listServerFiles(String username) async {
    try {
      final uri = Uri.parse('$_baseUrl/images?username=$username');
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        // files returns "username/filename". We probably want just filename? 
        // Or keep full path? The download endpoint expects filename.
        // The backend `ListFiles` returns keys like "username/filename".
        // The frontend usually wants to display grid.
        // Let's return raw list for now.
        return List<String>.from(json['files'] ?? []);
      }
      return [];
    } catch (e) {
      print('ListFiles Error: $e');
      return [];
    }
  }

  Future<Uint8List?> fetchAndDecryptImage(String username, String filename, SecureKey masterKey) async {
    try {
      // Backend expects filename to be just the name if logic is simple, or path?
      // Backend: `objectName := fmt.Sprintf("%s/%s", username, filename)`
      // So if I pass "myuser/image.jpg", it becomes "myuser/myuser/image.jpg". WRONG.
      // I should pass only the filename part.
      // But the list returns "username/filename".
      
      final actualFilename = filename.split('/').last;
      
      final uri = Uri.parse('$_baseUrl/image/download?username=$username&filename=$actualFilename');
      final response = await http.get(uri);
      
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
