// weather_client.dart — daily heat/humidity context for training load.
//
// WHY: identical sessions are not identical stimulus. Padel outdoors at 34°C
// and 70% humidity drives heart rate, sweat loss and next-day recovery far
// harder than the same session indoors in July. Without this the coach sees an
// unexplained HR spike and has no way to attribute it.
//
// Open-Meteo is used because it needs NO API KEY and no account — one less
// credential to manage, and nothing to expire. Non-commercial use is free.
// https://open-meteo.com/
//
// Stored as `wx_`-prefixed keys in metric_series (same convention as the `hk_`
// health-import keys) so it can never collide with a DerivationEngine metric.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/day_label.dart';
import '../data/db.dart';

class WeatherClient {
  static const String _base = 'https://api.open-meteo.com/v1/forecast';

  final http.Client _http;
  WeatherClient({http.Client? client}) : _http = client ?? http.Client();

  /// Last known coordinates, so a denied/unavailable fix still gets weather for
  /// roughly the right place rather than none at all.
  static const _kLat = 'wx_last_lat';
  static const _kLon = 'wx_last_lon';

  /// Resolve a position without prompting: uses the last known fix, falling
  /// back to a cached one. Deliberately never requests permission — weather is
  /// a background nicety and must not trigger a permission dialog on its own.
  Future<({double lat, double lon})?> _location() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        final pos = await Geolocator.getLastKnownPosition();
        if (pos != null) {
          await LocalDb.setCursor(_kLat, pos.latitude.toString());
          await LocalDb.setCursor(_kLon, pos.longitude.toString());
          return (lat: pos.latitude, lon: pos.longitude);
        }
      }
    } catch (_) {
      /* fall through to the cache */
    }
    final lat = double.tryParse(await LocalDb.getCursor(_kLat) ?? '');
    final lon = double.tryParse(await LocalDb.getCursor(_kLon) ?? '');
    if (lat != null && lon != null) return (lat: lat, lon: lon);
    return null;
  }

  /// Fetch daily weather for the last [days] days and store it against each
  /// local day. Returns the number of days written; 0 on any failure.
  ///
  /// Never throws: weather is context, not a core metric, so a dead network or
  /// a missing location must degrade to "no weather" rather than break a sync.
  Future<int> syncRecent({int days = 7}) async {
    try {
      final loc = await _location();
      if (loc == null) {
        debugPrint('[weather] no location available — skipping');
        return 0;
      }

      final now = DateTime.now();
      final start = now.subtract(Duration(days: days));
      final uri = Uri.parse(_base).replace(queryParameters: {
        'latitude': loc.lat.toStringAsFixed(3),
        'longitude': loc.lon.toStringAsFixed(3),
        'daily': 'temperature_2m_max,temperature_2m_min,'
            'apparent_temperature_max,relative_humidity_2m_mean,'
            'precipitation_sum',
        'timezone': 'auto', // day boundaries in LOCAL time, matching our labels
        'start_date': dayLabelOf(start),
        'end_date': dayLabelOf(now),
      });

      final resp = await _http.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('[weather] HTTP ${resp.statusCode}');
        return 0;
      }

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return 0;
      final daily = decoded['daily'];
      if (daily is! Map) return 0;

      final dates = (daily['time'] as List?) ?? const [];
      List<double?> col(String k) => ((daily[k] as List?) ?? const [])
          .map((v) => (v as num?)?.toDouble())
          .toList();

      final tMax = col('temperature_2m_max');
      final tMin = col('temperature_2m_min');
      final feels = col('apparent_temperature_max');
      final rh = col('relative_humidity_2m_mean');
      final precip = col('precipitation_sum');

      final db = await LocalDb.instance;
      var written = 0;
      await db.transaction((txn) async {
        for (var i = 0; i < dates.length; i++) {
          final day = '${dates[i]}';
          Future<void> put(String key, double? v) async {
            if (v == null || v.isNaN || v.isInfinite) return;
            await txn.insert(
              'metric_series',
              {'date': day, 'key': key, 'value': v},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            written++;
          }

          await put('wx_temp_max_c', i < tMax.length ? tMax[i] : null);
          await put('wx_temp_min_c', i < tMin.length ? tMin[i] : null);
          await put('wx_feels_max_c', i < feels.length ? feels[i] : null);
          await put('wx_humidity_pct', i < rh.length ? rh[i] : null);
          await put('wx_precip_mm', i < precip.length ? precip[i] : null);
        }
      });

      debugPrint('[weather] wrote $written scalars across ${dates.length} days');
      return dates.length;
    } catch (e) {
      debugPrint('[weather] sync failed: $e');
      return 0;
    }
  }
}
