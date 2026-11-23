import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

/// Notification-level controls belong in Settings > Notifications only.
/// BFP contact editing belongs in Settings > BFP Contact Details only.
class PyroguardSafetyPanel extends StatefulWidget {
  const PyroguardSafetyPanel({super.key});
  @override
  State<PyroguardSafetyPanel> createState() => _PyroguardSafetyPanelState();
}

class _PyroguardSafetyPanelState extends State<PyroguardSafetyPanel> {
  String mode = 'important';
  bool dailySummary = true;
  bool loading = true;
  bool saving = false;
  String? error;

  Future<void> _load() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) {
      if (mounted) setState(() { loading = false; error = 'Sign in to manage notifications.'; });
      return;
    }
    try {
      final row = await client.from('pyroguard_notification_preferences')
          .select('mode,daily_summary').eq('user_id',uid).maybeSingle();
      if (mounted) {
        setState(() {
        mode = (row?['mode'] as String?) ?? 'important';
        dailySummary = row?['daily_summary'] as bool? ?? true;
        error = null;
      });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Notification level settings are unavailable. Apply the Supabase notification preferences migration.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _save({String? nextMode, bool? nextSummary}) async {
    if (saving) return;
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    final desiredMode = nextMode ?? mode;
    final desiredSummary = nextSummary ?? dailySummary;
    setState(() { saving = true; error = null; });
    try {
      await client.from('pyroguard_notification_preferences').upsert({
        'user_id': uid, 'mode': desiredMode, 'daily_summary': desiredSummary,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
      final saved = await client.from('pyroguard_notification_preferences')
          .select('mode,daily_summary').eq('user_id',uid).single();
      if (saved['mode'] != desiredMode || saved['daily_summary'] != desiredSummary) {
        throw StateError('Notification preference read-back mismatch.');
      }
      if (mounted) setState(() { mode = desiredMode; dailySummary = desiredSummary; });
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save these preferences. Check your connection and Supabase permissions.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    // Same glass card as the other panels (GlassStyle has no blur filter, so
    // it does not cause the washed-out text of a blur inside a blur).
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Notification Level & Daily Summary', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 6),
        Text('These controls are separate from your BFP contact details. Fire alarms remain active independently.', style: TextStyle(color: secondary)),
        if (loading || saving) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: AppColors.orange)),
        if (!loading) ...[
          const SizedBox(height: 12),
          // Always-visible choice chips instead of a pop-up dropdown: the
          // pop-up list rendered see-through over the page and was unreadable.
          Text('Notification level', style: TextStyle(color: secondary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final o in const [
              ('all', 'All sensor activity', Icons.sensors_rounded),
              ('important', 'Important incidents', Icons.warning_amber_rounded),
              ('critical', 'Critical emergencies', Icons.local_fire_department_rounded),
            ])
              Builder(builder: (context) {
                final current = ['all', 'important', 'critical'].contains(mode) ? mode : 'important';
                final selected = current == o.$1;
                return ChoiceChip(
                  avatar: Icon(o.$3, size: 18, color: selected ? Colors.white : AppColors.orange),
                  label: Text(o.$2),
                  selected: selected,
                  showCheckmark: false,
                  selectedColor: AppColors.orange,
                  backgroundColor: AppTheme.isDark(context) ? AppColors.darkCard : Colors.white,
                  side: BorderSide(color: selected ? AppColors.orange : AppColors.orange.withValues(alpha: .45)),
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : primary,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  onSelected: saving || selected ? null : (_) => _save(nextMode: o.$1),
                );
              }),
          ]),
          const SizedBox(height: 4),
          Text(
            switch (['all', 'important', 'critical'].contains(mode) ? mode : 'important') {
              'all' => 'You get alerts for every sensor change, warnings and incidents.',
              'critical' => 'Only critical emergencies (confirmed fire, intrusion while armed).',
              _ => 'Warnings, intrusions and incidents; routine sensor changes are skipped.',
            },
            style: TextStyle(color: secondary, fontSize: 12),
          ),
          Material(type: MaterialType.transparency, child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text('Daily sensor summary', style: TextStyle(color: primary)),
            subtitle: Text('Delivery requires a configured notification backend.', style: TextStyle(color: secondary)),
            value: dailySummary,
            activeThumbColor: AppColors.orange,
            onChanged: saving ? null : (v) => _save(nextSummary: v),
          )),
        ],
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: AppTheme.statusForeground(context, AppColors.red), fontSize: 12))),
      ]),
    );
  }
}
