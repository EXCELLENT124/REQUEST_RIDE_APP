import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models.dart';

class RouteResult {
  const RouteResult({
    required this.distanceKm,
    required this.durationMinutes,
    required this.points,
  });

  final double distanceKm;
  final int durationMinutes;
  final List<GeoPoint> points;
}

class MappingService {
  MappingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<GeoPoint> reverseGeocode(GeoPoint point) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': '${point.latitude}',
      'lon': '${point.longitude}',
      'format': 'jsonv2',
      'zoom': '18',
      'addressdetails': '1',
    });
    final response = await _client.get(uri, headers: const {
      'User-Agent': 'RequestRide/0.1 (ride-hailing test application)',
      'Accept-Language': 'en-ZA,en',
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return point;
    }
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    return GeoPoint(
      point.latitude,
      point.longitude,
      label: value['display_name'] as String?,
    );
  }

  Future<List<GeoPoint>> searchAddress(String query) async {
    final text = query.trim();
    if (text.length < 3) return const [];
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': '$text, South Africa',
      'format': 'jsonv2',
      'countrycodes': 'za',
      'limit': '5',
      'addressdetails': '1',
    });
    final response = await _client.get(uri, headers: const {
      'User-Agent': 'RequestRide/0.1 (ride-hailing test application)',
      'Accept-Language': 'en-ZA,en',
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Address search is temporarily unavailable.');
    }
    final rows = jsonDecode(response.body) as List<dynamic>;
    return rows
        .map((value) => value as Map<String, dynamic>)
        .map((value) => GeoPoint(
              double.parse(value['lat'] as String),
              double.parse(value['lon'] as String),
              label: value['display_name'] as String?,
            ))
        .toList();
  }

  Future<RouteResult> route(GeoPoint start, GeoPoint end) async {
    final coordinates = '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}';
    final uri = Uri.https(
      'router.project-osrm.org',
      '/route/v1/driving/$coordinates',
      {'overview': 'full', 'geometries': 'geojson', 'steps': 'false'},
    );
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Road routing is temporarily unavailable.');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = body['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty) throw Exception('No driving route was found.');
    final route = routes.first as Map<String, dynamic>;
    final geometry = route['geometry'] as Map<String, dynamic>;
    final coordinatesJson = geometry['coordinates'] as List<dynamic>;
    return RouteResult(
      distanceKm: (route['distance'] as num).toDouble() / 1000,
      durationMinutes: ((route['duration'] as num).toDouble() / 60).ceil(),
      points: coordinatesJson.map((coordinate) {
        final values = coordinate as List<dynamic>;
        return GeoPoint(
          (values[1] as num).toDouble(),
          (values[0] as num).toDouble(),
        );
      }).toList(),
    );
  }
}
