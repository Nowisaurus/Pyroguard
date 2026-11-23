import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../responsive.dart';
import '../../services/admin_service.dart';
import '../dashboard/main_shell.dart'
    show
        PyroDesktopSidebar,
        PyroMobileDrawer,
        PyroMobileBottomNav,
        PyroNavigationItem,
        PyroBottomItem;
import '../dashboard/shared_app_bar.dart';
import '../../services/dual_sync_service.dart';
import '../../theme.dart';
import '../../services/room_sensor_service.dart';
import '../dashboard/room_sensor_panel.dart';
import '../support/support_tickets_page.dart';
import 'admin_extra_panels.dart';

/// Administrator-only scaffold; intentionally independent of MainShell.
class AdminConsoleScreen extends StatelessWidget {
  const AdminConsoleScreen({super.key});

  @override
  Widget build(BuildContext context) => const AdminTab();
}

class AdminTab extends StatefulWidget {
  const AdminTab({super.key});
  @override
  State<AdminTab> createState() => _AdminTabState();
}

class _AdminTabState extends State<AdminTab> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _ticketScrollController = ScrollController();
  int _selected = 0;
  bool _syncing = false;
  bool _managing = false;
  List<Map<String, dynamic>> commands = const [];
  static const _menus = [
    ('Overview', Icons.dashboard_outlined),
    ('Administrators', Icons.admin_panel_settings_outlined),
    ('Users', Icons.people_outline),
    ('Devices', Icons.sensors_outlined),
    ('Alerts', Icons.warning_amber_outlined),
    ('Activity', Icons.history),
    ('Database sync', Icons.cloud_sync_outlined),
    ('Support tickets', Icons.support_agent_outlined),
    ('Hardware cost', Icons.request_quote_outlined),
    ('Sensor health', Icons.monitor_heart_outlined),
    ('User changes', Icons.manage_history_outlined),
  ];
  String get _name {
    final user = Supabase.instance.client.auth.currentUser;
    for (final value in [
      AdminService.instance.record?['display_name'],
      user?.userMetadata?['full_name'],
      user?.userMetadata?['display_name'],
      user?.email?.split('@').first
    ]) {
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return 'Administrator';
  }

  Future<void> _logout() async {
    try {
      await DualSyncService.instance
          .recordSessionEvent(event: 'admin_logout', admin: true);
    } catch (_) {}
    await Supabase.instance.client.auth.signOut();
    if (mounted) context.go('/login');
  }

  List<PyroNavigationItem> get _navigationItems => [
        for (var i = 0; i < _menus.length; i++)
          (
            path: '$i',
            icon: _menus[i].$2,
            activeIcon: _menus[i].$2,
            label: _menus[i].$1
          ),
      ];
  List<PyroBottomItem> get _bottomItems => [
        for (final i in [0, 2, 3, 6, 7])
          (
            path: '$i',
            icon: _menus[i].$2,
            active: _menus[i].$2,
            label: i == 6
                ? 'Sync'
                : i == 7
                    ? 'Tickets'
                    : _menus[i].$1
          ),
      ];
  void _selectPage(String path) {
    final next = int.parse(path);
    setState(() => _selected = next);
    if (next != 7 && error != null && !loading) _load(silent: true);
  }

  Timer? _refreshTimer;
  Timer? _debounce;
  RealtimeChannel? _changes;
  bool _fetching = false;
  List<Map<String, dynamic>> latestUsers = const [];
  bool usersTruncated = false;

  bool loading = true;
  String? error;
  List<Map<String, dynamic>> admins = const [];
  List<Map<String, dynamic>> profiles = const [];
  List<Map<String, dynamic>> identities = const [];
  List<Map<String, dynamic>> devices = const [];
  List<Map<String, dynamic>> heartbeats = const [];
  bool heartbeatFeedReady = false;
  List<Map<String, dynamic>> events = const [];
  List<Map<String, dynamic>> readings = const [];
  List<Map<String, dynamic>> syncPending = const [];
  List<Map<String, dynamic>> ledgerPending = const [];
  Map<String, dynamic> databaseHealth = const {};
  Map<String, dynamic> exactRecordCounts = const {};
  List<Map<String, dynamic>> dashboardTickets = const [];
  Map<String, int> ticketMetrics = const {};
  String? ticketMetricsError;

  @override
  void initState() {
    super.initState();
    RoomSensorService.instance.start();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_selected != 7) _load(silent: true);
    });
    _changes = Supabase.instance.client
        .channel('admin-account-refresh')
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'profiles',
            callback: (_) => _scheduleReload())
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'account_identities',
            callback: (_) => _scheduleReload())
        .subscribe();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 500), () => _load(silent: true));
  }

  @override
  void dispose() {
    _ticketScrollController.dispose();
    _refreshTimer?.cancel();
    _debounce?.cancel();
    if (_changes != null) Supabase.instance.client.removeChannel(_changes!);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted || _fetching || (_selected == 7 && silent)) return;
    _fetching = true;
    if (!silent) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      await AdminService.instance.refresh();
      if (!AdminService.instance.isAdmin) {
        throw StateError('Administrator access is required.');
      }
      final response = await Supabase.instance.client.functions
          .invoke('admin-console', body: {'action': 'read'});
      final raw = response.data;
      Map<String, int> newTicketMetrics = {};
      String? newTicketMetricsError;
      List<Map<String, dynamic>> loadedTickets = [];
      try {
        final rows = await Supabase.instance.client
            .from('support_tickets')
            .select(
                'id,title,status,severity,assigned_to,archived_at,created_at');
        final tickets = List<Map<String, dynamic>>.from(rows)
            .where((t) => t['archived_at'] == null)
            .toList();
        loadedTickets = tickets;
        int count(bool Function(Map<String, dynamic>) test) =>
            tickets.where(test).length;
        newTicketMetrics = {
          'total': tickets.length,
          'open': count((t) => t['status'] == 'open'),
          'active': count((t) => t['status'] == 'in_progress'),
          'critical': count((t) =>
              t['severity'] == 'critical' &&
              !['closed', 'resolved', 'ignored'].contains(t['status'])),
          'major': count((t) =>
              t['severity'] == 'major' &&
              !['closed', 'resolved', 'ignored'].contains(t['status'])),
          'unassigned': count((t) =>
              t['assigned_to'] == null &&
              !['closed', 'resolved', 'ignored'].contains(t['status'])),
          'resolved':
              count((t) => ['closed', 'resolved'].contains(t['status'])),
        };
      } catch (e) {
        newTicketMetricsError = 'Ticket statistics unavailable: $e';
      }

      if (raw is! Map || raw['ok'] != true) {
        throw StateError(
            'Admin data is unavailable. Deploy admin-console and check its logs.');
      }
      if (!mounted) return;
      setState(() {
        admins = _maps(raw['admins']);
        profiles = _maps(raw['profiles']);
        identities = _maps(raw['identities']);
        latestUsers = _maps(raw['users']);
        usersTruncated = raw['auth_scan_truncated'] == true;
        commands = _maps(raw['commands']);
        devices = _maps(raw['devices']);
        heartbeats = _maps(raw['heartbeats']);
        heartbeatFeedReady = raw.containsKey('heartbeats') &&
            !(raw['failures'] is List &&
                (raw['failures'] as List)
                    .any((e) => '$e'.contains('Device heartbeats')));
        events = _maps(raw['events']);
        syncPending = _maps(raw['mirrors']);
        ledgerPending = _maps(raw['ledger']);
        databaseHealth = raw['health'] is Map
            ? Map<String, dynamic>.from(raw['health'] as Map)
            : {};
        exactRecordCounts = raw['record_counts'] is Map
            ? Map<String, dynamic>.from(raw['record_counts'] as Map)
            : {};
        dashboardTickets = loadedTickets;
        ticketMetrics = newTicketMetrics;
        ticketMetricsError = newTicketMetricsError;
        final failures = raw['failures'];
        error = failures is List && failures.isNotEmpty
            ? failures.join('\n')
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Admin data could not refresh: $e');
    } finally {
      _fetching = false;
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> _maps(dynamic rows) => rows is List
      ? rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const [];

  Future<void> _manage(Map<String, dynamic> body) async {
    if (_managing) return;
    setState(() => _managing = true);
    try {
      final response = await Supabase.instance.client.functions
          .invoke('admin-console', body: body);
      final raw = response.data;
      if (raw is! Map || raw['ok'] != true) {
        throw StateError(
            raw is Map ? '${raw['error']}' : 'Management request failed');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['action'] == 'queue_security'
              ? 'Command ${raw['command']?['id']} queued. Wait for the device acknowledgement below.'
              : 'Saved in Supabase. The MySQL worker will mirror this change.')));
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Action failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  Future<void> _manageUser(Map<String, dynamic> user) async {
    final disabled = user['account_status'] == 'disabled';
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(disabled ? 'Enable user?' : 'Disable user?'),
                content: Text(
                    '${user['email']}\n${disabled ? 'Allow this user to sign in again.' : 'Block future sign-ins. Existing access tokens may remain valid until expiry.'}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Confirm'))
                ]));
    if (confirmed == true && mounted) {
      await _manage({
        'action': 'manage_user',
        'user_id': user['user_id'],
        'account_status': disabled ? 'active' : 'disabled'
      });
    }
  }

  Future<void> _renameDevice(Map<String, dynamic> device) async {
    final input = TextEditingController(text: '${device['device_name'] ?? ''}');
    final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Rename device'),
                content: TextField(
                    controller: input,
                    maxLength: 120,
                    decoration:
                        const InputDecoration(labelText: 'Device name')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, input.text.trim()),
                      child: const Text('Save'))
                ]));
    input.dispose();
    if (name != null && name.isNotEmpty && mounted) {
      await _manage({
        'action': 'manage_device',
        'device_id': device['device_id'],
        'device_name': name
      });
    }
  }

  Future<void> _retryDualSync() async {
    if (_syncing || loading) return;
    setState(() => _syncing = true);
    try {
      final response = await Supabase.instance.client.functions
          .invoke('admin-console', body: {'action': 'sync'});
      final raw = response.data;
      if (raw is! Map || raw['ok'] != true) {
        throw StateError('Administrator account sync failed.');
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(databaseHealth['mode'] == 'local-pc'
                ? 'Sync requested. Keep the PC worker running and wait for its next completed cycle.'
                : databaseHealth['mysql'] == true
                    ? 'Account sync checked. Review each user’s verified/pending result below.'
                    : 'MySQL is still unavailable. Open Database sync for the setup details.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Sync retry failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    final content = RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8,
            Responsive.horizontalPadding(context), 110),
        children: [
          if (_selected == 7)
            SizedBox(
                height: MediaQuery.sizeOf(context).height * .82,
                child: const SupportTicketsPage()),
          if (_selected != 7 && loading)
            const LinearProgressIndicator(color: AppColors.orange),
          if (_selected != 7 && error != null)
            _panel(
                child: Text(error!,
                    style:
                        TextStyle(color: AppTheme.dangerForeground(context)))),
          if (_selected != 7 && !loading && AdminService.instance.isAdmin) ...[
            if (_selected == 0) _modernOverview(),
            if (_selected != 0) ...[
              _panel(
                  child: Row(children: [
                Icon(_menus[_selected].$2, color: AppColors.orange),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(_menus[_selected].$1,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.bold))),
              ])),
              const SizedBox(height: 12),
            ],
            if (_selected == 8) const AdminCostCatalogPanel(),
            if (_selected == 9) const AdminSensorHealthPanel(),
            if (_selected == 10) const AdminChangeLogPanel(),
            if (_selected == 5)
              _section('SUPPORT OPERATIONS · ASSIGNED QUEUE', [
                if (ticketMetricsError != null)
                  ListTile(
                      title: Text(ticketMetricsError!,
                          style: const TextStyle(color: AppColors.amber))),
                if (ticketMetricsError == null) ...[
                  ListTile(
                      leading: const Icon(Icons.confirmation_number_outlined),
                      title: Text('Tickets: ${ticketMetrics['total'] ?? 0}'),
                      subtitle: Text(
                          'Open: ${ticketMetrics['open'] ?? 0} · In progress: ${ticketMetrics['active'] ?? 0} · Resolved/closed: ${ticketMetrics['resolved'] ?? 0}')),
                  ListTile(
                      leading: const Icon(Icons.priority_high_outlined),
                      title: Text(
                          'Critical: ${ticketMetrics['critical'] ?? 0} · Major: ${ticketMetrics['major'] ?? 0}'),
                      subtitle: Text(
                          'Unassigned active tickets: ${ticketMetrics['unassigned'] ?? 0}')),
                ],
              ]),
            if (_selected == 5) const SizedBox(height: 10),
            if (_selected == 5)
              _section('OPERATIONAL HEALTH', [
                ListTile(
                    leading: Icon(
                        databaseHealth['supabase'] == true
                            ? Icons.cloud_done
                            : Icons.cloud_off,
                        color: databaseHealth['supabase'] == true
                            ? AppColors.green
                            : AppColors.amber),
                    title: Text(
                        'Supabase: ${databaseHealth['supabase'] == true ? 'Reachable' : 'Not confirmed'}'),
                    subtitle: const Text(
                        'Database reachability is separate from hardware status')),
                ListTile(
                    leading: Icon(
                        databaseHealth['mysql'] == true
                            ? Icons.sync
                            : Icons.sync_problem,
                        color: databaseHealth['mysql'] == true
                            ? AppColors.green
                            : AppColors.amber),
                    title: Text(
                        'MySQL mirror: ${databaseHealth['mysql'] == true ? 'Reachable' : 'Unavailable or not verified'}'),
                    subtitle: Text(
                        'Queued synchronization records: ${syncPending.length + ledgerPending.length}')),
                ListTile(
                    leading: const Icon(Icons.memory_outlined),
                    title: Text('Registered hardware: ${devices.length}'),
                    subtitle: const Text(
                        'Review per-device heartbeats and sensor freshness on the Devices page; registration alone does not mean online')),
                ListTile(
                    leading: const Icon(Icons.pending_actions_outlined),
                    title: Text('Device commands: ${commands.length} loaded'),
                    subtitle: Text(
                        'Pending or failed: ${commands.where((c) => ![
                              'applied',
                              'completed',
                              'success'
                            ].contains(c['status'])).length}')),
              ]),
            if (_selected == 1) const SizedBox(height: 10),
            if (_selected == 1)
              _section('ADMIN ACCOUNTS', [
                for (final a in admins)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.orange.withValues(alpha: .15),
                      child: Icon(
                        a['admin_role'] == 'head_developer'
                            ? Icons.code
                            : Icons.admin_panel_settings,
                        color: AppTheme.brandForeground(context),
                      ),
                    ),
                    title: Text('${a['display_name'] ?? a['email']}',
                        style: TextStyle(
                            color: AppTheme.textPrimary(context),
                            fontWeight: FontWeight.w800)),
                    subtitle: Text(
                      '${a['email']} · ${a['admin_role']}\nReference: ${a['admin_reference_code'] ?? 'Not set'}',
                      style: TextStyle(
                          color: AppTheme.textSecondary(context), fontSize: 11),
                    ),
                    trailing: Text(a['active'] == true ? 'ACTIVE' : 'DISABLED',
                        style: TextStyle(
                            color: a['active'] == true
                                ? AppTheme.safeForeground(context)
                                : AppTheme.dangerForeground(context),
                            fontSize: 10,
                            fontWeight: FontWeight.w900)),
                  ),
              ]),
            if (_selected == 6) const SizedBox(height: 10),
            if (_selected == 6)
              _section('DATABASE COMMUNICATION', [
                ListTile(
                  leading: Icon(
                    databaseHealth['supabase'] == true &&
                            databaseHealth['mysql'] == true
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: databaseHealth['supabase'] == true &&
                            databaseHealth['mysql'] == true
                        ? AppColors.green
                        : AppColors.amber,
                  ),
                  title: Text(
                    databaseHealth['supabase'] == true &&
                            databaseHealth['mysql'] == true
                        ? 'Supabase and MySQL are both reachable'
                        : 'Database communication needs attention',
                    style: TextStyle(
                        color: AppTheme.textPrimary(context),
                        fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    'Supabase: ${databaseHealth['supabase'] == true ? 'CONNECTED' : 'UNAVAILABLE'}  ·  '
                    'MySQL: ${databaseHealth['mysql'] == true ? 'CONNECTED' : 'UNAVAILABLE'}\n'
                    'Last checked: ${databaseHealth['checked_at'] ?? 'Unavailable'}\n'
                    '${databaseHealth['mode'] == 'local-pc' ? 'Local laptop tables verified' : 'MySQL mirror schema'}: ${databaseHealth['mysql_schema_parity'] == true ? '${databaseHealth['mysql_table_count'] ?? 28}/${databaseHealth['mysql_expected_table_count'] ?? 28} TABLES' : '${databaseHealth['mysql_table_count'] ?? 0}/${databaseHealth['mysql_expected_table_count'] ?? 28} TABLES'}\n'
                    '${databaseHealth['mode'] == 'local-pc' ? 'Last completed local cycle: ${databaseHealth['last_completed_at'] ?? 'Waiting'}\n' : ''}'
                    'Account comparisons: ${databaseHealth['verified_accounts'] ?? 0}/${databaseHealth['account_verification_scope'] ?? 0} loaded homeowners match the MySQL profile, identity and registration snapshot. See table results for the local worker’s other record types.',
                    style: TextStyle(
                        color: AppTheme.textSecondary(context),
                        fontSize: 13,
                        height: 1.45),
                  ),
                ),
                if (databaseHealth['mode'] == 'local-pc') ...[
                  ListTile(
                    leading: Icon(Icons.computer,
                        color: databaseHealth['worker_online'] == true
                            ? AppColors.green
                            : AppColors.amber),
                    title: Text('Local MySQL on your laptop',
                        style: TextStyle(
                            color: AppTheme.textPrimary(context),
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        'Worker: ${databaseHealth['worker_online'] == true ? 'ONLINE' : 'OFFLINE'} · Cycle: ${databaseHealth['cycle_complete'] == true ? 'COMPLETED' : 'PENDING'}\nSupabase is the source. MySQL catches up while your laptop worker is running.',
                        style:
                            TextStyle(color: AppTheme.textSecondary(context))),
                  ),
                  if (databaseHealth['table_results'] is Map)
                    for (final entry
                        in (databaseHealth['table_results'] as Map).entries)
                      ListTile(
                        dense: true,
                        leading: Icon(
                            entry.value is Map &&
                                    entry.value['state'] == 'verified'
                                ? Icons.check_circle_outline
                                : Icons.sync_problem_outlined,
                            color: entry.value is Map &&
                                    entry.value['state'] == 'verified'
                                ? AppColors.green
                                : AppColors.amber),
                        title: Text(entry.key.toString(),
                            style: TextStyle(
                                color: AppTheme.textPrimary(context))),
                        subtitle: Text(
                            entry.value is Map
                                ? '${entry.value['state']} · ${entry.value['verified_rows'] ?? 0}/${entry.value['rows'] ?? 0} rows checked'
                                : 'Pending',
                            style: TextStyle(
                                color: AppTheme.textSecondary(context))),
                      ),
                ],
                if (databaseHealth['error'] != null)
                  ListTile(
                    leading:
                        const Icon(Icons.info_outline, color: AppColors.amber),
                    title: Text('Communication detail',
                        style: TextStyle(
                            color: AppTheme.textPrimary(context),
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(databaseHealth['error'].toString(),
                        style: TextStyle(
                            color: AppTheme.textSecondary(context),
                            fontSize: 13)),
                  ),
                ListTile(
                  leading: Icon(
                    (error == null &&
                            databaseHealth['mysql'] == true &&
                            databaseHealth['verified_accounts'] ==
                                databaseHealth['account_verification_scope'] &&
                            syncPending.isEmpty &&
                            ledgerPending.isEmpty &&
                            identities.every((e) => e['mysql_synced'] == true))
                        ? Icons.verified_outlined
                        : Icons.sync_problem_outlined,
                    color: (error == null &&
                            databaseHealth['mysql'] == true &&
                            databaseHealth['verified_accounts'] ==
                                databaseHealth['account_verification_scope'] &&
                            syncPending.isEmpty &&
                            ledgerPending.isEmpty &&
                            identities.every((e) => e['mysql_synced'] == true))
                        ? AppColors.green
                        : AppColors.amber,
                  ),
                  title: Text(
                    (error == null &&
                            databaseHealth['mysql'] == true &&
                            databaseHealth['verified_accounts'] ==
                                databaseHealth['account_verification_scope'] &&
                            syncPending.isEmpty &&
                            ledgerPending.isEmpty &&
                            identities.every((e) => e['mysql_synced'] == true))
                        ? 'No pending records in the loaded sample'
                        : error != null
                            ? 'Pending status is incomplete; review the query error above'
                            : 'Account data or pending records still need verification / sync',
                    style: TextStyle(
                        color: AppTheme.textPrimary(context),
                        fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    'Loaded pending mirror/ledger/account records: ${syncPending.length + ledgerPending.length + identities.where((e) => e['mysql_synced'] != true).length}. The Sync button retries hosted mirroring or requests the PC worker’s next full cycle.',
                    style: TextStyle(
                        color: AppTheme.textSecondary(context), fontSize: 11),
                  ),
                ),
              ]),
            if (_selected == 4) const SizedBox(height: 10),
            if (_selected == 4)
              _section('ALERTS & INCIDENT TRIAGE', [
                ...events
                    .where((e) {
                      final label =
                          '${e['event_type'] ?? e['type'] ?? ''} ${e['severity'] ?? ''}'
                              .toLowerCase();
                      return label.contains('alert') ||
                          label.contains('alarm') ||
                          label.contains('fire') ||
                          label.contains('smoke') ||
                          label.contains('intrusion') ||
                          label.contains('critical');
                    })
                    .take(30)
                    .map((e) => ListTile(
                          leading: const Icon(Icons.warning_amber_outlined,
                              color: Colors.orange),
                          title: Text(
                              '${e['event_type'] ?? e['type'] ?? 'Alert'}'),
                          subtitle:
                              Text('${e['created_at'] ?? 'Time unavailable'}'),
                        )),
                if (!events.any((e) {
                  final label =
                      '${e['event_type'] ?? e['type'] ?? ''} ${e['severity'] ?? ''}'
                          .toLowerCase();
                  return label.contains('alert') ||
                      label.contains('alarm') ||
                      label.contains('fire') ||
                      label.contains('smoke') ||
                      label.contains('intrusion') ||
                      label.contains('critical');
                }))
                  const ListTile(
                      title: Text('No alert events in the latest 100 records')),
              ]),
            if (_selected == 3) ...[
              const SizedBox(height: 10),
              const RoomSensorPanel(compact: true, adminDiagnostics: true),
            ],
            if (_selected == 3) const SizedBox(height: 10),
            if (_selected == 3)
              _section('DEVICE & SENSOR MANAGEMENT', [
                if (devices.isEmpty)
                  const ListTile(title: Text('No devices available')),
                for (final d in devices)
                  ListTile(
                    leading: const Icon(Icons.sensors_outlined),
                    title: Text(
                        '${d['name'] ?? d['device_name'] ?? d['id'] ?? 'Device'}'),
                    subtitle: Text(
                        'Device ID: ${d['device_id'] ?? 'unknown'} • Status: ${d['status'] ?? 'not reported'}'),
                    trailing: PopupMenuButton<String>(
                        enabled: !_managing,
                        tooltip: 'Manage device',
                        onSelected: (action) {
                          if (action == 'rename') {
                            _renameDevice(d);
                          } else {
                            _manage({
                              'action': 'queue_security',
                              'device_id': d['device_id'],
                              'arm_mode': action
                            });
                          }
                        },
                        itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Rename device')),
                              PopupMenuItem(
                                  value: 'ARM_HOME',
                                  child: Text('Queue Arm Home')),
                              PopupMenuItem(
                                  value: 'ARM_AWAY',
                                  child: Text('Queue Arm Away')),
                              PopupMenuItem(
                                  value: 'DISARMED',
                                  child: Text('Queue Disarm'))
                            ]),
                  ),
              ]),
            if (_selected == 3) const SizedBox(height: 10),
            if (_selected == 3)
              _section('HARDWARE COMMAND STATUS', [
                if (commands.isEmpty)
                  const ListTile(title: Text('No device commands returned')),
                for (final command in commands.take(20))
                  ListTile(
                      title:
                          Text('${command['command']} · ${command['status']}'),
                      subtitle: Text(
                          '${command['target_device_id']} · ${command['created_at']}\n${command['result_message'] ?? 'Awaiting device result'}'),
                      isThreeLine: true,
                      trailing: Icon(command['status'] == 'applied'
                          ? Icons.check_circle_outline
                          : Icons.pending_outlined)),
              ]),
            if (_selected == 5) const SizedBox(height: 10),
            if (_selected == 5)
              _section('SYSTEM MONITORING & ACTIVITY LOGS', [
                ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined),
                  title: Text('Devices tracked: ${devices.length}'),
                  subtitle: Text(
                      'Events recorded: ${events.length} • Pending mirror records: ${syncPending.length + ledgerPending.length}'),
                ),
                for (final e in events.take(15))
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(
                        '${e['event_type'] ?? e['type'] ?? 'System event'}'),
                    subtitle: Text('${e['created_at'] ?? 'Time unavailable'}'),
                  ),
              ]),
            if (_selected == 2) const SizedBox(height: 10),
            if (_selected == 2)
              _section('LATEST USERS', [
                if (usersTruncated)
                  const ListTile(
                      title: Text(
                          'Account scan is limited to 5,000 Auth records; newest users are shown within that scan.')),
                if (latestUsers.isEmpty)
                  const ListTile(
                      title: Text(
                          'No homeowner accounts returned by the Auth service.')),
                for (final u in latestUsers)
                  ListTile(
                    leading: Icon(Icons.person_outline,
                        color: AppTheme.brandForeground(context)),
                    title: Text(
                        (u['full_name'] ?? u['email'] ?? 'Unnamed account')
                            .toString(),
                        style: TextStyle(
                            color: AppTheme.textPrimary(context),
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${u['email'] ?? ''}\n'
                        '${u['email_confirmed'] == true ? 'Email verified' : 'Awaiting email verification'} · '
                        '${u['email_confirmed'] != true ? 'Application registration pending confirmation' : u['profile_present'] == true ? 'Profile present' : u['profile_present'] == false ? 'PROFILE MISSING' : 'PROFILE READ UNAVAILABLE'} · '
                        '${u['identity_present'] == true ? 'Identity present' : u['identity_present'] == false ? 'IDENTITY MISSING' : 'IDENTITY READ UNAVAILABLE'}\n'
                        'MySQL: ${_verificationLabel(u['verification'])}',
                        style: TextStyle(
                            color: AppTheme.textSecondary(context),
                            fontSize: 12)),
                    isThreeLine: true,
                    trailing: IconButton(
                        tooltip: u['account_status'] == 'disabled'
                            ? 'Enable user'
                            : 'Disable user',
                        onPressed: _managing || u['email_confirmed'] != true
                            ? null
                            : () => _manageUser(u),
                        icon: Icon(u['account_status'] == 'disabled'
                            ? Icons.person_add_alt
                            : Icons.person_off_outlined)),
                  ),
              ]),
            if (_selected == 5) const SizedBox(height: 10),
            if (_selected == 5)
              _section('LATEST EVENTS · SUPABASE + MYSQL MIRROR', [
                if (events.isEmpty)
                  const ListTile(title: Text('No events recorded yet.')),
                for (final e in events.take(15))
                  ListTile(
                    leading: Icon(Icons.history,
                        color: e['mysql_synced'] == true
                            ? AppColors.green
                            : AppColors.amber),
                    title: Text((e['event_type'] ?? 'event').toString(),
                        style: TextStyle(
                            color: AppTheme.textPrimary(context),
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        (e['message'] ?? e['created_at'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textSecondary(context),
                            fontSize: 11)),
                    trailing: Text(
                        e['mysql_synced'] == true
                            ? 'DUAL SAVED'
                            : 'SYNC PENDING',
                        style: TextStyle(
                            color: e['mysql_synced'] == true
                                ? AppColors.green
                                : AppColors.amber,
                            fontSize: 9,
                            fontWeight: FontWeight.w900)),
                  ),
              ]),
          ],
        ],
      ),
    );
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      endDrawer: desktop
          ? null
          : PyroMobileDrawer(
              path: '$_selected',
              name: _name,
              email: email,
              onNav: _selectPage,
              onLogout: _logout,
              items: _navigationItems,
              adminWorkspace: true),
      bottomNavigationBar: desktop
          ? null
          : PyroMobileBottomNav(
              path: '$_selected',
              onNav: _selectPage,
              customItems: _bottomItems),
      body: AmbientBackdrop(
          child: Row(children: [
        if (desktop)
          PyroDesktopSidebar(
              path: '$_selected',
              name: _name,
              email: email,
              onNav: _selectPage,
              onLogout: _logout,
              items: _navigationItems,
              adminWorkspace: true),
        Expanded(
            child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: PyroAppBar(
                    title: 'PyroGuard · $_name',
                    subtitle: '${_menus[_selected].$1} · Administrator',
                    systemOnline: databaseHealth['supabase'] == true,
                    onOpenMenu: () =>
                        _scaffoldKey.currentState?.openEndDrawer(),
                    extraActions: [
                      if (_selected != 7)
                        IconButton(
                            onPressed:
                                loading || _syncing ? null : _retryDualSync,
                            tooltip: 'Sync actual homeowner accounts',
                            icon: const Icon(Icons.sync)),
                      if (_selected != 7)
                        IconButton(
                            onPressed: loading ? null : _load,
                            tooltip: 'Refresh admin data',
                            icon: const Icon(Icons.refresh)),
                    ]),
                body: content)),
      ])),
    );
  }

  String _verificationLabel(dynamic status) => switch (status) {
        'awaiting_confirmation' => 'AWAITING EMAIL CONFIRMATION',
        'verified' => 'PROFILE + IDENTITY + REGISTRATION VERIFIED',
        'pending' => 'LOCAL SYNC PENDING',
        'source_unavailable' => 'SOURCE READ UNAVAILABLE',
        'source_missing' => 'SOURCE RECORD MISSING — USE SYNC TO REPAIR',
        'mysql_missing' => 'MYSQL RECORD MISSING — SYNC PENDING',
        'mismatch' => 'DATA MISMATCH — REVIEW / SYNC',
        _ => 'VERIFICATION UNAVAILABLE',
      };

  Widget _panel({required Widget child}) =>
      GlassPanel(padding: const EdgeInsets.all(16), child: child);

  // The Overview is an additive visualization of the existing admin-console data.
  // Administrative actions continue to live in the existing navigation sections.
  Widget _modernOverview() {
    final ticketReady = ticketMetricsError == null;
    final adminFeedReady = error == null;
    final eventsLimited = events.length >= 100;
    final devicesLimited = devices.length >= 100;
    final syncLimited =
        syncPending.length >= 100 || ledgerPending.length >= 100;
    final active = dashboardTickets
        .where((t) =>
            !['resolved', 'closed', 'ignored'].contains('${t['status']}'))
        .toList();
    final severe = events.where(_isAlert).toList();
    final int? pending = exactRecordCounts['pending_total'] is int
        ? exactRecordCounts['pending_total'] as int
        : null;
    final deviceOnline = devices.where(_deviceIsFresh).length;
    final heartbeatVerified = adminFeedReady &&
        heartbeatFeedReady &&
        exactRecordCounts['devices'] == devices.length;
    final int? exactDeviceCount = exactRecordCounts['devices'] is int
        ? exactRecordCounts['devices'] as int
        : null;
    final int? exactEventCount = exactRecordCounts['events'] is int
        ? exactRecordCounts['events'] as int
        : null;
    final visibleTotal = dashboardTickets.length;
    final closed = dashboardTickets
        .where((t) => ['closed', 'resolved'].contains('${t['status']}'))
        .length;
    final ignored =
        dashboardTickets.where((t) => t['status'] == 'ignored').length;
    final working =
        dashboardTickets.where((t) => t['status'] == 'in_progress').length;
    final open = dashboardTickets.where((t) => t['status'] == 'open').length;
    final now = DateTime.now();
    final recentDates = List.generate(
        14,
        (i) => DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: 13 - i)));
    int onDate(Iterable<Map<String, dynamic>> rows, DateTime day) =>
        rows.where((r) {
          final date = DateTime.tryParse('${r['created_at'] ?? ''}')?.toLocal();
          return date != null &&
              date.year == day.year &&
              date.month == day.month &&
              date.day == day.day;
        }).length;
    final eventCounts = [for (final d in recentDates) onDate(events, d)];
    final alertCounts = [for (final d in recentDates) onDate(severe, d)];
    final ticketCounts = [
      for (final d in recentDates) onDate(dashboardTickets, d)
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Welcome back, $_name',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textPrimary(context))),
          Text(
              AdminService.instance.isHeadDeveloper
                  ? 'System-wide operations and administration'
                  : 'Your assigned operations and support queue',
              style: TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary(context))),
        ])),
        IconButton(
            tooltip: 'Refresh dashboard',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, b) {
        final columns = b.maxWidth >= 950
            ? 4
            : b.maxWidth >= 550
                ? 2
                : 1;
        final width = (b.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(
              width: width,
              child: _dashKpi(
                  'Open tickets',
                  ticketReady ? '${active.length}' : 'Unavailable',
                  Icons.confirmation_number_outlined,
                  AppColors.orange,
                  'Visible to your account',
                  7)),
          SizedBox(
              width: width,
              child: _dashKpi(
                  'Recent alerts',
                  adminFeedReady
                      ? (eventsLimited
                          ? '${severe.length}+'
                          : '${severe.length}')
                      : 'Unavailable',
                  Icons.warning_amber_rounded,
                  AppColors.redBright,
                  'Alerts in latest ${events.length} of ${exactEventCount ?? 'unknown'} events',
                  4)),
          SizedBox(
              width: width,
              child: _dashKpi(
                  'Devices fresh',
                  heartbeatVerified && exactDeviceCount != null
                      ? '$deviceOnline / $exactDeviceCount'
                      : 'Unavailable',
                  Icons.memory_rounded,
                  AppColors.green,
                  devicesLimited
                      ? 'Heartbeat verified · device list capped'
                      : 'Heartbeat verified',
                  3)),
          SizedBox(
              width: width,
              child: _dashKpi(
                  'Sync backlog',
                  pending != null ? '$pending' : 'Unavailable',
                  Icons.sync_problem_outlined,
                  AppColors.amber,
                  syncLimited
                      ? 'Exact unsynced rows in Supabase — list capped'
                      : 'Exact unsynced rows in Supabase',
                  6)),
        ]);
      }),
      const SizedBox(height: 12),
      // Trends and device analytics are a matched desktop row.
      LayoutBuilder(builder: (context, bounds) {
        final wide = bounds.maxWidth >= 820;
        final leftWidth = wide ? (bounds.maxWidth - 12) * .62 : bounds.maxWidth;
        final rightWidth =
            wide ? (bounds.maxWidth - 12) * .38 : bounds.maxWidth;
        const rowHeight = 310.0;
        final trend = _dashPanel(
            'Recorded trends · 14 days',
            Icons.show_chart,
            SizedBox(
                height: 240,
                child: Column(children: [
                  if (adminFeedReady && ticketReady && !eventsLimited)
                    SizedBox(
                        height: 170,
                        child: CustomPaint(
                            painter: _PyroTrendPainter(
                                eventCounts, alertCounts, ticketCounts),
                            child: const SizedBox.expand()))
                  else
                    const SizedBox(
                        height: 140,
                        child: Center(
                            child: Text(
                                'Complete 14-day event history unavailable'))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 12, runSpacing: 6, children: [
                    _legend('Events', AppColors.redBright),
                    _legend('Alerts', AppColors.amber),
                    _legend('Tickets', Colors.pinkAccent),
                  ]),
                  const Spacer(),
                  Text(
                      'Last 14 days · ${events.length} events loaded (total: ${exactEventCount ?? 'unknown'}); partial histories are not shown as complete.',
                      style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary(context))),
                ])));

        final analytics = _dashPanel(
          'Device analytics',
          Icons.donut_large_outlined,
          SizedBox(
            height: 240,
            child: Column(
              children: [
                if (heartbeatVerified)
                  SizedBox(
                    height: 155,
                    child: CustomPaint(
                      painter: _PyroDonutPainter(
                        [
                          deviceOnline,
                          devices.length - deviceOnline,
                        ],
                        [
                          AppColors.green,
                          AppColors.redBright,
                        ],
                      ),
                      child: Center(
                        child: Text(
                          devices.isEmpty
                              ? '—'
                              : deviceOnline == 0
                                  ? 'Not verified'
                                  : '${(100 * deviceOnline / devices.length).round()}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!heartbeatVerified)
                  const Expanded(
                    child: Center(
                      child: Text(
                        'Device heartbeat coverage unavailable',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                if (heartbeatVerified) ...[
                  const SizedBox(height: 8),
                  _legend(
                    'Fresh heartbeat $deviceOnline',
                    AppColors.green,
                  ),
                  const SizedBox(height: 6),
                  _legend(
                    'Stale or unverified ${devices.length - deviceOnline}',
                    AppColors.amber,
                  ),
                ],
                const Spacer(),
                Text(
                  'Registered does not mean online',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
        );

        if (!wide) {
          return Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(width: leftWidth, child: trend),
            SizedBox(width: rightWidth, child: analytics),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: leftWidth, height: rowHeight, child: trend),
          const SizedBox(width: 12),
          SizedBox(width: rightWidth, height: rowHeight, child: analytics),
        ]);
      }),
      const SizedBox(height: 12),
      // Health and the scrollable support queue are adjacent.
      LayoutBuilder(builder: (context, bounds) {
        final wide = bounds.maxWidth >= 820;
        final leftWidth = wide ? (bounds.maxWidth - 12) * .52 : bounds.maxWidth;
        final rightWidth =
            wide ? (bounds.maxWidth - 12) * .48 : bounds.maxWidth;
        const rowHeight = 320.0;
        final health = _dashPanel(
            'System health',
            Icons.health_and_safety_outlined,
            SizedBox(
                height: 250,
                child: LayoutBuilder(builder: (context, inner) {
                  final tileWidth = inner.maxWidth >= 440
                      ? (inner.maxWidth - 8) / 2
                      : inner.maxWidth;
                  final items = <Widget>[
                    for (final d in devices)
                      _healthTile(
                          '${d['device_name'] ?? d['name'] ?? d['device_id'] ?? 'Device'}',
                          heartbeatFeedReady
                              ? (_deviceIsFresh(d)
                                  ? 'Fresh heartbeat'
                                  : 'Stale / no heartbeat')
                              : 'Unavailable',
                          heartbeatFeedReady && _deviceIsFresh(d)),
                    _healthTile(
                        'Supabase',
                        databaseHealth['supabase'] == true
                            ? 'Reachable'
                            : 'Not verified',
                        databaseHealth['supabase'] == true),
                    _healthTile(
                        'MySQL mirror',
                        databaseHealth['mysql'] == true
                            ? 'Reachable'
                            : 'Not verified',
                        databaseHealth['mysql'] == true),
                  ];
                  return SingleChildScrollView(
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final item in items)
                        SizedBox(width: tileWidth, child: item),
                    ]),
                  );
                })));
        final queue = _dashPanel(
            'Active support tickets',
            Icons.support_agent_outlined,
            SizedBox(
                height: 250,
                child: !ticketReady
                    ? const Center(child: Text('Ticket records unavailable'))
                    : active.isEmpty
                        ? const Center(
                            child: Text(
                                'No active tickets visible to this account'))
                        : Scrollbar(
                            controller: _ticketScrollController,
                            thumbVisibility: true,
                            child: ListView.separated(
                              controller: _ticketScrollController,
                              primary: false,
                              itemCount: active.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final t = active[index];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  onTap: () => setState(() => _selected = 7),
                                  leading: const Icon(
                                      Icons.confirmation_number_outlined,
                                      color: AppColors.orange,
                                      size: 19),
                                  title: Text(
                                      '${t['title'] ?? 'Support ticket'}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                      '${t['severity'] ?? 'normal'} · ${t['status'] ?? 'open'}',
                                      style: const TextStyle(fontSize: 10)),
                                  trailing:
                                      const Icon(Icons.chevron_right, size: 18),
                                );
                              },
                            ))));
        if (!wide) {
          return Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(width: leftWidth, child: health),
            SizedBox(width: rightWidth, child: queue),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: leftWidth, height: rowHeight, child: health),
          const SizedBox(width: 12),
          SizedBox(width: rightWidth, height: rowHeight, child: queue),
        ]);
      }),
      const SizedBox(height: 12),
      // Compact, equal-height incident and ticket cards.
      LayoutBuilder(builder: (context, bounds) {
        final wide = bounds.maxWidth >= 820;
        final leftWidth = wide ? (bounds.maxWidth - 12) * .42 : bounds.maxWidth;
        final rightWidth = wide ? (bounds.maxWidth - 12) * .58 : bounds.maxWidth;
        const rowHeight = 216.0;
        final status = _dashPanel(
          'Ticket status',
          Icons.pie_chart_outline,
          SizedBox(height: 155, child: !ticketReady
            ? _compactPlaceholder(Icons.confirmation_number_outlined,
                'Tickets unavailable', 'Check ticket access and connection')
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(height: 100, child: CustomPaint(
                  painter: _PyroDonutPainter(
                    [open, working, closed, ignored],
                    [AppColors.redBright, AppColors.amber, AppColors.green, Colors.blueGrey]),
                  child: Center(child: Text('$visibleTotal',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))))),
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.center, spacing: 9, runSpacing: 5, children: [
                  _legend('Open $open', AppColors.redBright),
                  _legend('In progress $working', AppColors.amber),
                  _legend('Resolved $closed', AppColors.green),
                  _legend('Ignored $ignored', Colors.blueGrey),
                ]),
              ])));
        final incidents = _dashPanel(
          'Recent incidents',
          Icons.warning_amber_outlined,
          SizedBox(height: 155, child: !adminFeedReady
            ? _compactPlaceholder(Icons.cloud_off_outlined,
                'Incident history unavailable', 'Unable to load recorded alerts')
            : severe.isEmpty
              ? _compactPlaceholder(Icons.shield_outlined,
                  'No alerts in loaded records', 'New recorded incidents appear here')
              : ListView.separated(
                  primary: false,
                  itemCount: severe.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final e = severe[index];
                    return _compactPlaceholder(
                      Icons.warning_amber_outlined,
                      '${e['event_type'] ?? e['type'] ?? 'Incident'}',
                      '${e['created_at'] ?? 'Time unknown'}',
                      warning: true);
                  })));
        if (!wide) {
          return Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(width: leftWidth, child: status),
            SizedBox(width: rightWidth, child: incidents),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: leftWidth, height: rowHeight, child: status),
          const SizedBox(width: 12),
          SizedBox(width: rightWidth, height: rowHeight, child: incidents),
        ]);
      }),
      const SizedBox(height: 12),
      const RoomSensorPanel(compact: true, adminDiagnostics: true),
      const SizedBox(height: 10),
    ]);
  }

  bool _isAlert(Map<String, dynamic> e) {
    final v = '${e['event_type'] ?? e['type'] ?? ''} ${e['severity'] ?? ''}'
        .toLowerCase();
    return [
      'fire',
      'flame',
      'smoke',
      'intrusion',
      'alarm',
      'alert',
      'critical',
      'gas'
    ].any(v.contains);
  }

  bool _deviceIsFresh(Map<String, dynamic> d) {
    if (!heartbeatFeedReady) return false;
    final id = '${d['device_id'] ?? ''}';
    if (id.isEmpty) return false;
    final matching = heartbeats.where((h) => '${h['device_id'] ?? ''}' == id);
    if (matching.isEmpty) return false;
    // A registry row's updated_at is NOT proof that hardware is connected.
    DateTime? latest;
    for (final beat in matching) {
      final parsed = DateTime.tryParse(
          '${beat['updated_at'] ?? beat['created_at'] ?? ''}');
      if (parsed != null && (latest == null || parsed.isAfter(latest))) {
        latest = parsed;
      }
    }
    final parsed = latest;
    if (parsed == null) {
      return false;
    }
    final age = DateTime.now().toUtc().difference(parsed.toUtc());
    return !age.isNegative && age < const Duration(minutes: 5);
  }

  Widget _compactPlaceholder(IconData icon, String title, String subtitle,
      {bool warning = false}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: AppColors.maroonMid.withValues(alpha: .05),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.border(context)),
    ),
    child: Row(children: [
      Icon(icon, color: warning ? AppColors.redBright : AppColors.orange, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary(context))),
      ])),
    ]),
  );

  Widget _dashPanel(String title, IconData icon, Widget child) => GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: AppColors.orange),
          const SizedBox(width: 7),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14)))
        ]),
        const SizedBox(height: 12),
        child,
      ]));

  Widget _dashKpi(String label, String value, IconData icon, Color color,
          String hint, int destination) =>
      GlassPanel(
          padding: const EdgeInsets.all(13),
          child: InkWell(
              onTap: () => setState(() => _selected = destination),
              child: Row(children: [
                Container(
                    width: 43,
                    height: 43,
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, color: color)),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label, style: const TextStyle(fontSize: 11)),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 23, fontWeight: FontWeight.w900)),
                      Text(hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 9,
                              color: AppTheme.textSecondary(context))),
                    ])),
                const Icon(Icons.chevron_right, size: 15),
              ])));

  Widget _legend(String label, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 10)),
      ]);

  Widget _healthTile(String label, String status, bool healthy) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          border: Border.all(color: AppTheme.border(context)),
          borderRadius: BorderRadius.circular(12),
          color: AppColors.maroonMid.withValues(alpha: .06)),
      child: Row(children: [
        Icon(healthy ? Icons.check_circle_outline : Icons.info_outline,
            color: healthy ? AppColors.green : AppColors.amber, size: 19),
        const SizedBox(width: 7),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          Text(status, style: const TextStyle(fontSize: 10)),
        ]))
      ]));

  // Kept for future admin analytics views without altering current layout.
  // ignore: unused_element
  Widget _analyticsPanel() {
    final resolved = ticketMetrics['resolved'] ?? 0;
    final total = ticketMetrics['total'] ?? 0;
    final pendingCommands = commands
        .where(
            (c) => !['applied', 'completed', 'success'].contains(c['status']))
        .length;
    final pendingSync = syncPending.length + ledgerPending.length;
    return LayoutBuilder(builder: (context, bounds) {
      final width =
          bounds.maxWidth >= 750 ? (bounds.maxWidth - 12) / 2 : bounds.maxWidth;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        SizedBox(
            width: width,
            child: _chartPanel(
                'Ticket priority',
                Icons.support_agent,
                [
                  (
                    'Critical',
                    ticketMetrics['critical'] ?? 0,
                    AppColors.redBright
                  ),
                  ('Major', ticketMetrics['major'] ?? 0, AppColors.amber),
                  (
                    'In progress',
                    ticketMetrics['active'] ?? 0,
                    AppColors.orange
                  ),
                  ('Resolved', resolved, AppColors.green),
                ],
                note: ticketMetricsError ??
                    '$resolved of $total resolved or closed')),
        SizedBox(
            width: width,
            child: _chartPanel(
                'System operations',
                Icons.monitor_heart_outlined,
                [
                  ('Registered devices', devices.length, AppColors.green),
                  ('Pending commands', pendingCommands, AppColors.amber),
                  ('Sync backlog', pendingSync, AppColors.redBright),
                  (
                    'Unassigned tickets',
                    ticketMetrics['unassigned'] ?? 0,
                    AppColors.orange
                  ),
                ],
                note: 'Counts are live records, not device uptime')),
        SizedBox(width: width, child: _statusPanel()),
      ]);
    });
  }

  Widget _chartPanel(
      String title, IconData icon, List<(String, int, Color)> items,
      {String? note}) {
    final maximum =
        items.fold<int>(1, (max, item) => item.$2 > max ? item.$2 : max);
    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: AppColors.orange),
          const SizedBox(width: 8),
          Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w800)))
        ]),
        const SizedBox(height: 12),
        for (final item in items)
          Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(children: [
                Row(children: [
                  Expanded(
                      child:
                          Text(item.$1, style: const TextStyle(fontSize: 12))),
                  Text('${item.$2}',
                      style: const TextStyle(fontWeight: FontWeight.w700))
                ]),
                const SizedBox(height: 4),
                ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                        value: item.$2 / maximum,
                        minHeight: 8,
                        backgroundColor: AppTheme.border(context),
                        color: item.$3)),
              ])),
        if (note != null)
          Text(note,
              style: TextStyle(
                  fontSize: 10, color: AppTheme.textSecondary(context))),
      ]),
    );
  }

  Widget _statusPanel() => GlassPanel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Infrastructure health',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _healthLine('Supabase', databaseHealth['supabase'] == true),
          _healthLine('MySQL mirror', databaseHealth['mysql'] == true),
          _healthLine('Mirror worker', databaseHealth['worker_online'] == true),
          const SizedBox(height: 6),
          Text('Unknown / unavailable is never interpreted as healthy.',
              style: TextStyle(
                  fontSize: 10, color: AppTheme.textSecondary(context))),
        ]),
      );

  Widget _healthLine(String label, bool healthy) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(healthy ? Icons.check_circle : Icons.error_outline,
              size: 16, color: healthy ? AppColors.green : AppColors.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(healthy ? 'Healthy' : 'Not verified',
              style: const TextStyle(fontSize: 11))
        ]),
      );

  Widget _section(String title, List<Widget> children) {
    final page = title.startsWith('ADMIN')
        ? 1
        : title.startsWith('LATEST USERS')
            ? 2
            : (title.startsWith('DEVICE') || title.startsWith('HARDWARE'))
                ? 3
                : title.startsWith('ALERTS')
                    ? 4
                    : title.startsWith('DATABASE')
                        ? 6
                        : 5;
    if (_selected == 7 || _selected == 0 || _selected != page) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            style: TextStyle(
                color: AppTheme.textSecondary(context),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: .6)),
        const SizedBox(height: 8),
        GlassPanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _PyroTrendPainter extends CustomPainter {
  final List<int> events, alerts, tickets;
  _PyroTrendPainter(this.events, this.alerts, this.tickets);
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: .19)
      ..strokeWidth = .7;
    for (var i = 0; i < 5; i++) {
      final y = 12 + (size.height - 26) * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final maxValue =
        [1, ...events, ...alerts, ...tickets].reduce((a, b) => a > b ? a : b);
    void line(List<int> values, Color color) {
      if (values.isEmpty) {
        return;
      }
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final point = Offset(i * size.width / (values.length - 1),
            12 + (size.height - 26) * (1 - values[i] / maxValue));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = 2.4
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    }

    line(events, AppColors.redBright);
    line(alerts, AppColors.amber);
    line(tickets, Colors.pinkAccent);
  }

  @override
  bool shouldRepaint(covariant _PyroTrendPainter old) => true;
}

class _PyroDonutPainter extends CustomPainter {
  final List<int> values;
  final List<Color> colors;
  _PyroDonutPainter(this.values, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    final sum = values.fold<int>(0, (a, b) => a + b);
    final radius = (size.shortestSide - 20) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -1.5707963267948966;
    var angle = start;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16;
    if (sum == 0) {
      paint.color = Colors.grey.withValues(alpha: .25);
      canvas.drawArc(rect, 0, 6.283185307179586, false, paint);
      return;
    }
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) {
        continue;
      }
      final sweep = 6.283185307179586 * values[i] / sum;
      paint.color = colors[i];
      canvas.drawArc(rect, angle, sweep, false, paint);
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PyroDonutPainter old) => true;
}
