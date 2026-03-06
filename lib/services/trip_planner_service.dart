import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TripPlannerService {
  static final TripPlannerService _instance = TripPlannerService._internal();
  factory TripPlannerService() => _instance;
  TripPlannerService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _apiKeyStorageKey = 'gemini_api_key';

  // ─── API Key ────────────────────────────────────────────────────────────────

  Future<void> saveApiKey(String key) async =>
      _storage.write(key: _apiKeyStorageKey, value: key.trim());

  Future<String?> getApiKey() async =>
      _storage.read(key: _apiKeyStorageKey);

  Future<void> clearApiKey() async =>
      _storage.delete(key: _apiKeyStorageKey);

  // ─── Trip Plan Cache (SharedPreferences) ────────────────────────────────────

  /// Returns a stable key for the cached plan of a given city.
  static String _cacheKey(String city) =>
      'trip_plan_${city.toLowerCase().replaceAll(' ', '_')}';

  /// Loads a previously cached trip plan for [city]. Returns null if none.
  Future<String?> getCachedPlan(String city) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cacheKey(city));
  }

  /// Persists a generated trip plan for [city] to local SharedPreferences.
  Future<void> savePlan(String city, String plan) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(city), plan);
    // Also store when it was cached (ISO 8601) so we can show freshness info
    await prefs.setString(
        '${_cacheKey(city)}_date', DateTime.now().toIso8601String());
  }

  /// Returns the date the plan for [city] was last generated, or null.
  Future<DateTime?> getCachedPlanDate(String city) async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('${_cacheKey(city)}_date');
    return str == null ? null : DateTime.tryParse(str);
  }

  /// Clears the cached plan for [city].
  Future<void> clearCachedPlan(String city) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey(city));
    await prefs.remove('${_cacheKey(city)}_date');
  }

  // ─── Plan Generation ────────────────────────────────────────────────────────

  /// Generates a comprehensive trip plan using the Gemini API.
  Future<String> generateTripPlan({
    required String city,
    required String timeCapsuleInfo,
    required String memoryCountInfo,
    required List<String> placesVisited,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception("API Key not found. Please provide a Gemini API Key.");
    }

    final model = GenerativeModel(
      model: 'gemini-flash-latest',
      apiKey: apiKey,
    );

    final prompt = '''
You are a highly experienced and expert travel curator.
The user is viewing their past travels to "$city".
Here is some context about their previous trips to $city:
- Total memories (photos/videos): $memoryCountInfo
- Time capsule / frequency: $timeCapsuleInfo
- Notable places they previously visited or photographed: ${placesVisited.isEmpty ? 'None extracted' : placesVisited.join(', ')}

Based on this, curate a completely new, immersive, and highly detailed trip plan for a return visit to $city.
Format the entire response in beautiful Markdown, adhering strictly to the following sections and listing formats:

## Best Time to Travel
Recommend the best months to visit and how many days are ideal.

## Travel Modes
Nearest airports, major train routes, or driving tips to reach the destination.

## Top Sites
For every site, use exactly this bullet point format:
- **[Site Name]**: [Short description of why they should visit it, blending iconic spots with hidden gems.]

## Hotels
Categorised loosely by budget. For every hotel, use exactly this bullet point format:
- **[Hotel Name]**: [Short description of the vibe and budget.]

## Local Food
Specific dishes and venue types. For every food/restaurant, use exactly this bullet point format:
- **[Food or Restaurant Name]**: [Short description of why it's a must-try.]

Make the response engaging, enthusiastic, and highly readable. Do not include raw JSON. Return pure Markdown.
''';

    try {
      final content = [Content.text(prompt)];
      final response = await model.generateContent(content);

      if (response.text == null || response.text!.isEmpty) {
        throw Exception("Received an empty response from Gemini.");
      }

      final plan = response.text!;
      // Persist to local cache immediately after a successful generation
      await savePlan(city, plan);
      return plan;
    } catch (e) {
      debugPrint("Gemini generation error: $e");
      if (e.toString().contains("API key not valid")) {
        throw Exception("The provided API key is invalid or expired.");
      }
      throw Exception(
          "Failed to generate trip plan: ${e.toString().replaceAll('Exception:', '')}");
    }
  }
}
