import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../responsive.dart';
import '../../services/admin_service.dart';
import '../dashboard/main_shell.dart' show PyroDesktopSidebar, PyroMobileDrawer, PyroMobileBottomNav, PyroNavigationItem, PyroBottomItem;
import '../dashboard/shared_app_bar.dart';
import '../../services/dual_sync_service.dart';
import '../../theme.dart';


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
  int _selected = 0;
  bool _syncing = false;
  bool _managing = false;
  List<Map<String,dynamic>> commands = const [];
  static const _menus = [
    ('Overview', Icons.dashboard_outlined),
    ('Administrators', Icons.admin_panel_settings_outlined),
    ('Users', Icons.people_outline),
    ('Devices', Icons.sensors_outlined),
    ('Alerts', Icons.warning_amber_outlined),
    ('Activity', Icons.history),
    ('Database sync', Icons.cloud_sync_outlined),
  ];
  String get _name {
    final user = Supabase.instance.client.auth.currentUser;
    for (final value in [AdminService.instance.record?['display_name'],
      user?.userMetadata?['full_name'], user?.userMetadata?['display_name'],
      user?.email?.split('@').first]) {
      if (value != null && value.toString().trim().isNotEmpty) return value.toString().trim();
    }
    return 'Administrator';
  }

  Future<void> _logout() async {
    try { await DualSyncService.instance.recordSessionEvent(event: 'admin_logout', admin: true); } catch (_) {}
    await Supabase.instance.client.auth.signOut();
    if (mounted) context.go('/login');
  }

  List<PyroNavigationItem> get _navigationItems => [
    for (var i=0; i<_menus.length; i++)
      (path: '$i', icon: _menus[i].$2, activeIcon: _menus[i].$2, label: _menus[i].$1),
  ];
  List<PyroBottomItem> get _bottomItems => [for (final i in [0,2,3,5,6])
    (path: '$i', icon: _menus[i].$2, active: _menus[i].$2, label: i == 6 ? 'Sync' : _menus[i].$1),
  ];
  void _selectPage(String path) => setState(() => _selected = int.parse(path));
  Timer? _refreshTimer;
  Timer? _debounce;
  RealtimeChannel? _changes;
  bool _fetching = false;
  List<Map<String,dynamic>> latestUsers = const [];
  bool usersTruncated = false;


  bool loading = true;
  String? error;
  List<Map<String, dynamic>> admins = const [];
  List<Map<String, dynamic>> profiles = const [];
  List<Map<String, dynamic>> identities = const [];
  List<Map<String, dynamic>> devices = const [];
  List<Map<String, dynamic>> events = const [];
  List<Map<String, dynamic>> readings = const [];
  List<Map<String, dynamic>> syncPending = const [];
  List<Map<String, dynamic>> ledgerPending = const [];
  Map<String, dynamic> databaseHealth = const {};

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
    _changes = Supabase.instance.client.channel('admin-account-refresh')
      .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'profiles', callback: (_) => _scheduleReload())
      .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'account_identities', callback: (_) => _scheduleReload())
      .subscribe();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _load(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel(); _debounce?.cancel();
    if (_changes != null) Supabase.instance.client.removeChannel(_changes!);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted || _fetching) return;
    _fetching = true;
    if (!silent) setState(() { loading = true; error = null; });
    try {
      await AdminService.instance.refresh();
      if (!AdminService.instance.isAdmin) throw StateError('Administrator access is required.');
      final response = await Supabase.instance.client.functions.invoke('admin-console', body: {'action':'read'});
      final raw = response.data;
      if (raw is! Map || raw['ok'] != true) throw StateError('Admin data is unavailable. Deploy admin-console and check its logs.');
      if (!mounted) return;
      setState(() {
        admins = _maps(raw['admins']);
        profiles = _maps(raw['profiles']);
        identities = _maps(raw['identities']);
        latestUsers = _maps(raw['users']);
        usersTruncated = raw['auth_scan_truncated'] == true;
        commands = _maps(raw['commands']);
        devices = _maps(raw['devices']); events = _maps(raw['events']);
        syncPending = _maps(raw['mirrors']); ledgerPending = _maps(raw['ledger']);
        databaseHealth = raw['health'] is Map ? Map<String,dynamic>.from(raw['health'] as Map) : {};
        final failures = raw['failures'];
        error = failures is List && failures.isNotEmpty ? failures.join('\n') : null;
      });
    } catch(e) {
      if (mounted) setState(() => error = 'Admin data could not refresh: $e');
    } finally {
      _fetching = false;
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> _maps(dynamic rows) =>
      rows is List ? rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];

  Future<void> _manage(Map<String,dynamic> body) async {
    if (_managing) return;
    setState(() => _managing = true);
    try {
      final response = await Supabase.instance.client.functions.invoke('admin-console', body: body);
      final raw = response.data;
      if (raw is! Map || raw['ok'] != true) throw StateError(raw is Map ? '${raw['error']}' : 'Management request failed');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(body['action'] == 'queue_security'
        ? 'Command ${raw['command']?['id']} queued. Wait for the device acknowledgement below.'
        : 'Saved in Supabase. The MySQL worker will mirror this change.')));
      await _load(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action failed: $e')));
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  Future<void> _manageUser(Map<String,dynamic> user) async {
    final disabled = user['account_status'] == 'disabled';
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(disabled ? 'Enable user?' : 'Disable user?'),
      content: Text('${user['email']}\n${disabled ? 'Allow this user to sign in again.' : 'Block future sign-ins. Existing access tokens may remain valid until expiry.'}'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm'))]));
    if (confirmed == true && mounted) await _manage({'action':'manage_user','user_id':user['user_id'], 'account_status':disabled ? 'active' : 'disabled'});
  }

  Future<void> _renameDevice(Map<String,dynamic> device) async {
    final input = TextEditingController(text: '${device['device_name'] ?? ''}');
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename device'),
      content: TextField(controller: input, maxLength: 120, decoration: const InputDecoration(labelText: 'Device name')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, input.text.trim()), child: const Text('Save'))]));
    input.dispose();
    if (name != null && name.isNotEmpty && mounted) await _manage({'action':'manage_device','device_id':device['device_id'],'device_name':name});
  }

  Future<void> _retryDualSync() async {
    if (_syncing || loading) return;
    setState(() => _syncing = true);
    try {
    final response = await Supabase.instance.client.functions.invoke('admin-console', body: {'action':'sync'});
    final raw = response.data;
    if (raw is! Map || raw['ok'] != true) throw StateError('Administrator account sync failed.');
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(databaseHealth['mode'] == 'local-pc'
        ? 'Sync requested. Keep the PC worker running and wait for its next completed cycle.'
        : databaseHealth['mysql'] == true
        ? 'Account sync checked. Review each user’s verified/pending result below.'
        : 'MySQL is still unavailable. Open Database sync for the setup details.')),
    );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync retry failed: $e')));
    } finally { if (mounted) setState(() => _syncing = false); }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    final content = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            Responsive.horizontalPadding(context), 12,
            Responsive.horizontalPadding(context), 110),
          children: [
            if (loading) const LinearProgressIndicator(color: AppColors.orange),
            if (error != null) _panel(child: Text(error!, style: TextStyle(color: AppTheme.dangerForeground(context)))),
            if (!loading && AdminService.instance.isAdmin) ...[
              GlassPanel(
                padding: const EdgeInsets.all(16),
                borderColor: AppColors.maroonMid.withValues(alpha: .38),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(gradient: GlassStyle.brandGradient, borderRadius: BorderRadius.circular(13)),
                    child: const Icon(Icons.admin_panel_settings_outlined, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      AdminService.instance.isHeadDeveloper ? 'HEAD DEVELOPER CONSOLE' : 'ADMINISTRATOR CONSOLE',
                      style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AdminService.instance.isHeadDeveloper
                          ? 'Welcome, $_name. Review accounts, monitor devices and alerts, and check database synchronization.'
                          : 'Welcome, $_name. Use the admin menu to review users, devices, alerts and database status.',
                      style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11, height: 1.4),
                    ),
                  ])),
                ]),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, c) {
                final cards = [
                  _stat('Fixed Admins', '${admins.length}/4', Icons.admin_panel_settings_outlined, AppColors.orange),
                  _stat('Recent Homeowners', '${latestUsers.length}', Icons.people_outline, AppColors.green),
                  _stat('Loaded Devices', error == null ? '${devices.length}' : '—', Icons.developer_board_outlined, AppColors.amber),
                  _stat('Dual Sync Pending', '${syncPending.length + ledgerPending.length + identities.where((e) => e['mysql_synced'] != true).length}', Icons.sync_problem_outlined,
                      (error == null && databaseHealth['mysql'] == true && databaseHealth['verified_accounts'] == databaseHealth['account_verification_scope'] && syncPending.isEmpty && ledgerPending.isEmpty && identities.every((e) => e['mysql_synced'] == true)) ? AppColors.green : AppColors.redBright),
                ];
                final columns = c.maxWidth >= 900 ? 4 : c.maxWidth >= 360 ? 2 : 1;
                return Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final card in cards)
                    SizedBox(width: (c.maxWidth - 10 * (columns - 1)) / columns, child: card),
                ]);
              }),
              const SizedBox(height: 14),
              _section('ADMIN ACCOUNTS', [
                for (final a in admins)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.orange.withValues(alpha: .15),
                      child: Icon(
                        a['admin_role'] == 'head_developer' ? Icons.code : Icons.admin_panel_settings,
                        color: AppTheme.brandForeground(context),
                      ),
                    ),
                    title: Text('${a['display_name'] ?? a['email']}',
                        style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        '${a['email']} · ${a['admin_role']}\nReference: ${a['admin_reference_code'] ?? 'Not set'}',
                        style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11),
                      ),
                    trailing: Text(a['active'] == true ? 'ACTIVE' : 'DISABLED',
                        style: TextStyle(color: a['active'] == true ? AppTheme.safeForeground(context) : AppTheme.dangerForeground(context),
                            fontSize: 10, fontWeight: FontWeight.w900)),
                  ),
              ]),
              const SizedBox(height: 14),
              _section('DATABASE COMMUNICATION', [
                ListTile(
                  leading: Icon(
                    databaseHealth['supabase'] == true && databaseHealth['mysql'] == true
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: databaseHealth['supabase'] == true && databaseHealth['mysql'] == true
                        ? AppColors.green
                        : AppColors.amber,
                  ),
                  title: Text(
                    databaseHealth['supabase'] == true && databaseHealth['mysql'] == true
                        ? 'Supabase and MySQL are both reachable'
                        : 'Database communication needs attention',
                    style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    'Supabase: ${databaseHealth['supabase'] == true ? 'CONNECTED' : 'UNAVAILABLE'}  ·  '
                    'MySQL: ${databaseHealth['mysql'] == true ? 'CONNECTED' : 'UNAVAILABLE'}\n'
                    'Last checked: ${databaseHealth['checked_at'] ?? 'Unavailable'}\n'
                    '${databaseHealth['mode'] == 'local-pc' ? 'Local PC tables verified' : 'MySQL mirror schema'}: ${databaseHealth['mysql_schema_parity'] == true ? '25/25 TABLES' : '${databaseHealth['mysql_table_count'] ?? 0}/${databaseHealth['mysql_expected_table_count'] ?? 25} TABLES'}\n'
                    '${databaseHealth['mode'] == 'local-pc' ? 'Last completed local cycle: ${databaseHealth['last_completed_at'] ?? 'Waiting'}\n' : ''}'
                    'Account comparisons: ${databaseHealth['verified_accounts'] ?? 0}/${databaseHealth['account_verification_scope'] ?? 0} loaded homeowners match the MySQL profile, identity and registration snapshot. See table results for the local worker’s other record types.',
                    style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 13, height: 1.45),
                  ),
                ),
                if (databaseHealth['mode'] == 'local-pc') ...[
                  ListTile(
                    leading: Icon(Icons.computer, color: databaseHealth['worker_online'] == true ? AppColors.green : AppColors.amber),
                    title: Text('Local MySQL on your PC', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700)),
                    subtitle: Text('Worker: ${databaseHealth['worker_online'] == true ? 'ONLINE' : 'OFFLINE'} · Cycle: ${databaseHealth['cycle_complete'] == true ? 'COMPLETED' : 'PENDING'}\nSupabase is the source. MySQL catches up while your PC worker is running.', style: TextStyle(color: AppTheme.textSecondary(context))),
                  ),
                  if (databaseHealth['table_results'] is Map)
                    for (final entry in (databaseHealth['table_results'] as Map).entries)
                      ListTile(
                        dense: true,
                        leading: Icon(entry.value is Map && entry.value['state'] == 'verified' ? Icons.check_circle_outline : Icons.sync_problem_outlined, color: entry.value is Map && entry.value['state'] == 'verified' ? AppColors.green : AppColors.amber),
                        title: Text(entry.key.toString(), style: TextStyle(color: AppTheme.textPrimary(context))),
                        subtitle: Text(entry.value is Map ? '${entry.value['state']} · ${entry.value['verified_rows'] ?? 0}/${entry.value['rows'] ?? 0} rows checked' : 'Pending', style: TextStyle(color: AppTheme.textSecondary(context))),
                      ),
                ],
                if (databaseHealth['error'] != null)
                  ListTile(
                    leading: Icon(Icons.info_outline, color: AppColors.amber),
                    title: Text('Communication detail', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700)),
                    subtitle: Text(databaseHealth['error'].toString(), style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 13)),
                  ),
                ListTile(
                  leading: Icon(
                    (error == null && databaseHealth['mysql'] == true && databaseHealth['verified_accounts'] == databaseHealth['account_verification_scope'] && syncPending.isEmpty && ledgerPending.isEmpty && identities.every((e) => e['mysql_synced'] == true))
                        ? Icons.verified_outlined
                        : Icons.sync_problem_outlined,
                    color: (error == null && databaseHealth['mysql'] == true && databaseHealth['verified_accounts'] == databaseHealth['account_verification_scope'] && syncPending.isEmpty && ledgerPending.isEmpty && identities.every((e) => e['mysql_synced'] == true))
                        ? AppColors.green
                        : AppColors.amber,
                  ),
                  title: Text(
                    (error == null && databaseHealth['mysql'] == true && databaseHealth['verified_accounts'] == databaseHealth['account_verification_scope'] && syncPending.isEmpty && ledgerPending.isEmpty && identities.every((e) => e['mysql_synced'] == true))
                        ? 'No pending records in the loaded sample'
                        : error != null ? 'Pending status is incomplete; review the query error above' : 'Account data or pending records still need verification / sync',
                    style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    'Loaded pending mirror/ledger/account records: ${syncPending.length + ledgerPending.length + identities.where((e) => e['mysql_synced'] != true).length}. The Sync button retries hosted mirroring or requests the PC worker’s next full cycle.',
                    style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              _section('ALERTS & INCIDENT TRIAGE', [
                ...events.where((e) {
                  final label = '${e['event_type'] ?? e['type'] ?? ''} ${e['severity'] ?? ''}'.toLowerCase();
                  return label.contains('alert') || label.contains('alarm') ||
                      label.contains('fire') || label.contains('smoke') ||
                      label.contains('intrusion') || label.contains('critical');
                }).take(30).map((e) => ListTile(
                  leading: const Icon(Icons.warning_amber_outlined, color: Colors.orange),
                  title: Text('${e['event_type'] ?? e['type'] ?? 'Alert'}'),
                  subtitle: Text('${e['created_at'] ?? 'Time unavailable'}'),
                )),
                if (!events.any((e) {
                  final label = '${e['event_type'] ?? e['type'] ?? ''} ${e['severity'] ?? ''}'.toLowerCase();
                  return label.contains('alert') || label.contains('alarm') ||
                      label.contains('fire') || label.contains('smoke') ||
                      label.contains('intrusion') || label.contains('critical');
                })) const ListTile(title: Text('No alert events in the latest 100 records')),
              ]),
              const SizedBox(height: 14),
              _section('DEVICE & SENSOR MANAGEMENT', [
                if (devices.isEmpty) const ListTile(title: Text('No devices available')),
                for (final d in devices)
                  ListTile(
                    leading: const Icon(Icons.sensors_outlined),
                    title: Text('${d['name'] ?? d['device_name'] ?? d['id'] ?? 'Device'}'),
                    subtitle: Text('Device ID: ${d['device_id'] ?? 'unknown'} • Status: ${d['status'] ?? 'not reported'}'),
                    trailing: PopupMenuButton<String>(enabled: !_managing,
                      tooltip: 'Manage device',
                      onSelected: (action) {
                        if (action == 'rename') { _renameDevice(d); }
                        else { _manage({'action':'queue_security','device_id':d['device_id'],'arm_mode':action}); }
                      }, itemBuilder: (_) => const [
                        PopupMenuItem(value:'rename', child:Text('Rename device')),
                        PopupMenuItem(value:'ARM_HOME', child:Text('Queue Arm Home')),
                        PopupMenuItem(value:'ARM_AWAY', child:Text('Queue Arm Away')),
                        PopupMenuItem(value:'DISARMED', child:Text('Queue Disarm'))]),
                  ),
              ]),
              const SizedBox(height: 14),
              _section('HARDWARE COMMAND STATUS', [
                if (commands.isEmpty) const ListTile(title: Text('No device commands returned')),
                for (final command in commands.take(20)) ListTile(
                  title: Text('${command['command']} · ${command['status']}'),
                  subtitle: Text('${command['target_device_id']} · ${command['created_at']}\n${command['result_message'] ?? 'Awaiting device result'}'),
                  isThreeLine: true,
                  trailing: Icon(command['status'] == 'applied' ? Icons.check_circle_outline : Icons.pending_outlined)),
              ]),
              const SizedBox(height: 14),
              _section('SYSTEM MONITORING & ACTIVITY LOGS', [
                ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined),
                  title: Text('Devices tracked: ${devices.length}'),
                  subtitle: Text('Events recorded: ${events.length} • Pending mirror records: ${syncPending.length + ledgerPending.length}'),
                ),
                for (final e in events.take(15))
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text('${e['event_type'] ?? e['type'] ?? 'System event'}'),
                    subtitle: Text('${e['created_at'] ?? 'Time unavailable'}'),
                  ),
              ]),
              const SizedBox(height: 14),
              _section('LATEST USERS', [
                if (usersTruncated) const ListTile(title: Text('Account scan is limited to 5,000 Auth records; newest users are shown within that scan.')),
                if (latestUsers.isEmpty) const ListTile(title: Text('No homeowner accounts returned by the Auth service.')),
                for (final u in latestUsers)
                  ListTile(
                    leading: Icon(Icons.person_outline, color: AppTheme.brandForeground(context)),
                    title: Text((u['full_name'] ?? u['email'] ?? 'Unnamed account').toString(),
                      style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700)),
                    subtitle: Text('${u['email'] ?? ''}\nCreated: ${u['created_at'] ?? 'Unavailable'}\n'
                      '${u['email_confirmed'] == true ? 'Email verified' : 'Awaiting email verification'} · '
                      '${u['email_confirmed'] != true ? 'Application registration pending confirmation' : u['profile_present'] == true ? 'Profile present' : u['profile_present'] == false ? 'PROFILE MISSING' : 'PROFILE READ UNAVAILABLE'} · '
                      '${u['identity_present'] == true ? 'Identity present' : u['identity_present'] == false ? 'IDENTITY MISSING' : 'IDENTITY READ UNAVAILABLE'}\n'
                      'MySQL: ${_verificationLabel(u['verification'])}',
                      style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12)),
                    isThreeLine: true,
                    trailing: IconButton(tooltip: u['account_status'] == 'disabled' ? 'Enable user' : 'Disable user',
                      onPressed: _managing || u['email_confirmed'] != true ? null : () => _manageUser(u),
                      icon: Icon(u['account_status'] == 'disabled' ? Icons.person_add_alt : Icons.person_off_outlined)),
                  ),
              ]),
              const SizedBox(height: 14),
              _section('LATEST EVENTS · SUPABASE + MYSQL MIRROR', [
                if (events.isEmpty)
                  const ListTile(title: Text('No events recorded yet.')),
                for (final e in events.take(15))
                  ListTile(
                    leading: Icon(Icons.history, color: e['mysql_synced'] == true ? AppColors.green : AppColors.amber),
                    title: Text((e['event_type'] ?? 'event').toString(),
                        style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700)),
                    subtitle: Text((e['message'] ?? e['created_at'] ?? '').toString(),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11)),
                    trailing: Text(e['mysql_synced'] == true ? 'DUAL SAVED' : 'SYNC PENDING',
                        style: TextStyle(color: e['mysql_synced'] == true ? AppColors.green : AppColors.amber,
                            fontSize: 9, fontWeight: FontWeight.w900)),
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
      endDrawer: desktop ? null : PyroMobileDrawer(path:'$_selected', name:_name, email:email,
        onNav:_selectPage, onLogout:_logout, items:_navigationItems, adminWorkspace:true),
      bottomNavigationBar: desktop ? null : PyroMobileBottomNav(path:'$_selected', onNav:_selectPage, customItems:_bottomItems),
      body: AmbientBackdrop(child: Row(children: [
        if (desktop) PyroDesktopSidebar(path:'$_selected', name:_name, email:email,
          onNav:_selectPage, onLogout:_logout, items:_navigationItems, adminWorkspace:true),
        Expanded(child: Scaffold(backgroundColor: Colors.transparent,
          appBar: PyroAppBar(title:'PyroGuard · $_name', subtitle:'${_menus[_selected].$1} · Administrator',
            systemOnline:databaseHealth['supabase'] == true,
            onOpenMenu:() => _scaffoldKey.currentState?.openEndDrawer(),
            extraActions:[
              IconButton(onPressed:loading || _syncing ? null : _retryDualSync, tooltip:'Sync actual homeowner accounts', icon:const Icon(Icons.sync)),
              IconButton(onPressed:loading ? null : _load, tooltip:'Refresh admin data', icon:const Icon(Icons.refresh)),
            ]),
          body:content)),
      ])),
    );
  }

  String _verificationLabel(dynamic status) => switch(status) {
    'awaiting_confirmation' => 'AWAITING EMAIL CONFIRMATION',
    'verified' => 'PROFILE + IDENTITY + REGISTRATION VERIFIED',
    'pending' => 'LOCAL SYNC PENDING',
    'source_unavailable' => 'SOURCE READ UNAVAILABLE',
    'source_missing' => 'SOURCE RECORD MISSING — USE SYNC TO REPAIR',
    'mysql_missing' => 'MYSQL RECORD MISSING — SYNC PENDING',
    'mismatch' => 'DATA MISMATCH — REVIEW / SYNC',
    _ => 'VERIFICATION UNAVAILABLE',
  };

  Widget _panel({required Widget child}) => GlassPanel(
    padding: const EdgeInsets.all(16), child: child);

  Widget _section(String title, List<Widget> children) {
    final page = title.startsWith('ADMIN') ? 1 : title.startsWith('LATEST USERS') ? 2
      : (title.startsWith('DEVICE') || title.startsWith('HARDWARE')) ? 3 : title.startsWith('ALERTS') ? 4
      : title.startsWith('DATABASE') ? 6 : 5;
    if (_selected != 0 && _selected != page) return const SizedBox.shrink();
    return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: TextStyle(color: AppTheme.textSecondary(context),
          fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .6)),
      const SizedBox(height: 8),
      GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    ],
  );

  }

  Widget _stat(String title, String value, IconData icon, Color color) => GlassPanel(
    padding: const EdgeInsets.all(14),
    child: Row(children: [
      Container(width: 38, height: 38,
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(11)),
        child: Icon(icon, color: AppTheme.statusForeground(context, color), size: 20)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 18, fontWeight: FontWeight.w900)),
        Text(title, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 13)),
      ])),
    ]),
  );
}
