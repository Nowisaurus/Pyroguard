import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../services/admin_service.dart';
import 'feedback_form_page.dart';
import '../../responsive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Ticket priority and resolution are server-enforced admin-only fields.
class SupportTicketsPage extends StatefulWidget {
  const SupportTicketsPage({super.key});
  @override
  State<SupportTicketsPage> createState() => _SupportTicketsPageState();
}

class _SupportTicketsPageState extends State<SupportTicketsPage> {
  final db = Supabase.instance.client;
  bool loading = true, admin = false, sending = false;
  String? error;
  String statusFilter = 'all';
  String searchText = '';
  List<Map<String, dynamic>> tickets = [];
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      // The homeowner's feedback history must work even when the optional
      // admin-role RPC has not been deployed. Supabase RLS still enforces
      // which tickets this user may access.
      bool isAdmin = false;
      try {
        isAdmin = await db.rpc('pg_ticket_admin') == true;
      } catch (e) {
        debugPrint('Optional feedback admin-role lookup unavailable: $e');
      }
      final result = await db
          .from('support_tickets')
          .select('*')
          .isFilter('archived_at', null)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        admin = isAdmin;
        tickets = List<Map<String, dynamic>>.from(result); // Supabase RLS determines which tickets this account can read.
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is PostgrestException
              ? 'Support tickets unavailable: ${e.message}'
              : 'Unable to load support tickets. Check the connection and retry.';
          loading = false;
        });
      }
    }
  }

  Future<void> createTicket([String initialCategory = 'problem']) async {
    final submitted = await Navigator.of(context).push<bool>(
      PageRouteBuilder<bool>(
        opaque: true,
        pageBuilder: (_, __, ___) => FeedbackFormPage(initialCategory: initialCategory),
      ),
    );
    if (submitted == true && mounted) await refresh();
  }

  Future<void> openTicket(Map<String, dynamic> ticket) async {
    final id = ticket['id'].toString();
    String replyText = '';
    String resolutionText = ticket['resolution_notes']?.toString() ?? '';
    int replyFieldVersion = 0;
    String severity = ticket['severity']?.toString() ?? 'normal';
    String status = ticket['status']?.toString() ?? 'open';
    String? assignee = ticket['assigned_to']?.toString() ?? 'unassigned';
    bool internal = false;
    bool busy = false;
    List<Map<String, dynamic>> messages = [];
    List<Map<String, dynamic>> events = [];
    List<Map<String, dynamic>> admins = [];
    Future<void> load() async {
      final data = await db
          .from('support_ticket_messages')
          .select('*')
          .eq('ticket_id', id)
          .order('created_at');
      messages = List<Map<String, dynamic>>.from(data);
      if (admin) {
        final changes = await db
            .from('support_ticket_events')
            .select('*')
            .eq('ticket_id', id)
            .order('created_at', ascending: false);
        events = List<Map<String, dynamic>>.from(changes);
        // The admin-console Edge Function reads the complete registry using
        // server-side authorization. A restricted client-side RLS query may
        // otherwise return only the currently signed-in administrator.
        final byId = <String, Map<String, dynamic>>{};
        try {
          final response = await db.functions.invoke(
            'admin-console',
            body: {'action': 'read'},
          );
          final raw = response.data;
          if (raw is Map && raw['ok'] == true && raw['admins'] is List) {
            for (final item in raw['admins'] as List) {
              if (item is! Map) continue;
              final a = Map<String, dynamic>.from(item);
              final userId = a['user_id']?.toString();
              if (userId != null && userId.isNotEmpty && a['active'] == true) {
                byId[userId] = a;
              }
            }
          }
        } catch (e) {
          debugPrint('Full administrator registry unavailable: $e');
        }
        if (byId.isEmpty) {
          final people = await db
              .from('admin_accounts')
              .select('user_id,display_name,active')
              .eq('active', true);
          for (final a in people) {
            final userId = a['user_id']?.toString();
            if (userId != null && userId.isNotEmpty) {
              byId[userId] = Map<String, dynamic>.from(a);
            }
          }
        }
        admins = byId.values.toList()
          ..sort((a, b) => (a['display_name'] ?? a['email'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b['display_name'] ?? b['email'] ?? '')
                  .toString()
                  .toLowerCase()));
      }
    }

    try {
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text(ticket['title']?.toString() ?? 'Ticket'),
                  content: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 520,
                        maxHeight: MediaQuery.sizeOf(ctx).height * .80,
                      ),
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            Text(ticket['description']?.toString() ?? ''),
                            const SizedBox(height: 12),
                            Text(
                                'Status: $status${admin ? '  •  Priority: $severity' : ''}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            if (admin) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  initialValue: severity,
                                  decoration: const InputDecoration(
                                      labelText: 'Admin priority'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'low', child: Text('Low')),
                                    DropdownMenuItem(
                                        value: 'normal', child: Text('Normal')),
                                    DropdownMenuItem(
                                        value: 'major', child: Text('Major')),
                                    DropdownMenuItem(
                                        value: 'critical',
                                        child: Text(
                                            'Critical — immediate attention')),
                                  ],
                                  onChanged: (v) =>
                                      update(() => severity = v ?? severity)),
                              const SizedBox(height: 10),
                              DropdownButtonFormField<String>(
                                  initialValue: status,
                                  decoration: const InputDecoration(
                                      labelText: 'Ticket status'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'open', child: Text('Open')),
                                    DropdownMenuItem(
                                        value: 'in_progress',
                                        child: Text('In progress')),
                                    DropdownMenuItem(
                                        value: 'waiting_for_user',
                                        child: Text('Waiting for homeowner')),
                                    DropdownMenuItem(
                                        value: 'resolved',
                                        child: Text('Resolved')),
                                    DropdownMenuItem(
                                        value: 'closed', child: Text('Closed')),
                                    DropdownMenuItem(value: 'ignored', child: Text('Ignored')),
                                  ],
                                  onChanged: (v) =>
                                      update(() => status = v ?? status)),
                              const SizedBox(height: 10),
                              if (AdminService.instance.isHeadDeveloper)
                              DropdownButtonFormField<String>(
                                  initialValue: assignee == 'unassigned' ||
                                          admins.any((a) => a['user_id'].toString() == assignee)
                                      ? assignee
                                      : 'unassigned',
                                  decoration: const InputDecoration(
                                      labelText: 'Assigned administrator'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: 'unassigned',
                                        child: Text('Unassigned')),
                                    ...admins.map((a) => DropdownMenuItem(
                                        value: a['user_id'].toString(),
                                        child: Text(
                                            a['display_name']?.toString() ??
                                                a['user_id'].toString()))),
                                  ],
                                  onChanged: (v) => update(() => assignee = v)),
                              const SizedBox(height: 10),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                OutlinedButton.icon(onPressed: busy ? null : () => update(() => status = 'resolved'), icon: const Icon(Icons.check_circle_outline), label: const Text('Resolve')),
                                OutlinedButton.icon(onPressed: busy ? null : () => update(() => status = 'ignored'), icon: const Icon(Icons.visibility_off_outlined), label: const Text('Ignore')),
                                OutlinedButton.icon(onPressed: busy ? null : () => update(() => status = 'closed'), icon: const Icon(Icons.task_alt_outlined), label: const Text('Done / close')),
                              ]),
                              const SizedBox(height: 10),
                              TextFormField(
                                  initialValue: resolutionText,
                                  onChanged: (value) => resolutionText = value,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Resolution / troubleshooting notes')),
                              const SizedBox(height: 10),
                              FilledButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          try {
                                            update(() => busy = true);
                                            final saved = await db
                                                .from('support_tickets')
                                                .update({
                                              'severity': severity,
                                              'status': status,
                                              'assigned_to':
                                                  assignee == 'unassigned'
                                                      ? null
                                                      : assignee,
                                              'resolution_notes':
                                                  resolutionText.trim().isEmpty
                                                      ? null
                                                      : resolutionText.trim()
                                            }).eq('id', id).select('id').maybeSingle();
                                            if (saved == null) throw StateError('Ticket was not updated. Check administrator permissions.');
                                            await refresh();
                                            await load();
                                            if (ctx.mounted) update(() => busy = false);
                                          } catch (e) {
                                            if (ctx.mounted) update(() => busy = false);
                                            if (ctx.mounted) {
                                              ScaffoldMessenger.of(ctx)
                                                  .showSnackBar(SnackBar(
                                                      content: Text(
                                                          'Save failed: $e')));
                                            }
                                          }
                                        },
                                  child: const Text('Save admin decisions')),
                            ],
                            if (admin) ...[
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete from active queue (archive)'),
                                onPressed: busy || !AdminService.instance.isHeadDeveloper ? null : () async {
                                  final confirmed = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
                                    title: const Text('Archive this ticket?'),
                                    content: const Text('The ticket disappears from the active queue. Its messages and audit history remain saved for administrators.'),
                                    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete'))],
                                  ));
                                  if (confirmed != true || !ctx.mounted) return;
                                  try {
                                    update(() => busy = true);
                                    final archived = await db.from('support_tickets').update({'archived_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id).select('id').maybeSingle();
                                    if (archived == null) throw StateError('Archive denied by database permissions.');
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    await refresh();
                                  } catch (e) {
                                    if (ctx.mounted) { update(() => busy = false); ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Delete failed: $e'))); }
                                  }
                                },
                              ),
                            ],
                            const SizedBox(height: 14),
                            const Text('Conversation',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            ...messages.map((m) => Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              '${m['author_id'] == db.auth.currentUser?.id ? 'You' : 'Other participant'}${m['internal'] == true ? ' • INTERNAL ADMIN NOTE' : ''}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          Text(m['message']?.toString() ?? ''),
                                        ])))),
                            TextFormField(
                                key: ValueKey('reply_$replyFieldVersion'),
                                initialValue: replyText,
                                onChanged: (value) => replyText = value,
                                maxLines: 3,
                                maxLength: 5000,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Write a reply or describe troubleshooting steps')),
                            if (admin)
                              CheckboxListTile(
                                  value: internal,
                                  title: const Text(
                                      'Internal admin note (hidden from homeowner)'),
                                  onChanged: (v) =>
                                      update(() => internal = v ?? false)),
                            FilledButton.tonal(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        if (replyText.trim().isEmpty) return;
                                        try {
                                          update(() => busy = true);
                                          await db
                                              .from('support_ticket_messages')
                                              .insert({
                                            'ticket_id': id,
                                            'author_id':
                                                db.auth.currentUser!.id,
                                            'message': replyText.trim(),
                                            'internal': admin && internal
                                          });
                                          await load();
                                          if (!ctx.mounted) return;
                                          update(() { replyText = ''; replyFieldVersion++; busy = false; });
                                        } catch (e) {
                                          if (ctx.mounted) update(() => busy = false);
                                          if (ctx.mounted) {
                                            ScaffoldMessenger.of(ctx)
                                                .showSnackBar(SnackBar(
                                                    content: Text(
                                                        'Reply failed: $e')));
                                          }
                                        }
                                      },
                                child: const Text('Send reply')),
                            if (admin) ...[
                              const SizedBox(height: 16),
                              const Text('Admin audit history',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              ...events.map((e) => ListTile(
                                  dense: true,
                                  title: Text(
                                      '${e['action']} • ${e['created_at']}'),
                                  subtitle: Text(e['changes'].toString())))
                            ],
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Close'))
                  ],
                )));
    // TextFormField owns and disposes its own text-editing controllers.
    await refresh();
  }

  Widget _feedbackAction(IconData icon, String title, String subtitle, String category) {
    return SizedBox(width: double.infinity, child: OutlinedButton(
      onPressed: () => createTicket(category),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
        alignment: Alignment.centerLeft,
        side: BorderSide(color: AppTheme.border(context)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Row(children: [
        Icon(icon, color: AppColors.orange, size: 23),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary(context))),
          const SizedBox(height: 3),
          Text(subtitle, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context))),
        ])),
      ]),
    ));
  }

  Widget _metric(String title, int count, IconData icon, Color color) {
    return Expanded(
        child: GlassPanel(
      radius: 14,
      blur: 10,
      tint: AppTheme.isDark(context)
          ? Colors.black.withValues(alpha: .20)
          : Colors.white.withValues(alpha: .10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(height: 8),
          Text('$count',
              style:
                  const TextStyle(fontSize: 23, fontWeight: FontWeight.w900)),
          Text(title, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final visible = tickets.where((ticket) {
      final status = ticket['status']?.toString() ?? 'open';
      final matchStatus = statusFilter == 'all' || status == statusFilter;
      final needle = searchText.toLowerCase();
      final matchSearch = needle.isEmpty ||
          (ticket['title']?.toString() ?? '').toLowerCase().contains(needle) ||
          (ticket['description']?.toString() ?? '')
              .toLowerCase()
              .contains(needle) ||
          (ticket['id']?.toString() ?? '').toLowerCase().contains(needle);
      return matchStatus && matchSearch;
    }).toList();
    final open = tickets.where((t) => t['status'] == 'open').length;
    final active = tickets.where((t) => t['status'] == 'in_progress').length;
    final critical = tickets.where((t) => t['severity'] == 'critical').length;
    final major = tickets.where((t) => t['severity'] == 'major').length;
    final ignored = tickets.where((t) => t['status'] == 'ignored').length;
    final resolved = tickets
        .where((t) => t['status'] == 'resolved' || t['status'] == 'closed')
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Text(admin ? 'Support Command Center' : 'Feedback & Help'),
        actions: [
          IconButton(
              onPressed: refresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh tickets')
        ],
      ),

      backgroundColor: Colors.transparent,
      body: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(
                      child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('Unable to load support tickets: $error',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: refresh, child: const Text('Retry')),
                      ]),
                    ))
                  : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1240), child: RefreshIndicator(
                      onRefresh: refresh,
                      child: ListView(
                          padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 16, Responsive.horizontalPadding(context), 20),
                          children: [
                            if (!admin) ...[
                              GlassPanel(
                                radius: 20,
                                borderColor: AppColors.orange.withValues(alpha: .28),
                                padding: const EdgeInsets.all(20),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  const Icon(Icons.forum_outlined, color: AppColors.orange, size: 30),
                                  const SizedBox(height: 10),
                                  Text('We’re here to help', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context))),
                                  const SizedBox(height: 5),
                                  Text('Choose what you need. Each option opens a dedicated feedback form.', style: TextStyle(color: AppTheme.textSecondary(context))),
                                  const SizedBox(height: 18),
                                  LayoutBuilder(builder: (context, box) {
                                    final narrow = box.maxWidth < 520;
                                    final actions = [
                                      _feedbackAction(Icons.star_outline, 'Rate PyroGuard', 'Share your experience', 'rating'),
                                      _feedbackAction(Icons.help_outline, 'Ask a Question', 'Get help from the team', 'question'),
                                      _feedbackAction(Icons.report_problem_outlined, 'Report a Problem', 'App, device or account issue', 'problem'),
                                    ];
                                    return narrow
                                      ? Column(children: [for (final action in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: action)])
                                      : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final action in actions) Expanded(child: Padding(padding: const EdgeInsets.only(right: 10), child: action))]);
                                  }),
                                ]),
                              ),
                              const SizedBox(height: 24),
                              Row(children: [
                                Expanded(child: Text('My Feedback', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context)))),
                                Text('${tickets.length} submitted', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12)),
                              ]),
                              const SizedBox(height: 5),
                              Text('Track your reports and read replies from administrators.', style: TextStyle(color: AppTheme.textSecondary(context))),
                              const SizedBox(height: 14),
                            ],
                            if (admin) GlassPanel(
                              radius: 22,
                              padding: const EdgeInsets.all(18),
                              borderColor:
                                  AppColors.orange.withValues(alpha: .28),
                              tint: AppTheme.isDark(context)
                                  ? Colors.black.withValues(alpha: .30)
                                  : Colors.white.withValues(alpha: .10),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [

                                    Text(AdminService.instance.isHeadDeveloper ? 'ALL SUPPORT TICKETS' : 'MY ASSIGNED TICKETS',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.orange)),
                                    const SizedBox(height: 5),
                                    Text(
                                        'Review incidents, assign tickets, and track resolutions.',
                                        style: TextStyle(
                                            color: AppTheme.textSecondary(
                                                context))),
                                    const SizedBox(height: 10),
                                    Text('Critical: $critical   •   Major: $major   •   Ignored: $ignored', style: const TextStyle(fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 14),
                                    Row(children: [
                                      _metric(
                                          'Open',
                                          open,
                                          Icons.inbox_outlined,
                                          AppColors.orange),
                                      _metric(
                                          'In progress',
                                          active,
                                          Icons.pending_actions_outlined,
                                          AppColors.amber),
                                      _metric(
                                          'Resolved',
                                          resolved,
                                          Icons.task_alt_outlined,
                                          AppColors.green),
                                    ]),
                                  ]),
                            ),
                            const SizedBox(height: 16),
                            if (visible.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(28),
                                child: Center(
                                    child: Text(tickets.isEmpty
                                        ? admin ? 'No support requests yet.' : 'You have not submitted feedback yet.'
                                        : 'No tickets match your filters.')),
                              ),
                            ...visible.map((ticket) {
                              final status =
                                  (ticket['status'] ?? 'open').toString();
                              final label = status.replaceAll('_', ' ');
                              final id = ticket['id']?.toString() ?? '';
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: GlassPanel(
                                    radius: 16,
                                    blur: 10,
                                    tint: AppTheme.isDark(context)
                                        ? Colors.black.withValues(alpha: .27)
                                        : Colors.white.withValues(alpha: .10),
                                    padding: EdgeInsets.zero,
                                    child: Material(
                                      type: MaterialType.transparency,
                                      child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                      leading: CircleAvatar(
                                        backgroundColor: AppColors.orange
                                            .withValues(alpha: .16),
                                        child: const Icon(Icons.support_agent,
                                            color: AppColors.orange),
                                      ),
                                      title: Text(
                                          ticket['title']?.toString() ??
                                              'Untitled',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      subtitle: Padding(
                                        padding: const EdgeInsets.only(top: 5),
                                        child: Text(
                                            'Ticket ${id.length > 8 ? id.substring(0, 8) : id}  •  $label'
                                            '${admin ? '  •  ${ticket['severity'] ?? 'normal'}' : ''}'),
                                      ),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => openTicket(ticket),
                                    ))),
                              );
                            }),
                            const SizedBox(height: 70),
                          ]),
                    ))),
    );
  }
}
