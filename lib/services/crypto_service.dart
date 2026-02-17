import 'dart:convert';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs_sumo.dart';

class EncryptionResult {
  final Uint8List cipherText;
  final Uint8List nonce;

  EncryptionResult(this.cipherText, this.nonce);
}

class CryptoService {
  late SodiumSumo sodium;
  static final CryptoService _instance = CryptoService._internal();

  factory CryptoService() {
    return _instance;
  }

  CryptoService._internal();

  Future<void> init() async {
    sodium = await SodiumSumoInit.init();
  }

  Uint8List generateSalt() {
    return sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
  }

  Uint8List generateNonce() {
    return sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
  }

  SecureKey generateMasterKey() {
    return sodium.secureRandom(32); // 256 bits
  }

  // Derive Key Encryption Key (KEK) from Password
  SecureKey deriveKEK(String password, Uint8List salt) {
    return sodium.crypto.pwhash(
      outLen: 32,
      password: Int8List.fromList(utf8.encode(password)),
      salt: salt,
      opsLimit: sodium.crypto.pwhash.opsLimitInteractive,
      memLimit: sodium.crypto.pwhash.memLimitInteractive,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
  }

  // Encrypt Data (MasterKey, PrivateKey, etc.)
  // Key must be SecureKey. Message is raw bytes.
  EncryptionResult encrypt(Uint8List message, SecureKey key) {
    final nonce = generateNonce();
    final cipher = sodium.crypto.secretBox.easy(
      message: message,
      nonce: nonce,
      key: key,
    );
    return EncryptionResult(cipher, nonce);
  }

  // Decrypt Data
  // Returns raw bytes. Key must be SecureKey.
  Uint8List decrypt(Uint8List cipher, Uint8List nonce, SecureKey key) {
    return sodium.crypto.secretBox.openEasy(
      cipherText: cipher,
      nonce: nonce,
      key: key,
    );
  }

  // Generate Public/Private Key Pair
  KeyPair generateKeyPair() {
    return sodium.crypto.box.keyPair();
  }
}
