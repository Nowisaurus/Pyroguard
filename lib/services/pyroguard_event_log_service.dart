import 'package:supabase_flutter/supabase_flutter.dart';

/// Read-only, authenticated incident log backed by the existing event_history.
/// No local examples, fabricated incident timestamps, or invented measurements.
class PyroGuardEventLogService {
  const PyroGuardEventLogService();

  Future<List<Map<String, dynamic>>> recent({int limit = 400}) async {
    final db = Supabase.instance.client;
    if (db.auth.currentUser == null) return [];
    final rows = await db.from('event_history')
        .select('id,device_id,event_type,message,severity,created_at,payload_json')
        .order('created_at', ascending: false).limit(limit);
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  static DateTime? eventDate(Map<String, dynamic> row) =>
      DateTime.tryParse('${row['created_at'] ?? ''}')?.toLocal();
}
