import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'api_config.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'backup_service.dart';

/// Represents a share (photo shared with or by the current user)
class ShareItem {
  final String id;
  final String senderId;
  final String receiverId;
  final String imageId;
  final String shareType; // one_time | normal
  final DateTime createdAt;
  final DateTime? viewedAt;
  final String? senderUsername;
  final int width;
  final int height;
  final String mimeType;

  ShareItem({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.imageId,
    required this.shareType,
    required this.createdAt,
    this.viewedAt,
    this.senderUsername,
    this.width = 0,
    this.height = 0,
    this.mimeType = 'image/jpeg',
  });

  bool get isOneTime => shareType == 'one_time';
  bool get isViewed => viewedAt != null;
}

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  String get _baseUrl => ApiConfig().baseUrl;

  /// Search usernames by prefix (for autocomplete)
  Future<List<String>> searchUsers(String query, {String? excludeUsername}) async {
    if (query.trim().length < 2) return [];
    try {
      final params = <String, String>{'q': query.trim()};
      if (excludeUsername != null && excludeUsername.isNotEmpty) {
        params['exclude'] = excludeUsername;
      }
      final uri = Uri.parse('$_baseUrl/users/search').replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body);
      final list = json['usernames'] as List? ?? [];
      return list.map((e) => e.toString()).toList();
    } catch (e) {
      return [];
    }
  }

  /// Get receiver's public key for encrypting share key
  Future<Uint8List?> getReceiverPublicKey(String username) async {
    try {
      final uri = Uri.parse('$_baseUrl/users/$username/public-key');
      final response = await http.get(uri);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      final keyB64 = json['public_key'] as String?;
      if (keyB64 == null || keyB64.isEmpty) return null;
      return base64Decode(keyB64);
    } catch (e) {
      print('ShareService: getReceiverPublicKey error: $e');
      return null;
    }
  }

  /// Create a share: 1) create record 2) upload encrypted image
  Future<String?> createShare({
    required String receiverUsername,
    required String imageId,
    required String shareType,
    required Uint8List imageBytes,
  }) async {
    final session = await AuthService().loadSession();
    if (session == null) return null;

    final userId = session['username'] as String;
    final receiverPk = await getReceiverPublicKey(receiverUsername);
    if (receiverPk == null || receiverPk.length != 32) {
      print('ShareService: Could not get receiver public key');
      return null;
    }

    try {
      await CryptoService().init();
      final shareKey = CryptoService().generateMasterKey();
      final encryptedImage = CryptoService().encrypt(imageBytes, shareKey);
      final shareKeyBytes = shareKey.extractBytes();
      final encryptedShareKey = CryptoService().sealForRecipient(shareKeyBytes, receiverPk);

      final sessionPk = session['publicKey'] as Uint8List?;
      if (sessionPk == null) {
        print('ShareService: No public key in session');
        return null;
      }

      final createUri = Uri.parse('$_baseUrl/shares?user_id=$userId');
      final createBody = jsonEncode({
        'receiver_username': receiverUsername,
        'image_id': imageId,
        'share_type': shareType,
        'encrypted_share_key': base64Encode(encryptedShareKey),
        'sender_public_key': base64Encode(sessionPk),
      });

      final createResp = await http.post(
        createUri,
        headers: {'Content-Type': 'application/json'},
        body: createBody,
      );

      if (createResp.statusCode != 200) {
        print('ShareService: Create share failed: ${createResp.statusCode} ${createResp.body}');
        return null;
      }

      final createJson = jsonDecode(createResp.body);
      final shareId = createJson['share_id'] as String?;
      if (shareId == null) return null;

      // 2. Get upload URL and upload encrypted image
      final uploadUrlResp = await http.get(Uri.parse('$_baseUrl/shares/$shareId/upload-url?user_id=$userId'));
      if (uploadUrlResp.statusCode != 200) {
        print('ShareService: Get upload URL failed');
        return null;
      }

      final uploadUrl = jsonDecode(uploadUrlResp.body)['upload_url'] as String?;
      if (uploadUrl == null) return null;

      final encryptedPayload = Uint8List.fromList([...encryptedImage.nonce, ...encryptedImage.cipherText]);
      final uploadResp = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: encryptedPayload,
      );

      if (uploadResp.statusCode != 200) {
        print('ShareService: Upload failed: ${uploadResp.statusCode}');
        return null;
      }

      return shareId;
    } catch (e) {
      print('ShareService: createShare error: $e');
      return null;
    }
  }

  /// List shares received by current user
  Future<List<ShareItem>> listSharesWithMe() async {
    final session = await AuthService().loadSession();
    if (session == null) return [];

    try {
      final uri = Uri.parse('$_baseUrl/shares/with-me?user_id=${session['username']}');
      final response = await http.get(uri);
      if (response.statusCode != 200) return [];

      final json = jsonDecode(response.body);
      final list = json['shares'] as List? ?? [];
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return ShareItem(
          id: m['id'] ?? '',
          senderId: m['sender_id'] ?? '',
          receiverId: m['receiver_id'] ?? '',
          imageId: m['image_id'] ?? '',
          shareType: m['share_type'] ?? 'normal',
          createdAt: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
          viewedAt: m['viewed_at'] != null ? DateTime.tryParse(m['viewed_at']) : null,
          senderUsername: m['sender_username'] ?? m['sender_id'],
          width: m['width'] ?? 0,
          height: m['height'] ?? 0,
          mimeType: m['mime_type'] ?? 'image/jpeg',
        );
      }).toList();
    } catch (e) {
      print('ShareService: listSharesWithMe error: $e');
      return [];
    }
  }

  /// List shares sent by current user
  Future<List<ShareItem>> listSharesByMe() async {
    final session = await AuthService().loadSession();
    if (session == null) return [];

    try {
      final uri = Uri.parse('$_baseUrl/shares/by-me?user_id=${session['username']}');
      final response = await http.get(uri);
      if (response.statusCode != 200) return [];

      final json = jsonDecode(response.body);
      final list = json['shares'] as List? ?? [];
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return ShareItem(
          id: m['id'] ?? '',
          senderId: m['sender_id'] ?? '',
          receiverId: m['receiver_id'] ?? '',
          imageId: m['image_id'] ?? '',
          shareType: m['share_type'] ?? 'normal',
          createdAt: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
          viewedAt: m['viewed_at'] != null ? DateTime.tryParse(m['viewed_at']) : null,
          senderUsername: m['sender_id'],
          width: 0,
          height: 0,
          mimeType: 'image/jpeg',
        );
      }).toList();
    } catch (e) {
      print('ShareService: listSharesByMe error: $e');
      return [];
    }
  }

  /// Fetch and decrypt a shared image
  Future<Uint8List?> fetchSharedImage(String shareId) async {
    final session = await AuthService().loadSession();
    if (session == null) return null;

    final userId = session['username'] as String;
    final masterKeyBytes = session['masterKey'] as Uint8List;
    final privateKeyBytes = session['privateKey'] as Uint8List?;
    final publicKeyBytes = session['publicKey'] as Uint8List?;

    if (privateKeyBytes == null || publicKeyBytes == null) return null;

    try {
      // 1. Get share metadata (encrypted_share_key, sender_public_key)
      final metaResp = await http.get(Uri.parse('$_baseUrl/shares/$shareId?user_id=$userId'));
      if (metaResp.statusCode != 200) return null;

      final meta = jsonDecode(metaResp.body);
      final encShareKeyB64 = meta['encrypted_share_key'] as String?;
      final senderPkB64 = meta['sender_public_key'] as String?;

      if (encShareKeyB64 == null || encShareKeyB64.isEmpty || senderPkB64 == null || senderPkB64.isEmpty) {
        print('ShareService: Share missing keys');
        return null;
      }

      final crypto = CryptoService();
      await crypto.init();

      final encShareKey = base64Decode(encShareKeyB64);
      final ourPk = publicKeyBytes;
      final ourSk = crypto.restoreKey(privateKeyBytes);

      // For sealOpen we need our keypair - the recipient decrypts with their secret key
      final shareKey = crypto.unsealFromSender(encShareKey, ourPk, ourSk);

      // 2. Get download URL
      final urlResp = await http.get(Uri.parse('$_baseUrl/shares/$shareId/download-url?user_id=$userId'));
      if (urlResp.statusCode != 200) return null;

      final downloadUrl = jsonDecode(urlResp.body)['download_url'] as String?;
      if (downloadUrl == null) return null;

      // 3. Fetch encrypted image
      final imageResp = await http.get(Uri.parse(downloadUrl));
      if (imageResp.statusCode != 200) return null;

      final encryptedBytes = imageResp.bodyBytes;
      final nonceLen = crypto.sodium.crypto.secretBox.nonceBytes;
      if (encryptedBytes.length < nonceLen) return null;

      final nonce = encryptedBytes.sublist(0, nonceLen);
      final cipher = encryptedBytes.sublist(nonceLen);
      final shareKeySecure = crypto.restoreKey(Uint8List.fromList(shareKey));

      return crypto.decrypt(cipher, nonce, shareKeySecure);
    } catch (e) {
      print('ShareService: fetchSharedImage error: $e');
      return null;
    }
  }

  /// Revoke a share (sender only)
  Future<bool> revokeShare(String shareId) async {
    final session = await AuthService().loadSession();
    if (session == null) return false;

    try {
      final uri = Uri.parse('$_baseUrl/shares/$shareId?user_id=${session['username']}');
      final response = await http.delete(uri);
      return response.statusCode == 200;
    } catch (e) {
      print('ShareService: revokeShare error: $e');
      return false;
    }
  }

  /// Delete a received share (recipient only)
  Future<bool> deleteReceivedShare(String shareId) async {
    final session = await AuthService().loadSession();
    if (session == null) return false;

    try {
      final uri = Uri.parse('$_baseUrl/shares/$shareId/received?user_id=${session['username']}');
      final response = await http.delete(uri);
      return response.statusCode == 200;
    } catch (e) {
      print('ShareService: deleteReceivedShare error: $e');
      return false;
    }
  }
}
