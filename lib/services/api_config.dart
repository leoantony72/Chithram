import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  static final ApiConfig _instance = ApiConfig._internal();
  
  factory ApiConfig() {
    return _instance;
  }
  
  ApiConfig._internal();

  // The cached port string
  final String _port = '8080';
  
  // The dynamically stored base IP address, falling back to localhost bounds if unconfigured
  String _baseUrl = '';

  String get baseUrl {
    if (_baseUrl.isNotEmpty) return _baseUrl;

    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        return 'http://$host:$_port';
      }
      return 'http://localhost:$_port';
    }
    
    // Windows host defaulting to localhost
    if (Platform.isWindows) {
      return 'http://localhost:$_port';
    }
    
    // Android requires a custom network IP, defaulting to the old static fallback but easily overrideable
    if (Platform.isAndroid) {
      return 'http://192.168.18.11:$_port';
    }

    return 'http://localhost:$_port';
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('custom_api_ip');
    if (savedIp != null && savedIp.isNotEmpty) {
      // If a custom IP string like "192.168.1.5" was saved, map it to the server string
      _baseUrl = 'http://$savedIp:$_port';
    }
  }

  Future<void> setCustomIp(String ipAddress) async {
    final prefs = await SharedPreferences.getInstance();
    // Strip http:// or :8080 if the user accidentally typed it, just storing the pure IP string
    String cleanIp = ipAddress.replaceAll('http://', '').replaceAll(RegExp(r':\d+'), '').trim();
    
    await prefs.setString('custom_api_ip', cleanIp);
    _baseUrl = 'http://$cleanIp:$_port';
    print('Global API Host updated to: $_baseUrl');
  }

  // Get the pure IP string for UI display
  Future<String> getCurrentIp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('custom_api_ip') ?? (Platform.isAndroid ? '192.168.18.11' : (kIsWeb ? Uri.base.host : 'localhost'));
  }
}
