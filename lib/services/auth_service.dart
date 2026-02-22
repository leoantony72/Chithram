import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:sodium_libs/sodium_libs_sumo.dart'; // For Sumo types
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'crypto_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  final CryptoService _cryptoService = CryptoService();
  final _storage = const FlutterSecureStorage();
  Map<String, dynamic>? _cachedSession;

  factory AuthService() {
    return _instance;
  }

  AuthService._internal();

  // Helper for Base URL
  String get _baseUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        return 'http://$host:8080';
      }
      return 'http://localhost:8080';
    }
    if (!kIsWeb && Platform.isAndroid) {
      return 'http://192.168.18.11:8080';
    }
    return 'http://localhost:8080';
  }

  Future<void> init() async {
    await _cryptoService.init();
  }

  // --- Session Persistence ---
  
  // --- Session Persistence ---
  
  Future<void> saveSession(String username, Uint8List masterKey, Uint8List privateKey, Uint8List publicKey) async {
    await _storage.write(key: 'username', value: username);
    await _storage.write(key: 'master_key', value: base64Encode(masterKey));
    await _storage.write(key: 'private_key', value: base64Encode(privateKey));
    await _storage.write(key: 'public_key', value: base64Encode(publicKey));
    _cachedSession = {
      'username': username,
      'masterKey': masterKey,
      'privateKey': privateKey,
      'publicKey': publicKey,
    };
  }

  Future<Map<String, dynamic>?> loadSession() async {
    if (_cachedSession != null) return _cachedSession;

    final user = await _storage.read(key: 'username');
    final mk = await _storage.read(key: 'master_key');
    final pk = await _storage.read(key: 'private_key');
    final pub = await _storage.read(key: 'public_key');

    if (user != null && mk != null && pk != null && pub != null) {
      _cachedSession = {
        'username': user,
        'masterKey': base64Decode(mk),
        'privateKey': base64Decode(pk),
        'publicKey': base64Decode(pub),
      };
      return _cachedSession;
    }
    return null;
  }

  Future<void> logout() async {
    _cachedSession = null;
    await _storage.deleteAll();
  }

  // --- Auth Flow ---

  Future<bool> signup(String username, String email, String password) async {
    try {
      // 1. Generate Keys & Salts
      final masterKey = _cryptoService.generateMasterKey(); // Returns SecureKey
      final keyPair = _cryptoService.generateKeyPair();
      final kekSalt = _cryptoService.generateSalt();

      // 2. Derive KEK (Key Encryption Key)
      final kek = _cryptoService.deriveKEK(password, kekSalt); // Returns SecureKey

      // 3. Encrypt Master Key with KEK
      // masterKey is SecureKey (message), kek is SecureKey (key)
      final encryptedMk = _cryptoService.encrypt(masterKey.extractBytes(), kek);

      // 4. Encrypt Private Key with Master Key
      // keyPair.secretKey is SecureKey (message), masterKey is SecureKey (key)
      final encryptedPk = _cryptoService.encrypt(keyPair.secretKey.extractBytes(), masterKey);

      // 5. Prepare Payload
      final payload = {
        'username': username,
        'email': email,
        'password': password,
        'kek_salt': base64Encode(kekSalt),
        'encrypted_master_key': base64Encode(encryptedMk.cipherText),
        'master_key_nonce': base64Encode(encryptedMk.nonce),
        'public_key': base64Encode(keyPair.publicKey),
        'encrypted_private_key': base64Encode(encryptedPk.cipherText),
        'private_key_nonce': base64Encode(encryptedPk.nonce),
      };

      // 6. Send to Server
      final response = await http.post(
        Uri.parse('$_baseUrl/signup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        print('Signup failed: ${response.body}');
        return false;
      }
    } catch (e) {
      print('Signup error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> login(String email, String password) async {
    try {
      // 1. Authenticate with Server
      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      if (response.statusCode != 200) {
        print('Login failed: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body);

      // 2. Extract Data
      final username = data['username'] as String;
      final kekSalt = base64Decode(data['kek_salt']);
      final encryptedMk = base64Decode(data['encrypted_master_key']);
      final nonceMk = base64Decode(data['master_key_nonce']);
      final encryptedPk = base64Decode(data['encrypted_private_key']);
      final noncePk = base64Decode(data['private_key_nonce']);

      // 3. Derive KEK
      final kek = _cryptoService.deriveKEK(password, kekSalt); // SecureKey

      // 4. Decrypt Master Key
      final masterKeyBytes = _cryptoService.decrypt(encryptedMk, nonceMk, kek);
      
      // Convert Master Key bytes to SecureKey for next decryption
      final masterKeySecure = SecureKey.fromList(_cryptoService.sodium, masterKeyBytes);

      // 5. Decrypt Private Key
      final privateKeyBytes = _cryptoService.decrypt(encryptedPk, noncePk, masterKeySecure);

      print('Login successful. Keys decrypted.');
      
      final keys = {
        'username': username,
        'masterKey': masterKeyBytes, // Returning bytes for display/usage
        'privateKey': privateKeyBytes,
        'publicKey': base64Decode(data['public_key']),
      };
      
      // Save for persistence
      await saveSession(
        username,
        keys['masterKey'] as Uint8List, 
        keys['privateKey'] as Uint8List, 
        keys['publicKey'] as Uint8List
      );
      
      return keys;

    } catch (e) {
      print('Login error/decryption failed: $e');
      return null;
    }
  }
}
