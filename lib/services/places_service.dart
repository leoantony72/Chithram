import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class PlaceData {
  final String city;
  final String country;

  PlaceData({required this.city, required this.country});

  Map<String, dynamic> toJson() => {'city': city, 'country': country};
  factory PlaceData.fromJson(Map<String, dynamic> json) {
    return PlaceData(city: json['city'], country: json['country']);
  }
}

class PlacesService {
  static final PlacesService _instance = PlacesService._internal();
  factory PlacesService() => _instance;
  PlacesService._internal();

  DateTime _lastRequestTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Returns City and Country for a given coordinate. Uses SharedPreferences caching.
  Future<PlaceData?> getPlaceName(double lat, double lng) async {
    // Round coords to ~1km accuracy for caching to prevent overwhelming the API
    final String cacheKey = 'geo_${lat.toStringAsFixed(2)}_${lng.toStringAsFixed(2)}';
    
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(cacheKey)) {
      final String cached = prefs.getString(cacheKey)!;
      try {
         return PlaceData.fromJson(jsonDecode(cached));
      } catch (e) {
         prefs.remove(cacheKey);
      }
    }

    try {
      final timeSinceLast = DateTime.now().difference(_lastRequestTime);
      if (timeSinceLast.inMilliseconds < 1200) {
        await Future.delayed(Duration(milliseconds: 1200 - timeSinceLast.inMilliseconds));
      }

      final Uri uri = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&zoom=10&addressdetails=1');
      final response = await http.get(uri, headers: {
        'User-Agent': 'ChithramApp/1.0', // Required by Nominatim Terms of Use
        'Accept-Language': 'en-US,en;q=0.5',
      });
      
      _lastRequestTime = DateTime.now();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data != null && data['address'] != null) {
          final address = data['address'];
          // Fallbacks for different geographic structures
          final String city = address['city'] ?? address['town'] ?? address['village'] ?? address['county'] ?? address['state'] ?? 'Unknown Area';
          final String country = address['country'] ?? 'Unknown Country';
          
          final place = PlaceData(city: city, country: country);
          if (city != 'Unknown Area') {
            await prefs.setString(cacheKey, jsonEncode(place.toJson()));
          }
          return place;
        }
      } else {
        print('PlacesService: HTTP Error ${response.statusCode} - ${response.body}');
        throw Exception('Geocoding API failed: ${response.statusCode}');
      }
    } catch (e) {
      print('PlacesService: Error fetching location: $e');
      rethrow; // Propagate the error so PhotoProvider knows NOT to cache empty results
    }
    
    return null;
  }
}
