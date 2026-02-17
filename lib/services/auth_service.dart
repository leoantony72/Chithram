import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:sodium_libs/sodium_libs_sumo.dart'; // For Sumo types
import 'crypto_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  final CryptoService _cryptoService = CryptoService();

  factory AuthService() {
    return _instance;
  }

  AuthService._internal();

  // Helper for Base URL
  String get _baseUrl {
    if (Platform.isAndroid) {
      return 'http://10.221.188.139:8080';
    }
    return 'http://localhost:8080';
  }

  Future<void> init() async {
    await _cryptoService.init();
  }

  Future<bool> signup(String email, String password) async {
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
      
      return {
        'masterKey': masterKeyBytes, // Returning bytes for display/usage
        'privateKey': privateKeyBytes,
        'publicKey': base64Decode(data['public_key']),
      };

    } catch (e) {
      print('Login error/decryption failed: $e');
      return null;
    }
  }
}
