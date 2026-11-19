import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

/// Shows the motion events that ESP32-001 stored in Supabase
/// (`event_history`, event_type MOTION) and whether each row has already
/// been copied to MySQL (`mysql_synced`). This proves end to end that
/// Camera 1 motion -> ESP32-001 -> Supabase -> MySQL is working.
class MotionEventsPanel extends StatefulWidget {
  const MotionEventsPanel({
    super.key,
    this.limit = 15,
    this.fill = false,
    this.maxListHeight = 380,
  });
  final int limit;

  /// true: the panel takes the height its parent gives it (e.g. the camera
  /// card's height) and the event list scrolls inside it.
  final bool fill;

  /// Used when [fill] is false: the list scrolls after this height.
  final double maxListHeight;

  @override
  State<MotionEventsPanel> createState() => _MotionEventsPanelState();
}

class _MotionEventsPanelState extends State<MotionEventsPanel> {
  List<Map<String, dynamic>> _rows = const [];
  String? _error;
  bool _loading = true;
  Timer? _timer;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('event_history')
          .select('id,device_id,event_type,message,severity,payload_json,mysql_synced,created_at')
          .eq('event_type', 'MOTION')
          .order('created_at', ascending: false)
          .limit(widget.limit);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows as List);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read motion events from Supabase: $e';
        _loading = false;
      });
    }
  }

  String _time(dynamic value) {
    final dt = DateTime.tryParse('$value')?.toLocal();
    if (dt == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    return GlassPanel(
      radius: 22,
      blur: 18,
      borderColor: AppColors.orange.withValues(alpha: .26),
      tint: dark
          ? AppColors.darkCard.withValues(alpha: .66)
          : AppColors.lightCard.withValues(alpha: .68),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.directions_run_rounded, color: AppColors.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Stored motion events',
                  style: TextStyle(
                      color: AppTheme.textPrimary(context),
                      fontWeight: FontWeight.w800,
                      fontSize: 16)),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _load,
              icon: Icon(Icons.refresh_rounded,
                  color: AppTheme.brandForeground(context)),
            ),
          ]),
          Text(
            'Camera 1 motion saved by ESP32-001 in Supabase. "MySQL synced" '
            'appears once the local sync worker has copied the row.',
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (_loading)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(color: AppColors.orange),
            ))
          else if (_error != null)
            Text(_error!,
                style: TextStyle(
                    color: AppTheme.warningForeground(context), fontSize: 12))
          else if (_rows.isEmpty)
            Text('No motion stored yet. Walk in front of Camera 1 to create one.',
                style: TextStyle(color: AppTheme.textSecondary(context)))
          else if (widget.fill)
            Expanded(child: _list(shrinkWrap: false))
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxListHeight),
              child: _list(shrinkWrap: true),
            ),
        ],
      ),
    );
  }

  /// The event rows scroll inside the panel instead of stretching the page.
  Widget _list({required bool shrinkWrap}) => Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _scroll,
          shrinkWrap: shrinkWrap,
          padding: const EdgeInsets.only(right: 10),
          itemCount: _rows.length,
          itemBuilder: (context, i) => _eventTile(_rows[i]),
        ),
      );

  Widget _eventTile(Map<String, dynamic> row) {
    var payload = row['payload_json'];
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {}
    }
    final p = payload is Map ? payload : const {};
    final synced = row['mysql_synced'] == true;
    final severity = (row['severity'] as num?)?.toInt() ?? 1;
    final color = severity >= 2 ? AppColors.red : AppColors.orange;
    final details = <String>[
      if (p['pan'] != null) 'pan ${p['pan']}° / tilt ${p['tilt']}°',
      if (p['auto_follow'] == true) 'auto-follow on',
      if (p['armed'] == true) 'armed',
    ].join('  •  ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wraps onto two lines in narrow columns instead of squeezing the time.
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(_time(row['created_at']),
                    style: TextStyle(
                        color: AppTheme.textPrimary(context),
                        fontWeight: FontWeight.w700)),
              ),
              _badge('Supabase', AppColors.green),
              _badge(synced ? 'MySQL synced' : 'MySQL pending',
                  synced ? AppColors.green : AppColors.amber),
            ],
          ),
          const SizedBox(height: 4),
          Text('${row['message'] ?? 'Motion detected'}',
              style: TextStyle(color: AppTheme.textPrimary(context))),
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(details,
                  style: TextStyle(
                      color: AppTheme.textSecondary(context), fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: .5)),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
      );
}
