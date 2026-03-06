import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Singleton that holds the current backend URL.
///
/// IMPORTANT — call [ApiConfig.init()] early in main() (before runApp) so
/// the saved IP is available synchronously before any service makes a network
/// call.  [baseUrl] never falls back to a hard-coded IP; if no custom IP has
/// been configured it returns the platform-appropriate localhost address.
class ApiConfig {
  static final ApiConfig _instance = ApiConfig._internal();

  factory ApiConfig() => _instance;
  ApiConfig._internal();

  static const String _port = '8080';
  static const String _prefKey = 'custom_api_ip';

  /// The resolved base URL, set synchronously by [init()] from SharedPreferences.
  /// Mutated immediately by [setCustomIp()] so every subsequent call to
  /// [baseUrl] picks up the new host without any delay.
  String _baseUrl = '';

  /// Returns the current server base URL.
  /// Never returns a stale, hard-coded IP — always reflects the latest call
  /// to [setCustomIp()] or the value loaded by [init()].
  String get baseUrl {
    if (_baseUrl.isNotEmpty) return _baseUrl;

    // Fallback defaults when no custom IP has been saved yet
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        return 'http://$host:$_port';
      }
      return 'http://localhost:$_port';
    }

    if (!kIsWeb && Platform.isWindows) {
      return 'http://localhost:$_port';
    }

    // Android / iOS: no sensible default — the user must configure their IP.
    // Return empty so callers get a clear network error rather than silently
    // hitting a hard-coded stale IP from a previous development session.
    return '';
  }

  /// Must be called once in main() before runApp() so the saved IP is loaded
  /// synchronously into [_baseUrl] before any service accesses [baseUrl].
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString(_prefKey);
    if (savedIp != null && savedIp.isNotEmpty) {
      _baseUrl = 'http://$savedIp:$_port';
      debugPrint('ApiConfig.init: loaded saved IP → $_baseUrl');
    } else {
      debugPrint('ApiConfig.init: no custom IP saved, using platform defaults');
    }
  }

  /// Saves a new IP and immediately updates [_baseUrl] so every subsequent
  /// [baseUrl] access uses the new host — no restart required.
  Future<void> setCustomIp(String ipAddress) async {
    // Strip accidental http:// or :port suffix typed by the user
    final cleanIp = ipAddress
        .replaceAll('http://', '')
        .replaceAll('https://', '')
        .replaceAll(RegExp(r':\d+$'), '')
        .trim();

    // Update in-memory value FIRST so any ongoing request context picks it up
    _baseUrl = 'http://$cleanIp:$_port';
    debugPrint('ApiConfig: host updated to $_baseUrl');

    // Persist for next app launch
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, cleanIp);
  }

  /// Returns just the IP string for display in the settings UI.
  Future<String> getCurrentIp() async {
    final prefs = await SharedPreferences.getInstance();
    final customIp = prefs.getString(_prefKey);
    if (customIp != null && customIp.isNotEmpty) return customIp;

    if (kIsWeb) {
      final host = Uri.base.host;
      return host.isNotEmpty ? host : 'localhost';
    }

    if (!kIsWeb && Platform.isWindows) return 'localhost';

    return ''; // Not configured yet on Android/iOS
  }
}
