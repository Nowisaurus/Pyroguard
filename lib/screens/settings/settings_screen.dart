// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../responsive.dart';
import '../../services/notification_service.dart';
import '../../services/location_service.dart';
import '../../services/historical_service.dart';
import '../../services/dual_sync_service.dart';
import '../../services/security_control_service.dart';
import '../../services/settings_service.dart';
import '../../theme.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      await HistoricalService.instance.retryPendingSync();
      final data = await SettingsService.instance.loadAll();
      await NotificationService.loadBfpContact();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _section(String key) => Map<String, dynamic>.from((_data[key] as Map?) ?? const {});

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _section('profile');
    final home = _section('home');
    final bfp = _section('bfp');
    final stakeholder = _section('stakeholder');
    final safety = _section('safety');

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: Colors.transparent,
                  title: Text('Settings', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900)),
                  actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh saved settings')],
                ),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 10, Responsive.horizontalPadding(context), 110),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          GlassPanel(
                            padding: const EdgeInsets.all(16),
                            borderColor: AppColors.orange.withValues(alpha: .26),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Container(width: 46, height: 46, decoration: BoxDecoration(gradient: GlassStyle.brandGradient, borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.settings_outlined, color: Colors.white)),
                              const SizedBox(width: 12),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(profile['full_name']?.toString().trim().isNotEmpty == true ? profile['full_name'].toString() : 'PyroGuard Homeowner', style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 17, fontWeight: FontWeight.w900)),
                                const SizedBox(height: 3),
                                Text(home['home_name']?.toString().trim().isNotEmpty == true ? home['home_name'].toString() : 'Complete your home setup', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11.5)),
                                const SizedBox(height: 7),
                                Wrap(spacing: 8, runSpacing: 6, children: [
                                  _Badge(icon: Icons.cloud_done_outlined, text: 'SUPABASE CONNECTED', color: AppColors.green),
                                  _Badge(icon: Icons.storage_outlined, text: 'MYSQL MIRROR', color: AppColors.orange),
                                ]),
                              ])),
                            ]),
                          ),
                          if (_loading) ...[const SizedBox(height: 16), const LinearProgressIndicator(color: AppColors.orange)],
                          if (_error != null) ...[const SizedBox(height: 12), _InfoBox(icon: Icons.error_outline, text: _error!, color: AppColors.red)],
                          const SizedBox(height: 18),
                          Text('ACCOUNT & PROPERTY', style: _sectionStyle(context)),
                          const SizedBox(height: 8),
                          _SettingsCard(children: [
                            _nav(Icons.person_outline, 'User Account', 'Name, email, phone and password recovery', () => _open(UserAccountSettingsPage(initial: profile))),
                            _nav(Icons.home_work_outlined, 'Home & Location', home['address']?.toString().trim().isNotEmpty == true ? home['address'].toString() : 'Address and pinned map location', () => _open(HomeLocationSettingsPage(initial: home))),
                            _nav(Icons.people_outline, 'Stakeholders', stakeholder['full_name']?.toString().trim().isNotEmpty == true ? '${stakeholder['full_name']} · ${stakeholder['relationship'] ?? ''}' : 'Primary person to notify', () => _open(StakeholderSettingsPage(initial: stakeholder))),
                          ]),
                          const SizedBox(height: 18),
                          Text('SAFETY & EMERGENCY', style: _sectionStyle(context)),
                          const SizedBox(height: 8),
                          _SettingsCard(children: [
                            _nav(Icons.health_and_safety_outlined, 'Safety Setup', 'Entry delay, siren duration and AI assist', () => _open(SafetySetupSettingsPage(initial: safety))),
                            _nav(Icons.local_fire_department_outlined, 'BFP Contact Details', bfp['station_name']?.toString().trim().isNotEmpty == true ? '${bfp['station_name']} · ${bfp['phone'] ?? ''}' : 'Station, personnel, number and address', () => _open(BfpSettingsPage(initial: bfp))),
                            _nav(Icons.notifications_outlined, 'Notifications', 'Push, email and optional SMS preferences', () => _open(NotificationsSettingsPage(initial: _section('preferences')))),
                            _nav(Icons.shield_outlined, 'Devices & Security Controls', 'ARM AWAY / ARM HOME / DISARM + door/window controls', () => _open(DeviceSecuritySettingsPage(initial: _section('device')))),
                          ]),
                          const SizedBox(height: 18),
                          Text('REVIEW & APP', style: _sectionStyle(context)),
                          const SizedBox(height: 8),
                          _SettingsCard(children: [
                            _nav(Icons.fact_check_outlined, 'Review Saved Information', 'Review all account, property and safety records', () => _open(const SettingsReviewPage())),
                            _nav(Icons.palette_outlined, 'Appearance', 'Light/dark mode and Phoenix glass background', () => _open(const AppearanceSettingsPage())),
                            _nav(Icons.play_circle_outline, 'PyroGuard Tutorial', 'Replay the onboarding guide', () => context.go('/tutorial')),
                            _nav(Icons.info_outline, 'About PyroGuard', 'System scope, storage and emergency behavior', () => _open(const AboutPyroGuardPage())),
                          ]),
                          const SizedBox(height: 18),
                          if (bfp['station_name']?.toString().trim().isNotEmpty == true)
                            _InfoBox(
                              icon: Icons.local_fire_department,
                              color: AppColors.red,
                              text: 'Emergency BFP contact saved: ${bfp['station_name']} · ${bfp['phone'] ?? 'No phone'}${bfp['personnel_name']?.toString().trim().isNotEmpty == true ? ' · ${bfp['personnel_name']}' : ''}. This contact is displayed with CALL BFP during a confirmed hazard.',
                            ),
                          const SizedBox(height: 18),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Sign out?'), content: const Text('Your saved setup and important records remain mirrored in both Supabase and MySQL.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign Out'))]));
                              if (yes != true) return;
                              try {
                                await DualSyncService.instance.recordSessionEvent(
                                  event: 'homeowner_logout',
                                  admin: false,
                                );
                              } catch (_) {}
                              await Supabase.instance.client.auth.signOut();
                              if (mounted) context.go('/');
                            },
                            icon: const Icon(Icons.logout, color: AppColors.red),
                            label: Text('Sign Out', style: TextStyle(color: AppTheme.dangerForeground(context), fontWeight: FontWeight.w800)),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }

  Widget _nav(IconData icon, String title, String subtitle, VoidCallback onTap) => _SettingsNavTile(icon: icon, title: title, subtitle: subtitle, onTap: onTap);
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [for (var i = 0; i < children.length; i++) ...[children[i], if (i != children.length - 1) Divider(height: 1, color: AppTheme.border(context).withValues(alpha: .75))]]),
      );
}

class _SettingsNavTile extends StatelessWidget {
  const _SettingsNavTile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(width: 38, height: 38, decoration: BoxDecoration(color: AppColors.orange.withValues(alpha: .11), borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: AppTheme.brandForeground(context), size: 20)),
        title: Text(title, style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800, fontSize: 13.5)),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, height: 1.35)),
        trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary(context)),
      );
}

TextStyle _sectionStyle(BuildContext context) => TextStyle(color: AppTheme.textSecondary(context), fontWeight: FontWeight.w900, fontSize: 10.5, letterSpacing: 1.1);

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, required this.color});
  final IconData icon; final String text; final Color color;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(99), border: Border.all(color: color.withValues(alpha: .26))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: AppTheme.statusForeground(context, color), size: 12), const SizedBox(width: 5), Text(text, style: TextStyle(color: AppTheme.statusForeground(context, color), fontSize: 8.5, fontWeight: FontWeight.w900))]));
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.icon, required this.text, required this.color});
  final IconData icon; final String text; final Color color;
  @override
  Widget build(BuildContext context) => GlassPanel(borderColor: color.withValues(alpha: .28), padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: AppTheme.statusForeground(context, color), size: 19), const SizedBox(width: 9), Expanded(child: Text(text, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 11.5, height: 1.45)))]));
}

abstract class _SettingsPageState<T extends StatefulWidget> extends State<T> {
  bool saving = false;
  String? error;
  Future<void> save(Future<void> Function() operation) async {
    setState(() { saving = true; error = null; });
    try {
      await operation();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved successfully.'), backgroundColor: Color(0xFF166534)));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _DetailScaffold extends StatelessWidget {
  const _DetailScaffold({required this.title, required this.subtitle, required this.child, this.saving = false, this.error, this.onSave, this.actions});
  final String title, subtitle;
  final Widget child;
  final bool saving;
  final String? error;
  final VoidCallback? onSave;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(title), actions: actions),
        body: PhoenixBackdrop(
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 14, Responsive.horizontalPadding(context), 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(subtitle, style: TextStyle(color: AppTheme.textSecondary(context), height: 1.45, fontSize: 12)),
                    const SizedBox(height: 12),
                    GlassPanel(padding: EdgeInsets.all(Responsive.isCompact(context) ? 14 : 18), child: child),
                    if (error != null) ...[const SizedBox(height: 10), _InfoBox(icon: Icons.error_outline, text: error!, color: AppColors.red)],
                    if (onSave != null) ...[
                      const SizedBox(height: 14),
                      FilledButton.icon(onPressed: saving ? null : onSave, icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined), label: Text(saving ? 'Saving...' : 'Save Changes')),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

class UserAccountSettingsPage extends StatefulWidget {
  const UserAccountSettingsPage({super.key, required this.initial});
  final Map<String, dynamic> initial;
  @override State<UserAccountSettingsPage> createState() => _UserAccountSettingsPageState();
}
class _UserAccountSettingsPageState extends _SettingsPageState<UserAccountSettingsPage> {
  late final TextEditingController name, phone;
  @override void initState() { super.initState(); final user = Supabase.instance.client.auth.currentUser; name = TextEditingController(text: widget.initial['full_name']?.toString() ?? user?.userMetadata?['full_name']?.toString() ?? ''); phone = TextEditingController(text: widget.initial['phone']?.toString() ?? widget.initial['phone_number']?.toString() ?? user?.userMetadata?['phone_number']?.toString() ?? ''); }
  @override void dispose() { name.dispose(); phone.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) { final user = Supabase.instance.client.auth.currentUser; return _DetailScaffold(title: 'User Account', subtitle: 'Your account identity is stored in Supabase Auth and the profile table.', saving: saving, error: error, onSave: () => save(() => SettingsService.instance.saveProfile(fullName: name.text, phone: phone.text)), child: Column(children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person_outline))), const SizedBox(height: 12), TextField(enabled: false, controller: TextEditingController(text: user?.email ?? ''), decoration: const InputDecoration(labelText: 'Email Address', prefixIcon: Icon(Icons.email_outlined))), const SizedBox(height: 12), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile Number', prefixIcon: Icon(Icons.phone_outlined))), const SizedBox(height: 16), OutlinedButton.icon(onPressed: user?.email == null ? null : () async { await Supabase.instance.client.auth.resetPasswordForEmail(user!.email!); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password reset email sent.'))); }, icon: const Icon(Icons.password_outlined), label: const Text('Send Password Reset Email')), const SizedBox(height: 12), OutlinedButton.icon(onPressed: () => context.push('/security'), icon: const Icon(Icons.verified_user_outlined), label: const Text('Authenticator MFA and Change Password'))])); }
}

class HomeLocationSettingsPage extends StatefulWidget {
  const HomeLocationSettingsPage({super.key, required this.initial}); final Map<String, dynamic> initial;
  @override State<HomeLocationSettingsPage> createState() => _HomeLocationSettingsPageState();
}
class _HomeLocationSettingsPageState extends _SettingsPageState<HomeLocationSettingsPage> {
  final map = MapController(); late final TextEditingController home, address, barangay, city; LatLng? pin; bool locating = false;
  @override void initState() { super.initState(); home=TextEditingController(text: widget.initial['home_name']?.toString() ?? ''); address=TextEditingController(text: widget.initial['address']?.toString() ?? ''); barangay=TextEditingController(text: widget.initial['barangay']?.toString() ?? ''); city=TextEditingController(text: widget.initial['city']?.toString() ?? ''); final lat=(widget.initial['latitude'] as num?)?.toDouble(); final lng=(widget.initial['longitude'] as num?)?.toDouble(); if(lat!=null&&lng!=null) pin=LatLng(lat,lng); }
  @override void dispose(){home.dispose();address.dispose();barangay.dispose();city.dispose();super.dispose();}
  Future<void> current() async {
    setState(() => locating = true);
    try {
      final resolved = await LocationService.pinCurrentLocation();
      final pt = LatLng(resolved.latitude, resolved.longitude);
      if (!mounted) return;
      setState(() {
        pin = pt;
        address.text = resolved.placeName;
        error = null;
      });
      map.move(pt, 17);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> selectPin(LatLng p) async {
    setState(() {
      pin = p;
      locating = true;
      error = null;
    });
    try {
      final resolved = await LocationService.resolvePlaceName(p.latitude, p.longitude);
      if (mounted) setState(() => address.text = resolved);
    } catch (_) {
      // Coordinates are still valid even if reverse geocoding is unavailable.
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  @override Widget build(BuildContext context){const fallback=LatLng(14.5995,120.9842); return _DetailScaffold(title:'Home & Location',subtitle:'The pinned coordinates identify the monitored property and can be shown with emergency information and historical records.',saving:saving,error:error,onSave:()=>save(() async {if(pin==null)throw Exception('Pin the home location first.'); await SettingsService.instance.saveHome(homeName:home.text,address:address.text,barangay:barangay.text,city:city.text,latitude:pin!.latitude,longitude:pin!.longitude);}),child:Column(children:[TextField(controller:home,decoration:const InputDecoration(labelText:'Home Name',prefixIcon:Icon(Icons.home_outlined))),const SizedBox(height:12),TextField(controller:address,maxLines:2,decoration:const InputDecoration(labelText:'Address',prefixIcon:Icon(Icons.location_on_outlined))),const SizedBox(height:12),LayoutBuilder(builder:(context,c)=>c.maxWidth<520?Column(children:[TextField(controller:barangay,decoration:const InputDecoration(labelText:'Barangay')),const SizedBox(height:12),TextField(controller:city,decoration:const InputDecoration(labelText:'City'))]):Row(children:[Expanded(child:TextField(controller:barangay,decoration:const InputDecoration(labelText:'Barangay'))),const SizedBox(width:12),Expanded(child:TextField(controller:city,decoration:const InputDecoration(labelText:'City')))])),const SizedBox(height:14),Row(children:[Expanded(child:Text('PIN MONITORED HOME',style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w900,fontSize:11))),TextButton.icon(onPressed:locating?null:current,icon:locating?const SizedBox(width:14,height:14,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.my_location,size:16),label:const Text('Use current'))]),ClipRRect(borderRadius:BorderRadius.circular(16),child:SizedBox(height:280,child:FlutterMap(mapController:map,options:MapOptions(initialCenter:pin??fallback,initialZoom:pin==null?12:16,onTap:(_,p)=>selectPin(p)),children:[TileLayer(urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',userAgentPackageName:'com.pyroguard.iot'),if(pin!=null)MarkerLayer(markers:[Marker(point:pin!,width:54,height:54,child:const Icon(Icons.location_pin,color:AppColors.red,size:48))])]))),const SizedBox(height:7),Text(pin==null?'Tap the map to place the home pin.':'${pin!.latitude.toStringAsFixed(6)}, ${pin!.longitude.toStringAsFixed(6)}',style:TextStyle(color:pin==null?AppTheme.warningForeground(context):AppTheme.safeForeground(context),fontWeight:FontWeight.w800,fontSize:10.5))]));}
}

class StakeholderSettingsPage extends StatefulWidget { const StakeholderSettingsPage({super.key,required this.initial}); final Map<String,dynamic> initial; @override State<StakeholderSettingsPage> createState()=>_StakeholderSettingsPageState(); }
class _StakeholderSettingsPageState extends _SettingsPageState<StakeholderSettingsPage>{late final TextEditingController name,relationship,phone; @override void initState(){super.initState();name=TextEditingController(text:widget.initial['full_name']?.toString()??'');relationship=TextEditingController(text:widget.initial['relationship']?.toString()??'Homeowner');phone=TextEditingController(text:widget.initial['phone']?.toString()??'');} @override void dispose(){name.dispose();relationship.dispose();phone.dispose();super.dispose();} @override Widget build(BuildContext context)=>_DetailScaffold(title:'Stakeholders',subtitle:'The primary stakeholder is the person associated with the monitored home and notifications.',saving:saving,error:error,onSave:()=>save(()=>SettingsService.instance.saveStakeholder(fullName:name.text,relationship:relationship.text,phone:phone.text)),child:Column(children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Full Name',prefixIcon:Icon(Icons.person_outline))),const SizedBox(height:12),TextField(controller:relationship,decoration:const InputDecoration(labelText:'Relationship',prefixIcon:Icon(Icons.family_restroom_outlined))),const SizedBox(height:12),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Phone Number',prefixIcon:Icon(Icons.phone_outlined)))]));}

class SafetySetupSettingsPage extends StatefulWidget { const SafetySetupSettingsPage({super.key,required this.initial}); final Map<String,dynamic> initial; @override State<SafetySetupSettingsPage> createState()=>_SafetySetupSettingsPageState(); }
class _SafetySetupSettingsPageState extends _SettingsPageState<SafetySetupSettingsPage>{late final TextEditingController entry,siren,notes; late bool ack,ai; @override void initState(){super.initState();entry=TextEditingController(text:'${widget.initial['entry_delay_seconds']??20}');siren=TextEditingController(text:'${widget.initial['siren_duration_seconds']??60}');notes=TextEditingController(text:widget.initial['notes']?.toString()??'');ack=widget.initial['safety_acknowledged'] as bool? ?? false;ai=widget.initial['ai_assist_enabled'] as bool? ?? true;} @override void dispose(){entry.dispose();siren.dispose();notes.dispose();super.dispose();} @override Widget build(BuildContext context)=>_DetailScaffold(title:'Safety Setup',subtitle:'Intrusion timing can change with security mode. Smoke/gas and flame monitoring remain active as safety functions in every mode.',saving:saving,error:error,onSave:()=>save(()=>SettingsService.instance.saveSafety(acknowledged:ack,entryDelaySeconds:int.tryParse(entry.text)??20,sirenDurationSeconds:int.tryParse(siren.text)??60,aiAssistEnabled:ai,notes:notes.text)),child:Column(children:[TextField(controller:entry,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Door Entry Delay (seconds)',prefixIcon:Icon(Icons.timer_outlined))),const SizedBox(height:12),TextField(controller:siren,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Siren Duration (seconds)',prefixIcon:Icon(Icons.volume_up_outlined))),const SizedBox(height:10),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('AI-assisted camera review'),subtitle:const Text('Use camera motion as supporting evidence only.'),value:ai,onChanged:(v)=>setState(()=>ai=v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Safety acknowledgment'),subtitle:const Text('Emergency service contact remains a human action.'),value:ack,onChanged:(v)=>setState(()=>ack=v)),const SizedBox(height:8),TextField(controller:notes,maxLines:3,decoration:const InputDecoration(labelText:'Safety Notes',prefixIcon:Icon(Icons.notes_outlined)))]));}

class BfpSettingsPage extends StatefulWidget { const BfpSettingsPage({super.key,required this.initial}); final Map<String,dynamic> initial; @override State<BfpSettingsPage> createState()=>_BfpSettingsPageState(); }
class _BfpSettingsPageState extends _SettingsPageState<BfpSettingsPage>{late final TextEditingController station,personnel,rank,phone,address; bool confirmed=true; @override void initState(){super.initState();station=TextEditingController(text:widget.initial['station_name']?.toString()??widget.initial['name']?.toString()??'');personnel=TextEditingController(text:widget.initial['personnel_name']?.toString()??'');rank=TextEditingController(text:widget.initial['rank_position']?.toString()??'');phone=TextEditingController(text:widget.initial['phone']?.toString()??'');address=TextEditingController(text:widget.initial['address']?.toString()??'');confirmed=widget.initial['is_confirmed'] as bool? ?? true;} @override void dispose(){station.dispose();personnel.dispose();rank.dispose();phone.dispose();address.dispose();super.dispose();} @override Widget build(BuildContext context)=>_DetailScaffold(title:'BFP Contact Details',subtitle:'This saved contact is shown during a confirmed fire/hazard. PyroGuard opens the phone dialer only after the user taps CALL BFP.',saving:saving,error:error,onSave:()=>save(() async {if(station.text.trim().isEmpty||phone.text.trim().isEmpty)throw Exception('Station name and phone are required.');await SettingsService.instance.saveBfp(stationName:station.text,personnelName:personnel.text,rankPosition:rank.text,phone:phone.text,address:address.text,confirmed:confirmed);await NotificationService.loadBfpContact();}),child:Column(children:[TextField(controller:station,decoration:const InputDecoration(labelText:'BFP Station Name',prefixIcon:Icon(Icons.local_fire_department_outlined))),const SizedBox(height:12),TextField(controller:personnel,decoration:const InputDecoration(labelText:'BFP Personnel / Contact Person',prefixIcon:Icon(Icons.badge_outlined))),const SizedBox(height:12),TextField(controller:rank,decoration:const InputDecoration(labelText:'Rank / Position',prefixIcon:Icon(Icons.workspace_premium_outlined))),const SizedBox(height:12),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Telephone / Mobile Number',prefixIcon:Icon(Icons.phone_outlined))),const SizedBox(height:12),TextField(controller:address,maxLines:2,decoration:const InputDecoration(labelText:'Station Address',prefixIcon:Icon(Icons.location_city_outlined))),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Contact details reviewed by user'),value:confirmed,onChanged:(v)=>setState(()=>confirmed=v)),const SizedBox(height:8),_InfoBox(icon:Icons.info_outline,text:'Do not enter an invented BFP contact. Save the station/personnel details your group has actually verified for the monitored location.',color:AppColors.amber)]));}

class NotificationsSettingsPage extends StatefulWidget { const NotificationsSettingsPage({super.key,required this.initial}); final Map<String,dynamic> initial; @override State<NotificationsSettingsPage> createState()=>_NotificationsSettingsPageState(); }
class _NotificationsSettingsPageState extends _SettingsPageState<NotificationsSettingsPage>{late bool enabled,push,email,sms; @override void initState(){super.initState();enabled=widget.initial['notifications_enabled'] as bool? ?? true;push=widget.initial['push_notifications'] as bool? ?? true;email=widget.initial['email_alerts'] as bool? ?? false;sms=widget.initial['sms_alerts'] as bool? ?? false;} @override Widget build(BuildContext context)=>_DetailScaffold(title:'Notifications',subtitle:'These preferences are stored in Supabase and mirrored to MySQL. They control homeowner alerts; BFP calling remains a manual CALL BFP action.',saving:saving,error:error,onSave:()=>save(()=>SettingsService.instance.savePreferences(notificationsEnabled:enabled,pushNotifications:push,emailAlerts:email,smsAlerts:sms)),child:Column(children:[SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Notifications Enabled'),value:enabled,onChanged:(v)=>setState(()=>enabled=v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Push Notifications'),value:push,onChanged:(v)=>setState(()=>push=v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Email Alerts'),value:email,onChanged:(v)=>setState(()=>email=v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('SMS to Homeowner'),subtitle:const Text('Opens/configures user-directed alerts only; it does not auto-contact BFP.'),value:sms,onChanged:(v)=>setState(()=>sms=v)),const SizedBox(height:8),OutlinedButton.icon(onPressed:NotificationService.requestPermission,icon:const Icon(Icons.notification_add_outlined),label:const Text('Request Device Notification Permission'))]));}

class DeviceSecuritySettingsPage extends StatefulWidget { const DeviceSecuritySettingsPage({super.key,required this.initial}); final Map<String,dynamic> initial; @override State<DeviceSecuritySettingsPage> createState()=>_DeviceSecuritySettingsPageState(); }
class _DeviceSecuritySettingsPageState extends _SettingsPageState<DeviceSecuritySettingsPage>{late final TextEditingController device; final security=SecurityControlService.instance; @override void initState(){super.initState();device=TextEditingController(text:widget.initial['device_id']?.toString()??Supabase.instance.client.auth.currentUser?.userMetadata?['device_id']?.toString()??'ESP32-001');security.addListener(_changed);security.startListening();} void _changed(){if(mounted)setState((){});} @override void dispose(){device.dispose();security.removeListener(_changed);super.dispose();} Future<void> mode(SecurityMode m)async{final ok=await security.setMode(m);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'Security command saved. It will be applied when the controller is connected.':'Could not save security command.'),backgroundColor:ok?const Color(0xFF166534):AppColors.redDeep));} @override Widget build(BuildContext context)=>_DetailScaffold(title:'Devices & Security Controls',subtitle:'Security commands are saved in Supabase and mirrored to MySQL even while hardware is offline. The ESP32 applies pending commands when it reconnects.',saving:saving,error:error,onSave:()=>save(()=>SettingsService.instance.saveDevice(deviceId:device.text)),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[TextField(controller:device,decoration:const InputDecoration(labelText:'Main ESP32 Device ID',prefixIcon:Icon(Icons.developer_board_outlined))),const SizedBox(height:18),Text('SECURITY MODE',style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w900,fontSize:11)),const SizedBox(height:8),Wrap(spacing:8,runSpacing:8,children:[_ModeButton(label:'DISARM',selected:security.mode==SecurityMode.disarmed,color:AppColors.amber,onTap:()=>mode(SecurityMode.disarmed)),_ModeButton(label:'ARM HOME',selected:security.mode==SecurityMode.armHome,color:AppColors.orange,onTap:()=>mode(SecurityMode.armHome)),_ModeButton(label:'ARM AWAY',selected:security.mode==SecurityMode.armAway,color:AppColors.red,onTap:()=>mode(SecurityMode.armAway))]),const SizedBox(height:12),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Door Protection'),subtitle:const Text('Door opening participates in intrusion logic while armed.'),value:security.doorEnabled,onChanged:security.saving?null:(v)=>security.setDoorEnabled(v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Window Protection'),subtitle:const Text('Window opening can trigger perimeter intrusion logic while armed.'),value:security.windowEnabled,onChanged:security.saving?null:(v)=>security.setWindowEnabled(v)),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Interior Motion Protection'),subtitle:const Text('ARM HOME can keep the perimeter protected while treating interior motion differently.'),value:security.motionEnabled,onChanged:security.saving?null:(v)=>security.setMotionEnabled(v)),const SizedBox(height:8),_InfoBox(icon:Icons.local_fire_department_outlined,text:'Smoke/gas and flame monitoring are safety functions and remain active even when intrusion protection is DISARMED.',color:AppColors.red)]));}

class _ModeButton extends StatelessWidget{const _ModeButton({required this.label,required this.selected,required this.color,required this.onTap});final String label;final bool selected;final Color color;final VoidCallback onTap;@override Widget build(BuildContext context)=>OutlinedButton(onPressed:onTap,style:OutlinedButton.styleFrom(backgroundColor:selected?color.withValues(alpha:.14):null,side:BorderSide(color:selected?color:AppTheme.border(context))),child:Text(label,style:TextStyle(color:selected?AppTheme.statusForeground(context,color):AppTheme.textPrimary(context),fontWeight:FontWeight.w900,fontSize:11)));}

class SettingsReviewPage extends StatefulWidget { const SettingsReviewPage({super.key}); @override State<SettingsReviewPage> createState()=>_SettingsReviewPageState(); }
class _SettingsReviewPageState extends State<SettingsReviewPage>{Map<String,dynamic>? data;String? error;@override void initState(){super.initState();_load();}Future<void>_load()async{try{final d=await SettingsService.instance.loadAll();if(mounted)setState(()=>data=d);}catch(e){if(mounted)setState(()=>error='$e');}} @override Widget build(BuildContext context){final d=data;return _DetailScaffold(title:'Review Saved Information',subtitle:'This page shows the currently stored setup records. Realtime sensor values are intentionally not treated as account/setup data.',error:error,actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))],child:d==null?const Center(child:CircularProgressIndicator()):Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[for(final key in ['profile','home','stakeholder','bfp','safety','preferences','device'])...[_ReviewMap(title:key.toUpperCase().replaceAll('_',' '),data:Map<String,dynamic>.from((d[key] as Map?)??const{})),const SizedBox(height:10)] ]));}}
class _ReviewMap extends StatelessWidget{const _ReviewMap({required this.title,required this.data});final String title;final Map<String,dynamic> data;@override Widget build(BuildContext context)=>Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:AppTheme.card(context).withValues(alpha:.55),borderRadius:BorderRadius.circular(12),border:Border.all(color:AppTheme.border(context))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text(title,style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w900,fontSize:11)),const SizedBox(height:6),if(data.isEmpty)Text('No saved record yet.',style:TextStyle(color:AppTheme.textSecondary(context),fontSize:10.5)) else ...data.entries.where((e)=>!['id','user_id','created_at','updated_at'].contains(e.key)).map((e)=>Padding(padding:const EdgeInsets.symmetric(vertical:2),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(width:150,child:Text(e.key.replaceAll('_',' '),style:TextStyle(color:AppTheme.textSecondary(context),fontSize:10))),Expanded(child:Text('${e.value??'—'}',style:TextStyle(color:AppTheme.textPrimary(context),fontSize:10,fontWeight:FontWeight.w700)))]))) ]));}

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeNotifier>();
    return _DetailScaffold(
      title: 'Appearance',
      subtitle: 'Both themes keep the Phoenix background visible behind translucent glass panels. Light mode uses stronger panel opacity and dark text for readability.',
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dark Mode'),
            subtitle: Text(theme.isDark ? 'Dark glass security control center' : 'High-contrast light glass mode'),
            value: theme.isDark,
            onChanged: (value) async {
              theme.setDark(value);
              try {
                await SettingsService.instance.saveAppearance(darkMode: value);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(value ? 'Dark Mode enabled and saved.' : 'Light Mode enabled and saved.'),
                    backgroundColor: const Color(0xFF166534),
                  ));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Theme changed locally, but database sync is pending: $e'),
                    backgroundColor: const Color(0xFF92400E),
                  ));
                }
              }
            },
          ),
          const SizedBox(height: 10),
          GlassPanel(
            padding: const EdgeInsets.all(16),
            borderColor: AppColors.orange.withValues(alpha: .22),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.layers_outlined, color: AppTheme.brandForeground(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The same fixed Phoenix background and glassmorphism system is used throughout the application. Only the theme contrast changes between Light and Dark Mode.',
                    style: TextStyle(
                      color: AppTheme.textPrimary(context),
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutPyroGuardPage extends StatelessWidget { const AboutPyroGuardPage({super.key}); @override Widget build(BuildContext context)=>_DetailScaffold(title:'About PyroGuard',subtitle:'A real-time multi-sensor ESP32 home security and monitoring prototype.',child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[_InfoBox(icon:Icons.cloud_outlined,text:'Supabase: authentication, realtime state, settings, commands, evidence, and a complete mirrored history.',color:AppColors.green),const SizedBox(height:10),_InfoBox(icon:Icons.storage_outlined,text:'MySQL: stores the same persistent PyroGuard application data as Supabase through the secure mysql-history Edge Function, including current-state/configuration mirrors, commands, history, events and audits.',color:AppColors.orange),const SizedBox(height:10),_InfoBox(icon:Icons.sensors_outlined,text:'Until the ESP32/camera begins posting telemetry, the app stays online but hardware cards show NOT CONNECTED / WAITING FOR HARDWARE instead of invented sensor values.',color:AppColors.amber),const SizedBox(height:10),_InfoBox(icon:Icons.local_fire_department_outlined,text:'During a confirmed hazard, PyroGuard shows the saved BFP station/personnel information and a CALL BFP action. The actual telephone call remains a human action.',color:AppColors.red)])); }
