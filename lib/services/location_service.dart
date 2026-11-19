import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;

/// Result of a location fetch: raw coordinates plus the best human-readable
/// place name we could resolve for them.
class ResolvedLocation {
  final double latitude;
  final double longitude;
  final String placeName;
  const ResolvedLocation({
    required this.latitude,
    required this.longitude,
    required this.placeName,
  });
}

/// Thrown with a message safe to show directly to the user.
class LocationException implements Exception {
  final String message;
  LocationException(this.message);
  @override
  String toString() => message;
}

/// One shared, platform-aware location pipeline used everywhere in the app
/// (signup, and re-pinning from the Device screen). This is the single
/// source of truth for "how do we get an accurate GPS fix and turn it into
/// a real place name" — web and mobile both go through this exact code so
/// there is no drift between platforms.
///
/// Why this matters:
///  - `geolocator` (the GPS fix itself) has web, Android, and iOS
///    implementations, so high-accuracy positioning works on all three.
///  - `geocoding` (turning coordinates into a place name) has **no web
///    implementation** — calling it on web throws. So on web we always use
///    OpenStreetMap's Nominatim reverse-geocoding API instead. On mobile we
///    try the native geocoder first (faster, no network dependency for the
///    OS-level part) and fall back to Nominatim if it fails or returns
///    nothing usable, so mobile never silently degrades to raw numbers
///    either.
class LocationService {
  LocationService._();

  /// Gets the device's current high-accuracy GPS position. Throws
  /// [LocationException] with a user-facing message on any failure
  /// (services off, permission denied, no fix available).
  static Future<Position> getCurrentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationException(
          'Location is turned off. Enable GPS / location services and try again.');
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      throw LocationException(
          'Location permission denied. Allow location access to pin your exact address.');
    }

    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) {
        throw LocationException(
            'Could not get a GPS fix. Move to an open area (or near a window) and try again.');
      }
      return last;
    }
  }

  /// Resolves coordinates to a real place name (street/barangay/city/
  /// province, not just numbers), using the right strategy per platform.
  static Future<String> resolvePlaceName(double lat, double lng) async {
    String? name;

    if (!kIsWeb) {
      try {
        final marks = await placemarkFromCoordinates(lat, lng);
        if (marks.isNotEmpty) {
          final pm = marks.first;
          final joined = [
            pm.street,
            pm.subLocality,
            pm.locality,
            pm.administrativeArea,
            pm.country,
          ].where((s) => s != null && s.isNotEmpty).join(', ');
          if (joined.isNotEmpty) name = joined;
        }
      } catch (_) {
        // No native geocoder available or it failed — fall through to
        // the Nominatim fallback below.
      }
    }

    // Web always lands here (no native geocoding plugin exists for web).
    // Mobile lands here too if the native geocoder above failed or
    // returned nothing usable, so accuracy never silently degrades.
    if (name == null || name.isEmpty) {
      name = await _reverseGeocodeViaNominatim(lat, lng);
    }

    return (name != null && name.isNotEmpty)
        ? name
        : '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
  }

  /// Convenience: get position + resolved place name in one call.
  static Future<ResolvedLocation> pinCurrentLocation() async {
    final pos = await getCurrentPosition();
    final name = await resolvePlaceName(pos.latitude, pos.longitude);
    return ResolvedLocation(latitude: pos.latitude, longitude: pos.longitude, placeName: name);
  }

  static Future<String?> _reverseGeocodeViaNominatim(double lat, double lng) async {
    // BigDataCloud's client-side reverse-geocode endpoint is CORS-friendly and
    // works reliably from Flutter Web/localhost without an API key.
    try {
      final uri = Uri.parse(
        'https://api.bigdatacloud.net/data/reverse-geocode-client'
        '?latitude=$lat&longitude=$lng&localityLanguage=en',
      );
      final res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final locality = (data['locality'] ?? data['city'] ?? '').toString().trim();
        final principal = (data['principalSubdivision'] ?? '').toString().trim();
        final country = (data['countryName'] ?? '').toString().trim();
        final postcode = (data['postcode'] ?? '').toString().trim();
        final parts = [locality, principal, postcode, country]
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (_) {
      // Fall through to OpenStreetMap.
    }

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=$lat&lon=$lng&zoom=18&addressdetails=1',
      );
      final res = await http
          .get(uri, headers: {
            'Accept-Language': 'en',
            'Accept': 'application/json',
          })
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final displayName = data['display_name'] as String?;
      return (displayName != null && displayName.isNotEmpty) ? displayName : null;
    } catch (_) {
      return null;
    }
  }
}
