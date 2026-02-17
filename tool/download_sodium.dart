import 'dart:io';
import 'package:http/http.dart' as http;

void main() async {
  // Use sodium-sumo.js from browsers-sumo directory
  // https://github.com/jedisct1/libsodium.js/blob/master/dist/browsers-sumo/sodium.js is the page, raw is:
  final url = Uri.parse('https://raw.githubusercontent.com/jedisct1/libsodium.js/master/dist/browsers-sumo/sodium.js');
  final file = File('web/sodium.js');
  print('Downloading sodium-sumo.js from ${url} to ${file.path}...');
  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      print('Download complete. Size: ${response.bodyBytes.length} bytes.');
    } else {
      print('Download failed. Status: ${response.statusCode}');
      exit(1);
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}
