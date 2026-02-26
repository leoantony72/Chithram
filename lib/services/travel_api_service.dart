import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class TravelInfo {
  final String title;
  final String extract;
  final String? thumbnail;

  TravelInfo({required this.title, required this.extract, this.thumbnail});

  factory TravelInfo.fromJson(Map<String, dynamic> json) {
    return TravelInfo(
      title: json['title'] ?? '',
      extract: json['extract'] ?? '',
      thumbnail: json['thumbnail'] != null ? json['thumbnail']['source'] : null,
    );
  }
}

class NewsArticle {
  final String title;
  final String link;
  final String pubDate;
  final String source;

  NewsArticle({
    required this.title,
    required this.link,
    required this.pubDate,
    required this.source,
  });
}

class AttractionImage {
  final String title;
  final String imageUrl;

  AttractionImage({required this.title, required this.imageUrl});
}

class WeatherInfo {
  final double temperature;
  final int weatherCode;

  WeatherInfo({required this.temperature, required this.weatherCode});

  String get condition {
    // Basic WMO Weather interpretation
    if (weatherCode == 0) return "Clear sky";
    if (weatherCode >= 1 && weatherCode <= 3) return "Partly cloudy";
    if (weatherCode >= 45 && weatherCode <= 48) return "Fog";
    if (weatherCode >= 51 && weatherCode <= 67) return "Rain";
    if (weatherCode >= 71 && weatherCode <= 77) return "Snow";
    if (weatherCode >= 80 && weatherCode <= 82) return "Rain showers";
    if (weatherCode >= 95) return "Thunderstorm";
    return "Unknown";
  }

  String get iconStr {
    if (weatherCode == 0) return "☀️";
    if (weatherCode >= 1 && weatherCode <= 3) return "⛅";
    if (weatherCode >= 45 && weatherCode <= 48) return "🌫️";
    if (weatherCode >= 51 && weatherCode <= 67) return "🌧️";
    if (weatherCode >= 71 && weatherCode <= 77) return "❄️";
    if (weatherCode >= 80 && weatherCode <= 82) return "🌦️";
    if (weatherCode >= 95) return "⛈️";
    return "☁️";
  }
}

class TravelApiService {
  static final TravelApiService _instance = TravelApiService._internal();
  factory TravelApiService() => _instance;
  TravelApiService._internal();

  /// Fetches a high-quality summary and thumbnail from Wikipedia for a given city.
  Future<TravelInfo?> getDestinationSummary(String city) async {
    final query = Uri.encodeComponent(city);
    final uri = Uri.parse('https://en.wikipedia.org/api/rest_v1/page/summary/$query');

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'ChithramApp/1.0',
      }).timeout(const Duration(seconds: 7));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['type'] != 'disambiguation' && data['extract'] != null) {
          return TravelInfo.fromJson(data);
        }
      }
    } catch (e) {
      // Suppress full stack trace for standard offline drops
      print('TravelApiService: Could not fetch Wikipedia summary for $city.');
    }
    return null;
  }

  /// Fetches recent tourism news or attractions for the city using Google News RSS
  Future<List<NewsArticle>> getRecentAttractions(String city) async {
    final query = Uri.encodeComponent('$city tourism new attractions');
    final uri = Uri.parse('https://news.google.com/rss/search?q=$query&hl=en-US&gl=US&ceid=US:en');
    
    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'ChithramApp/1.0',
      }).timeout(const Duration(seconds: 7));
      
      if (response.statusCode == 200) {
        final document = XmlDocument.parse(response.body);
        final items = document.findAllElements('item').take(7).toList();
        
        return items.map((item) {
           return NewsArticle(
              title: item.findElements('title').first.innerText,
              link: item.findElements('link').first.innerText,
              pubDate: item.findElements('pubDate').firstOrNull?.innerText ?? '',
              source: item.findElements('source').firstOrNull?.innerText ?? 'Travel News',
           );
        }).toList();
      }
    } catch (e) {
      print('TravelApiService: Secondary news feed for $city unavailable.');
    }
    
    return [];
  }

  /// Fetches 5 high-quality images of local landmarks using the Wikipedia Action API
  Future<List<AttractionImage>> getAttractionImages(String city) async {
    final query = Uri.encodeComponent('$city landmark');
    final uri = Uri.parse('https://en.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=$query&gsrlimit=5&prop=pageimages&format=json&pithumbsize=800');

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'ChithramApp/1.0',
      }).timeout(const Duration(seconds: 7));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        
        if (pages != null) {
          final List<AttractionImage> result = [];
          pages.forEach((key, value) {
            final title = value['title'] as String?;
            final thumbnail = value['thumbnail'];
            if (title != null && thumbnail != null) {
               final source = thumbnail['source'] as String?;
               if (source != null) {
                  result.add(AttractionImage(title: title, imageUrl: source));
               }
            }
          });
          return result;
        }
      }
    } catch (e) {
      print('TravelApiService: Wikipedia landmarks for $city failed to connect.');
    }
    return [];
  }

  /// Fetches live weather conditions from Open-Meteo free API
  Future<WeatherInfo?> getLiveWeather(double lat, double lon) async {
    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code');

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'ChithramApp/1.0',
      }).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final current = data['current'];
        if (current != null) {
           return WeatherInfo(
             temperature: (current['temperature_2m'] as num).toDouble(),
             weatherCode: current['weather_code'] as int,
           );
        }
      }
    } catch (e) {
      print('TravelApiService: Open-Meteo weather ping bypassed.');
    }
    return null;
  }
}
