import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/room_sensor_service.dart';
import '../../theme.dart';
import '../../widgets/cost_estimate_panel.dart';
import '../../widgets/pg_ui.dart';

final _when = DateFormat('MMM d, yyyy h:mm a');
SupabaseClient get _db => Supabase.instance.client;

void _snack(BuildContext context, String text) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

String _time(dynamic v) {
  final d = DateTime.tryParse('${v ?? ''}');
  return d == null ? '-' : _when.format(d.toLocal());
}

// ═════════════════════════════════════════════════════════════════════════
// 1. Hardware cost: the only place prices can be changed.
// ═════════════════════════════════════════════════════════════════════════
class AdminCostCatalogPanel extends StatefulWidget {
  const AdminCostCatalogPanel({super.key});
  @override
  State<AdminCostCatalogPanel> createState() => _AdminCostCatalogPanelState();
}

class _AdminCostCatalogPanelState extends State<AdminCostCatalogPanel> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await CostCatalog.load();
      if (mounted) {
        setState(() {
        _items = list;
        _loading = false;
        _error = null;
      });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
        _loading = false;
        _error = 'Could not load the price list: $e';
      });
      }
    }
  }

  Future<void> _edit(Map<String, dynamic>? item) async {
    final name = TextEditingController(text: '${item?['item'] ?? ''}');
    final qty = TextEditingController(text: item == null ? '1' : CostCatalog.qty(CostCatalog.n(item['quantity'])));
    final unit = TextEditingController(text: '${item?['unit'] ?? 'pc'}');
    final price = TextEditingController(text: item == null ? '' : CostCatalog.n(item['unit_price']).toStringAsFixed(2));
    final supplier = TextEditingController(text: '${item?['supplier'] ?? 'Makerlab Electronics PH'}');
    final url = TextEditingController(text: '${item?['source_url'] ?? ''}');
    final notes = TextEditingController(text: '${item?['notes'] ?? ''}');
    var cat = '${item?['category'] ?? 'Hardware'}';
    var checked = DateTime.tryParse('${item?['price_checked_on'] ?? ''}') ?? DateTime.now();

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(item == null ? 'Add price item' : 'Edit price item'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  for (final c in const ['Hardware', 'Labor', 'Other'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text(c), selected: cat == c, onSelected: (_) => setD(() => cat = c)),
                    ),
                ]),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Item')),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: unit, decoration: const InputDecoration(labelText: 'Unit'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Unit price', prefixText: '₱ '),
                    ),
                  ),
                ]),
                if (cat == 'Labor')
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => price.text = kLaborRatePerHour.toStringAsFixed(2),
                      child: Text('Use NCR-28 minimum wage (₱${kLaborRatePerHour.toStringAsFixed(2)}/hour)'),
                    ),
                  ),
                TextField(controller: supplier, decoration: const InputDecoration(labelText: 'Supplier')),
                TextField(controller: url, decoration: const InputDecoration(labelText: 'Product page (source)')),
                TextField(controller: notes, maxLength: 300, decoration: const InputDecoration(labelText: 'Note (optional)')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('Price checked on ${DateFormat('MMM d, yyyy').format(checked)}'),
                    onPressed: () async {
                      final p = await showDatePicker(
                          context: ctx, initialDate: checked, firstDate: DateTime(2025), lastDate: DateTime.now());
                      if (p != null) setD(() => checked = p);
                    },
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            if (item != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: Text('Delete', style: TextStyle(color: AppTheme.dangerForeground(ctx))),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      if (action == 'delete' && item != null) {
        await _db.from('pyroguard_cost_catalog').delete().eq('id', item['id']);
      } else if (action == 'save') {
        final row = {
          'category': cat,
          'item': name.text.trim().isEmpty ? 'Item' : name.text.trim(),
          'quantity': double.tryParse(qty.text.replaceAll(',', '.')) ?? 1,
          'unit': unit.text.trim().isEmpty ? 'pc' : unit.text.trim(),
          'unit_price': double.tryParse(price.text.replaceAll(',', '')) ?? 0,
          'supplier': supplier.text.trim().isEmpty ? 'Makerlab Electronics PH' : supplier.text.trim(),
          'source_url': url.text.trim().isEmpty ? null : url.text.trim(),
          'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
          'price_checked_on': checked.toIso8601String().substring(0, 10),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'updated_by': _db.auth.currentUser?.id,
        };
        if (item != null) {
          await _db.from('pyroguard_cost_catalog').update(row).eq('id', item['id']);
        } else {
          await _db.from('pyroguard_cost_catalog').insert({...row, 'sort_order': _items.length + 1});
        }
      }
      await _load();
      if (mounted) _snack(context, 'Price list updated. Homeowners see the change right away.');
    } catch (e) {
      if (mounted) _snack(context, 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final hw = CostCatalog.sum(_items, 'Hardware'), labor = CostCatalog.sum(_items, 'Labor');
    final other = CostCatalog.sum(_items, 'Other');
    return PgCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PgHeader(
          icon: Icons.request_quote_outlined,
          title: 'Hardware & Labor Prices',
          subtitle: 'Only administrators can change these. Homeowners see them read-only and download the pricing PDF.',
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange, foregroundColor: Colors.white),
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add item'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _items.isEmpty ? null : () => CostCatalog.downloadPdf(_items),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('PDF'),
          ),
          const Spacer(),
          IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20)),
        ]),
        if (_loading) const LinearProgressIndicator(color: AppColors.orange),
        if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 12)),
        for (final i in _items)
          InkWell(
            onTap: () => _edit(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                SizedBox(width: 70, child: PgBadge('${i['category']}', color: AppColors.orange)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i['item']}', style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w700)),
                    Text(
                      '${CostCatalog.qty(CostCatalog.n(i['quantity']))} ${i['unit']} × '
                      '${CostCatalog.peso.format(CostCatalog.n(i['unit_price']))} · ${i['supplier']} · '
                      'checked ${i['price_checked_on']}',
                      style: TextStyle(color: secondary, fontSize: 11),
                    ),
                  ]),
                ),
                Text(CostCatalog.peso.format(CostCatalog.line(i)),
                    style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w800)),
                const SizedBox(width: 4),
                Icon(Icons.edit_outlined, size: 17, color: secondary),
              ]),
            ),
          ),
        Divider(color: AppTheme.border(context), height: 18),
        Text(
          'Hardware ${CostCatalog.peso.format(hw)} · Labor ${CostCatalog.peso.format(labor)}'
          '${other > 0 ? ' · Other ${CostCatalog.peso.format(other)}' : ''} · '
          'Total ${CostCatalog.peso.format(hw + labor + other)}',
          style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// 2. Sensor health records: current state, history, maintenance records.
// ═════════════════════════════════════════════════════════════════════════
class AdminSensorHealthPanel extends StatefulWidget {
  const AdminSensorHealthPanel({super.key});
  @override
  State<AdminSensorHealthPanel> createState() => _AdminSensorHealthPanelState();
}

class _AdminSensorHealthPanelState extends State<AdminSensorHealthPanel> {
  List<Map<String, dynamic>> _state = const [];
  List<Map<String, dynamic>> _log = const [];
  List<Map<String, dynamic>> _maint = const [];
  bool _loading = true;
  bool _problemsOnly = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final st = await _db.from('pyroguard_sensor_health_state').select().order('controller_device_id').order('room_key');
      var q = _db.from('pyroguard_sensor_health_log').select();
      if (_problemsOnly) q = q.neq('status', 'OK');
      final lg = await q.order('observed_at', ascending: false).limit(200);
      final mt = await _db.from('pyroguard_sensor_maintenance').select().order('updated_at', ascending: false).limit(100);
      if (!mounted) return;
      setState(() {
        _state = [for (final r in st as List) Map<String, dynamic>.from(r as Map)];
        _log = [for (final r in lg as List) Map<String, dynamic>.from(r as Map)];
        _maint = [for (final r in mt as List) Map<String, dynamic>.from(r as Map)];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
        _loading = false;
        _error = 'Could not load sensor health: $e';
      });
      }
    }
  }

  static Color _color(String s) => switch (s) {
        'OK' => AppColors.green,
        'WARMING_UP' => AppColors.amber,
        _ => AppColors.red,
      };

  static String _label(String s) => switch (s) {
        'OK' => 'Working',
        'WARMING_UP' => 'Warming up',
        'NO_SIGNAL' => 'Damaged: no signal',
        _ => 'Damaged',
      };

  String _room(Map<String, dynamic> r) => RoomSensorService.label(
      '${r['controller_device_id'] ?? r['device_id'] ?? ''}', '${r['room_key'] ?? ''}');

  Future<void> _review(Map<String, dynamic> e) async {
    final note = TextEditingController(text: '${e['admin_note'] ?? ''}');
    var resolved = e['resolved_at'] != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${e['sensor_kind']} · ${_room(e)}'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_label('${e['status']}')} since ${_time(e['observed_at'])}'),
              Text('Reading: ${e['detail'] ?? '-'}', style: TextStyle(color: AppTheme.textSecondary(ctx), fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                controller: note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Admin check note (what was found / done)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Checked and resolved'),
                value: resolved,
                onChanged: (v) => setD(() => resolved = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _db.from('pyroguard_sensor_health_log').update({
        'admin_note': note.text.trim().isEmpty ? null : note.text.trim(),
        'resolved_at': resolved ? (e['resolved_at'] ?? DateTime.now().toUtc().toIso8601String()) : null,
        'resolved_by': resolved ? _db.auth.currentUser?.id : null,
      }).eq('id', e['id']);
      await _load();
    } catch (err) {
      if (mounted) _snack(context, 'Could not save: $err');
    }
  }

  Future<void> _editMaintenance(Map<String, dynamic> m) async {
    var installed = DateTime.tryParse('${m['installed_on'] ?? ''}');
    var checked = DateTime.tryParse('${m['last_checked_on'] ?? ''}');
    final notes = TextEditingController(text: '${m['notes'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Widget dateBtn(String label, DateTime? v, void Function(DateTime) set) => OutlinedButton(
              onPressed: () async {
                final p = await showDatePicker(
                    context: ctx, initialDate: v ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now());
                if (p != null) setD(() => set(p));
              },
              child: Text('$label: ${v == null ? '-' : DateFormat('MMM d, yyyy').format(v)}'),
            );
        return AlertDialog(
          title: Text('${m['sensor_kind']} · ${_room(m)}'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              dateBtn('Installed', installed, (d) => installed = d),
              const SizedBox(height: 6),
              dateBtn('Last checked', checked, (d) => checked = d),
              TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _db.from('pyroguard_sensor_maintenance').update({
        'installed_on': installed?.toIso8601String().substring(0, 10),
        'last_checked_on': checked?.toIso8601String().substring(0, 10),
        'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', m['id']);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final open = _log.where((e) => e['status'] != 'OK' && e['resolved_at'] == null).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PgCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PgHeader(
            icon: Icons.monitor_heart_outlined,
            title: 'Sensor Health Now',
            subtitle: 'Recorded automatically from every reading the ESP32 boards send.',
            actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20))],
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.orange),
          if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 12)),
          const SizedBox(height: 6),
          for (final s in _state)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                PgDot(_color('${s['status']}')),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('${s['sensor_kind']} · ${_room(s)}',
                      style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
                Text('${_label('${s['status']}')} · last reading ${_time(s['last_seen'])}',
                    style: TextStyle(color: secondary, fontSize: 11)),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      PgCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PgHeader(
            icon: Icons.history,
            title: 'Health History',
            subtitle: '$open open problem${open == 1 ? '' : 's'}. Tap a record to add a check note or mark it resolved.',
          ),
          Row(children: [
            ChoiceChip(
              label: const Text('Problems only'),
              selected: _problemsOnly,
              onSelected: (_) {
                setState(() => _problemsOnly = true);
                _load();
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('All changes'),
              selected: !_problemsOnly,
              onSelected: (_) {
                setState(() => _problemsOnly = false);
                _load();
              },
            ),
          ]),
          const SizedBox(height: 6),
          if (!_loading && _log.isEmpty) Text('No records.', style: TextStyle(color: secondary, fontSize: 12)),
          for (final e in _log)
            InkWell(
              onTap: () => _review(e),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.only(top: 4), child: PgDot(_color('${e['status']}'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['sensor_kind']} · ${_room(e)} · ${_label('${e['status']}')}',
                          style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w700)),
                      Text('${_time(e['observed_at'])} · ${e['detail'] ?? ''}',
                          style: TextStyle(color: secondary, fontSize: 11)),
                      if (e['admin_note'] != null)
                        Text('Note: ${e['admin_note']}', style: TextStyle(color: primary, fontSize: 11.5)),
                    ]),
                  ),
                  if (e['status'] != 'OK')
                    PgBadge(e['resolved_at'] == null ? 'Open' : 'Resolved',
                        color: e['resolved_at'] == null ? AppColors.amber : AppColors.green),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      PgCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PgHeader(
            icon: Icons.build_outlined,
            title: 'Maintenance Records',
            subtitle: 'Install and last-check dates entered by homeowners. Tap to correct.',
          ),
          if (!_loading && _maint.isEmpty)
            Text('No maintenance records yet.', style: TextStyle(color: secondary, fontSize: 12)),
          for (final m in _maint)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _editMaintenance(m),
              title: Text('${m['sensor_kind']} · ${_room(m)}',
                  style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 12.5)),
              subtitle: Text(
                'Installed ${m['installed_on'] ?? '-'} · last checked ${m['last_checked_on'] ?? '-'}'
                '${m['notes'] == null ? '' : ' · ${m['notes']}'}',
                style: TextStyle(color: secondary, fontSize: 11),
              ),
              trailing: Icon(Icons.edit_outlined, size: 17, color: secondary),
            ),
        ]),
      ),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════
// 3. User changes: everything users (and admins) changed, newest first.
// ═════════════════════════════════════════════════════════════════════════
class AdminChangeLogPanel extends StatefulWidget {
  const AdminChangeLogPanel({super.key});
  @override
  State<AdminChangeLogPanel> createState() => _AdminChangeLogPanelState();
}

class _AdminChangeLogPanelState extends State<AdminChangeLogPanel> {
  static const _tables = {
    '': 'All',
    'homes': 'Home & location',
    'emergency_contacts': 'Contacts',
    'pyroguard_home_layout': 'Floor plan',
    'pyroguard_sensor_maintenance': 'Maintenance',
    'pyroguard_incident_reports': 'Incident reports',
    'pyroguard_bfp_report_emails': 'BFP e-mails',
    'pyroguard_cost_catalog': 'Prices',
  };
  List<Map<String, dynamic>> _rows = const [];
  String _table = '';
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = _db
        .channel('admin-change-log')
        .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'pyroguard_change_log',
            callback: (_) => _load())
        .subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) _db.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var q = _db.from('pyroguard_change_log').select();
      if (_table.isNotEmpty) q = q.eq('table_name', _table);
      final rows = await q.order('changed_at', ascending: false).limit(200);
      if (!mounted) return;
      setState(() {
        _rows = [for (final r in rows as List) Map<String, dynamic>.from(r as Map)];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
        _loading = false;
        _error = 'Could not load changes: $e';
      });
      }
    }
  }

  /// Field names whose value changed (UPDATE), skipping timestamps.
  List<String> _changed(Map<String, dynamic> r) {
    final o = r['old_data'], n = r['new_data'];
    if (o is! Map || n is! Map) return const [];
    return [
      for (final k in n.keys)
        if (!'$k'.endsWith('_at') && jsonEncode(o[k]) != jsonEncode(n[k])) '$k',
    ];
  }

  String _summary(Map<String, dynamic> r) {
    final n = (r['new_data'] ?? r['old_data']);
    final m = n is Map ? n : const {};
    final name = m['item'] ?? m['name'] ?? m['label'] ?? m['report_number'] ?? m['address'] ?? m['email'] ?? r['record_id'];
    if (r['action'] == 'UPDATE') {
      final o = r['old_data'] is Map ? r['old_data'] as Map : const {};
      final fields = _changed(r);
      if (fields.isEmpty) return '$name';
      return '$name: ${fields.take(4).map((f) => '$f ${_short(o[f])} → ${_short(m[f])}').join(', ')}';
    }
    return '$name';
  }

  String _short(dynamic v) {
    final s = v == null ? '-' : '$v';
    return s.length > 28 ? '${s.substring(0, 28)}…' : s;
  }

  Future<void> _details(Map<String, dynamic> r) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${r['action']} · ${_tables[r['table_name']] ?? r['table_name']}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                'By: ${r['actor_email'] ?? r['changed_by'] ?? 'system / device'}\n'
                'When: ${_time(r['changed_at'])}\n\n'
                'Before:\n${const JsonEncoder.withIndent('  ').convert(r['old_data'])}\n\n'
                'After:\n${const JsonEncoder.withIndent('  ').convert(r['new_data'])}',
                style: TextStyle(fontSize: 12, color: AppTheme.textPrimary(ctx), fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    return PgCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PgHeader(
          icon: Icons.manage_history_outlined,
          title: 'User Changes',
          subtitle: 'Every change homeowners and admins make to homes, contacts, floor plans, maintenance, reports and prices.',
          actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20))],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final t in _tables.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(t.value),
                  selected: _table == t.key,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    setState(() => _table = t.key);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        if (_loading) const LinearProgressIndicator(color: AppColors.orange),
        if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 12)),
        if (!_loading && _rows.isEmpty) Text('No changes recorded yet.', style: TextStyle(color: secondary, fontSize: 12)),
        for (final r in _rows)
          InkWell(
            onTap: () => _details(r),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 64,
                  child: PgBadge('${r['action']}',
                      color: switch ('${r['action']}') {
                        'INSERT' => AppColors.green,
                        'DELETE' => AppColors.red,
                        _ => AppColors.amber,
                      }),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_tables[r['table_name']] ?? r['table_name']} · ${_summary(r)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w700)),
                    Text('${r['actor_email'] ?? 'system / device'} · ${_time(r['changed_at'])}',
                        style: TextStyle(color: secondary, fontSize: 11)),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
