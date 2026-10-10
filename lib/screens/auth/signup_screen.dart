import '../../services/registration_service.dart';
import '../../services/password_policy.dart';
// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../responsive.dart';
import '../../services/account_bootstrap_service.dart';
import '../../services/location_service.dart';
import '../../services/admin_identity.dart';
import '../../theme.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _pageCtrl = PageController();
  final _mapCtrl = MapController();
  int _currentStep = 0;
  bool _loading = false;
  bool _locating = false;
  bool _safetyAcknowledged = false;
  String? _error;
  LatLng? _homePin;

  final _emailCt = TextEditingController();
  final _passCt = TextEditingController();
  final _confCt = TextEditingController();
  final _nameCt = TextEditingController();
  final _phoneCt = TextEditingController();
  final _homeNameCt = TextEditingController();
  final _addressCt = TextEditingController();
  final _deviceIdCt = TextEditingController(text: 'ESP32-001');
  final _stakeholderCt = TextEditingController();
  final _relationshipCt = TextEditingController(text: 'Homeowner');
  final _stakeholderPhoneCt = TextEditingController();
  final _bfpStationCt = TextEditingController();
  final _bfpPersonnelCt = TextEditingController();
  final _bfpRankCt = TextEditingController();
  final _bfpPhoneCt = TextEditingController();
  final _bfpAddressCt = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConf = true;

  static const _steps = [
    ('Account', Icons.lock_person_outlined),
    ('Home', Icons.home_work_outlined),
    ('Safety', Icons.health_and_safety_outlined),
    ('Review', Icons.fact_check_outlined),
  ];

  @override
  void dispose() {
    _pageCtrl.dispose();
    for (final c in [
      _emailCt, _passCt, _confCt, _nameCt, _phoneCt, _homeNameCt, _addressCt,
      _deviceIdCt, _stakeholderCt, _relationshipCt, _stakeholderPhoneCt,
      _bfpStationCt, _bfpPersonnelCt, _bfpRankCt, _bfpPhoneCt, _bfpAddressCt,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validationMessage(int step) {
    if (step == 0) {
      if (!_emailCt.text.trim().contains('@')) return 'Enter a valid email address.';
      final passwordError = PasswordPolicy.validate(_passCt.text);
      if (passwordError != null) return passwordError;
      if (_passCt.text != _confCt.text) return 'Passwords do not match.';
    }
    if (step == 1) {
      if (_nameCt.text.trim().isEmpty) return 'Enter the homeowner name.';
      if (_phoneCt.text.trim().length < 7) return 'Enter a valid mobile number.';
      if (_homeNameCt.text.trim().isEmpty) return 'Enter a home name.';
      if (_addressCt.text.trim().isEmpty) return 'Enter the home address.';
      if (_homePin == null) return 'Pin the monitored home location on the map.';
      if (_deviceIdCt.text.trim().isEmpty) return 'Enter the PyroGuard device ID.';
    }
    if (step == 2) {
      if (_stakeholderCt.text.trim().isEmpty) return 'Enter the primary stakeholder.';
      if (_stakeholderPhoneCt.text.trim().length < 7) return 'Enter the stakeholder phone number.';
      if (_bfpStationCt.text.trim().isEmpty) return 'Enter the BFP station name.';
      if (_bfpPhoneCt.text.trim().length < 7) return 'Enter the BFP contact number.';
      if (_bfpAddressCt.text.trim().isEmpty) return 'Enter the BFP station address.';
      if (!_safetyAcknowledged) return 'Confirm the safety acknowledgment to continue.';
    }
    return null;
  }

  bool _validStep(int step) => _validationMessage(step) == null;

  void _next() {
    final error = _validationMessage(_currentStep);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _error = null);
    if (_currentStep < 3) {
      if (_currentStep == 0 && _stakeholderCt.text.trim().isEmpty) {
        _stakeholderCt.text = _nameCt.text.trim();
        _stakeholderPhoneCt.text = _phoneCt.text.trim();
      }
      _pageCtrl.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    }
  }

  void _previous() {
    if (_currentStep == 0) {
      context.go('/login');
      return;
    }
    setState(() => _error = null);
    _pageCtrl.previousPage(duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final resolved = await LocationService.pinCurrentLocation();
      final point = LatLng(resolved.latitude, resolved.longitude);
      if (!mounted) return;
      setState(() {
        _homePin = point;
        _addressCt.text = resolved.placeName;
        _error = null;
      });
      _mapCtrl.move(point, 17);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _fillAddress(LatLng point) async {
    try {
      final address = await LocationService.resolvePlaceName(
        point.latitude,
        point.longitude,
      );
      if (mounted) setState(() => _addressCt.text = address);
    } catch (_) {
      // Pin remains valid even when reverse geocoding is temporarily unavailable.
    }
  }

  Future<void> _completeSignup() async {
    final normalizedEmail = _emailCt.text.trim().toLowerCase();
    if (AdminIdentity.isFixedAdminEmail(normalizedEmail)) {
      setState(() {
        _error = 'This email belongs to a fixed PyroGuard administrator. Administrator accounts cannot be created or used as homeowner accounts.';
      });
      _pageCtrl.animateToPage(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      return;
    }
    for (var i = 0; i < 3; i++) {
      final error = _validationMessage(i);
      if (error != null) {
        setState(() => _error = error);
        _pageCtrl.animateToPage(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        return;
      }
    }

    setState(() { _loading = true; _error = null; });
    try {
      final metadata = <String, dynamic>{
        'full_name': _nameCt.text.trim(),
        'phone_number': _phoneCt.text.trim(),
        'home_name': _homeNameCt.text.trim(),
        'address': _addressCt.text.trim(),
        'home_latitude': _homePin!.latitude,
        'home_longitude': _homePin!.longitude,
        'device_id': _deviceIdCt.text.trim(),
        'stakeholder_name': _stakeholderCt.text.trim(),
        'stakeholder_relationship': _relationshipCt.text.trim(),
        'stakeholder_phone': _stakeholderPhoneCt.text.trim(),
        'bfp_station_name': _bfpStationCt.text.trim(),
        'bfp_personnel_name': _bfpPersonnelCt.text.trim(),
        'bfp_rank_position': _bfpRankCt.text.trim(),
        'bfp_phone': _bfpPhoneCt.text.trim(),
        'bfp_address': _bfpAddressCt.text.trim(),
        'safety_acknowledged': true,
        'onboarding_completed': false,
        'role': 'homeowner',
      };

      final result = await RegistrationService.register(
        email: _emailCt.text.trim(),
        password: _passCt.text,
        metadata: metadata,
      );
      final hasSession = Supabase.instance.client.auth.currentSession != null;

      if (hasSession) {
        // A valid session means we can immediately persist the complete
        // registration through the unified dual-database layer. If email
        // confirmation is enabled and session is null, the same bootstrap runs
        // automatically after the user's first verified login.
        await AccountBootstrapService.instance
            .ensureRegistrationPersisted(force: true);
      }

      if (!mounted) return;
      if (hasSession) {
        if (result['dual_saved'] != true) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Your account was created. The MySQL copy is pending synchronization. Keep your configured sync worker running.')));
        context.go('/tutorial');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['dual_saved'] == true
            ? 'Account details saved to both databases. Verify your email, then sign in.'
            : 'Click Confirm Account in your email to complete registration. Your application profile and MySQL copy will be saved after confirmation.'),
          backgroundColor: const Color(0xFF166534),
        ));
        context.go('/login');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = _formatError(e.message));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not finish setup: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatError(String message) {
    final m = message.toLowerCase();
    if (m.contains('already registered')) return 'This email is already registered. Try signing in instead.';
    if (m.contains('password')) return 'Password must have 12+ characters, uppercase, lowercase, number and symbol, without spaces.';
    if (m.contains('invalid') && m.contains('email')) return 'Enter a valid email address.';
    if (m.contains('rate')) return 'Too many requests. Please try again later.';
    return message;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: PhoenixBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8, Responsive.horizontalPadding(context), 6),
                    child: Row(children: [
                      IconButton(onPressed: _loading ? null : _previous, icon: const Icon(Icons.arrow_back_ios_new, size: 18)),
                      const Spacer(),
                      const PyroGuardLogo(),
                      const SizedBox(width: 9),
                      Text('PYROGUARD', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, letterSpacing: 1)),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ]),
                  ),
                  _ProgressHeader(current: _currentStep),
                  const SizedBox(height: 6),
                  Expanded(
                    child: PageView(
                      controller: _pageCtrl,
                      physics: const NeverScrollableScrollPhysics(),
                      onPageChanged: (i) => setState(() { _currentStep = i; _error = null; }),
                      children: [
                        _stepAccount(),
                        _stepHome(),
                        _stepSafety(),
                        _stepReview(),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8, Responsive.horizontalPadding(context), 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (_error != null) ...[_ErrorBox(_error!), const SizedBox(height: 8)],
                      FilledButton(
                        onPressed: _loading || (_currentStep < 3 && !_validStep(_currentStep))
                            ? null
                            : (_currentStep == 3 ? _completeSignup : _next),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: _loading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : Text(_currentStep == 3 ? 'Create Account & Finish Setup' : 'Continue'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextButton(onPressed: _loading ? null : () => context.go('/login'), child: const Text('Already have an account? Sign in')),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _shell(String eyebrow, String title, String subtitle, List<Widget> children) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8, Responsive.horizontalPadding(context), 18),
        child: GlassPanel(
          radius: 24,
          padding: EdgeInsets.all(Responsive.isCompact(context) ? 15 : 22),
          borderColor: AppColors.orange.withValues(alpha: .26),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(eyebrow, style: TextStyle(color: AppTheme.brandForeground(context), fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .8)),
            const SizedBox(height: 7),
            Text(title, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: Responsive.isCompact(context) ? 21 : 25, fontWeight: FontWeight.w900)),
            const SizedBox(height: 5),
            Text(subtitle, style: TextStyle(color: AppTheme.textSecondary(context), height: 1.45, fontSize: 12.5)),
            const SizedBox(height: 18),
            ...children,
          ]),
        ),
      );

  Widget _stepAccount() => _shell('STEP 1 OF 4 · ACCOUNT', 'Create your login', 'Create the homeowner account used to access PyroGuard.', [
        _Field(controller: _emailCt, label: 'Email Address', icon: Icons.email_outlined, keyboardType: TextInputType.emailAddress, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _passCt, label: 'Password', icon: Icons.lock_outline, obscure: _obscurePass, onChanged: (_) => setState(() {}), trailing: IconButton(onPressed: () => setState(() => _obscurePass = !_obscurePass), icon: Icon(_obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined))),
        const SizedBox(height: 12),
        _Field(controller: _confCt, label: 'Confirm Password', icon: Icons.lock_reset_outlined, obscure: _obscureConf, onChanged: (_) => setState(() {}), trailing: IconButton(onPressed: () => setState(() => _obscureConf = !_obscureConf), icon: Icon(_obscureConf ? Icons.visibility_outlined : Icons.visibility_off_outlined))),
        const SizedBox(height: 8),
        Text('After 3 wrong passwords: 1-minute lock. After 10 cumulative wrong passwords: 15-minute lock.', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11)),
      ]);

  Widget _stepHome() => _shell('STEP 2 OF 4 · HOME & LOCATION', 'Register the monitored home', 'Enter the homeowner and property details, then pin the exact monitored location.', [
        _Field(controller: _nameCt, label: 'Homeowner Full Name', icon: Icons.person_outline, textCapitalization: TextCapitalization.words, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _phoneCt, label: 'Mobile Number', icon: Icons.phone_outlined, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _homeNameCt, label: 'Home Name', icon: Icons.home_work_outlined, hint: 'e.g. Main Home', onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _addressCt, label: 'Address', icon: Icons.location_on_outlined, maxLines: 2, textCapitalization: TextCapitalization.words, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _LocationPicker(mapController: _mapCtrl, selected: _homePin, locating: _locating, onUseCurrent: _useCurrentLocation, onSelected: (p) { setState(() { _homePin = p; _error = null; }); _fillAddress(p); }),
        const SizedBox(height: 12),
        _Field(controller: _deviceIdCt, label: 'PyroGuard Device ID', icon: Icons.developer_board_outlined, onChanged: (_) => setState(() {})),
      ]);

  Widget _stepSafety() => _shell('STEP 3 OF 4 · SAFETY', 'Stakeholder & BFP contact', 'Save the person to notify and the local BFP information that will be shown during an emergency.', [
        _Field(controller: _stakeholderCt, label: 'Primary Stakeholder', icon: Icons.people_outline, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _relationshipCt, label: 'Relationship', icon: Icons.family_restroom_outlined, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _stakeholderPhoneCt, label: 'Stakeholder Phone', icon: Icons.phone_in_talk_outlined, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {})),
        const SizedBox(height: 18),
        Text('BFP CONTACT DETAILS', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 12)),
        const SizedBox(height: 10),
        _Field(controller: _bfpStationCt, label: 'BFP Station Name', icon: Icons.local_fire_department_outlined, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _bfpPersonnelCt, label: 'BFP Personnel / Contact Person (optional)', icon: Icons.badge_outlined, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _bfpRankCt, label: 'Rank / Position (optional)', icon: Icons.workspace_premium_outlined, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _bfpPhoneCt, label: 'BFP Phone Number', icon: Icons.phone_callback_outlined, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        _Field(controller: _bfpAddressCt, label: 'BFP Station Address', icon: Icons.map_outlined, maxLines: 2, onChanged: (_) => setState(() {})),
        const SizedBox(height: 14),
        CheckboxListTile(
          value: _safetyAcknowledged,
          onChanged: (v) => setState(() => _safetyAcknowledged = v ?? false),
          contentPadding: EdgeInsets.zero,
          activeColor: AppColors.orange,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('I understand PyroGuard is a monitoring prototype and emergency calls remain a human action.', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700, fontSize: 12)),
          subtitle: Text('During a confirmed hazard the app will show the saved BFP contact and a CALL BFP button. It will not claim to dispatch responders automatically.', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, height: 1.4)),
        ),
      ]);

  Widget _stepReview() => _shell('STEP 4 OF 4 · REVIEW', 'Review before account creation', 'Confirm the information below. You can edit all of these later in Settings.', [
        _ReviewSection(title: 'Account', rows: {'Email': _emailCt.text.trim(), 'Homeowner': _nameCt.text.trim(), 'Mobile': _phoneCt.text.trim()}),
        const SizedBox(height: 10),
        _ReviewSection(title: 'Home & Location', rows: {'Home': _homeNameCt.text.trim(), 'Address': _addressCt.text.trim(), 'Pinned coordinates': _homePin == null ? 'Not pinned' : '${_homePin!.latitude.toStringAsFixed(6)}, ${_homePin!.longitude.toStringAsFixed(6)}', 'Device': _deviceIdCt.text.trim()}),
        const SizedBox(height: 10),
        _ReviewSection(title: 'Primary Stakeholder', rows: {'Name': _stakeholderCt.text.trim(), 'Relationship': _relationshipCt.text.trim(), 'Phone': _stakeholderPhoneCt.text.trim()}),
        const SizedBox(height: 10),
        _ReviewSection(title: 'BFP Contact', rows: {'Station': _bfpStationCt.text.trim(), 'Personnel': _bfpPersonnelCt.text.trim().isEmpty ? 'Not provided' : _bfpPersonnelCt.text.trim(), 'Phone': _bfpPhoneCt.text.trim(), 'Address': _bfpAddressCt.text.trim()}),
        const SizedBox(height: 12),
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppColors.green.withValues(alpha: .10), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.green.withValues(alpha: .30))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.check_circle_outline, color: AppTheme.safeForeground(context)), const SizedBox(width: 9), Expanded(child: Text('Initial security mode will be DISARMED. Door and window protection are enabled and ready to receive commands once the hardware connects. Smoke/gas and flame monitoring remain safety functions in every arm mode.', style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 11.5, height: 1.45)))])),
      ]);
}

class _LocationPicker extends StatelessWidget {
  const _LocationPicker({required this.mapController, required this.selected, required this.locating, required this.onUseCurrent, required this.onSelected});
  final MapController mapController;
  final LatLng? selected;
  final bool locating;
  final VoidCallback onUseCurrent;
  final ValueChanged<LatLng> onSelected;

  @override
  Widget build(BuildContext context) {
    const fallback = LatLng(14.5995, 120.9842);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('PIN HOME LOCATION', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 11))),
        TextButton.icon(onPressed: locating ? null : onUseCurrent, icon: locating ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location, size: 16), label: const Text('Use current')),
      ]),
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: Responsive.isCompact(context) ? 220 : 270,
          child: FlutterMap(
            mapController: mapController,
            options: MapOptions(initialCenter: selected ?? fallback, initialZoom: selected == null ? 12 : 16, onTap: (_, point) => onSelected(point)),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.pyroguard.iot'),
              if (selected != null)
                MarkerLayer(markers: [Marker(point: selected!, width: 54, height: 54, child: const Icon(Icons.location_pin, color: AppColors.red, size: 48))]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(selected == null ? 'Tap the map to place the monitored-home pin.' : 'Pinned: ${selected!.latitude.toStringAsFixed(6)}, ${selected!.longitude.toStringAsFixed(6)}', style: TextStyle(color: selected == null ? AppColors.amber : AppColors.green, fontSize: 10.5, fontWeight: FontWeight.w700)),
    ]);
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.current});
  final int current;
  @override
  Widget build(BuildContext context) {
    final compact = Responsive.isCompact(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 24),
      child: Row(children: List.generate(_SignupScreenState._steps.length, (i) {
        final step = _SignupScreenState._steps[i];
        final active = i <= current;
        return Expanded(child: Row(children: [
          Expanded(child: Column(children: [
            AnimatedContainer(duration: const Duration(milliseconds: 220), width: compact ? 28 : 34, height: compact ? 28 : 34, decoration: BoxDecoration(shape: BoxShape.circle, gradient: active ? GlassStyle.brandGradient : null, color: active ? null : AppTheme.card(context), border: Border.all(color: active ? AppColors.orange : AppTheme.border(context))), child: Icon(step.$2, size: compact ? 13 : 16, color: active ? Colors.white : AppTheme.textSecondary(context))),
            const SizedBox(height: 4),
            Text(step.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 8 : 9, fontWeight: active ? FontWeight.w800 : FontWeight.w500, color: active ? AppColors.orange : AppTheme.textSecondary(context))),
          ])),
          if (i < _SignupScreenState._steps.length - 1) Container(width: compact ? 5 : 16, height: 1.5, margin: EdgeInsets.only(bottom: compact ? 18 : 20), color: i < current ? AppColors.orange : AppTheme.border(context)),
        ]));
      })),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.label, required this.icon, this.hint, this.keyboardType, this.obscure = false, this.trailing, this.maxLines = 1, this.textCapitalization = TextCapitalization.words, this.onChanged});
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? trailing;
  final int maxLines;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        textCapitalization: textCapitalization,
        onChanged: onChanged,
        style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 14),
        decoration: InputDecoration(labelText: label, hintText: hint, prefixIcon: Icon(icon), suffixIcon: trailing),
      );
}

class _ReviewSection extends StatelessWidget {
  const _ReviewSection({required this.title, required this.rows});
  final String title;
  final Map<String, String> rows;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: AppTheme.card(context).withValues(alpha: .66), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border(context))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 12)),
          const SizedBox(height: 7),
          ...rows.entries.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 112, child: Text(e.key, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5))), Expanded(child: Text(e.value.isEmpty ? '—' : e.value, style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700, fontSize: 10.5)))]))),
        ]),
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: AppColors.red.withValues(alpha: .10), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.red.withValues(alpha: .25))), child: Row(children: [const Icon(Icons.error_outline, color: AppColors.red, size: 18), const SizedBox(width: 8), Expanded(child: Text(message, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 11.5)))]));
}
