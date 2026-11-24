import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../responsive.dart';
import '../../services/camera_service.dart';
import '../../theme.dart';
import '../../widgets/pg_ui.dart';
import '../dashboard/shared_app_bar.dart';
import 'recordings_tab.dart';

/// Evidence & Gallery: real fire / smoke alerts from ESP32-001 and ESP32-002,
/// Camera 1 pictures and saved recordings. Same glass look as the other pages.
class EvidenceGalleryTab extends StatefulWidget {
  const EvidenceGalleryTab({super.key});

  @override
  State<EvidenceGalleryTab> createState() => _EvidenceGalleryTabState();
}

class _EvidenceGalleryTabState extends State<EvidenceGalleryTab> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);
  final cameraService = CameraService.instance;
  late Future<List<AlertLog>> _incidents = cameraService.getEvidencePhotos();
  late Future<List<CameraEvent>> _photos = cameraService.getCapturedPhotos();
  int _reloadKey = 0;

  static final _dateTime = DateFormat('MMM d, yyyy · h:mm:ss a');
  static final _time = DateFormat('MMM d · h:mm a');

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
        _incidents = cameraService.getEvidencePhotos();
        _photos = cameraService.getCapturedPhotos();
        _reloadKey++;
      });

  @override
  Widget build(BuildContext context) {
    final pad = Responsive.horizontalPadding(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PyroAppBar(
        title: 'Evidence & Gallery',
        subtitle: 'Fire alerts, Camera 1 pictures and recordings',
        extraActions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textPrimary(context)),
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 12, pad, 4),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _GlassTabs(controller: _tabController),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildIncidentsTab(),
              _buildPhotosTab(),
              RecordingsTab(key: ValueKey(_reloadKey)),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Fire alerts ───────────────────────────────────────────

  Widget _buildIncidentsTab() {
    return FutureBuilder<List<AlertLog>>(
      future: _incidents,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.red));
        }
        final incidents = snapshot.data ?? const <AlertLog>[];
        if (incidents.isEmpty) {
          return _empty(Icons.verified_user_outlined, AppColors.green, 'No fire or smoke alerts recorded',
              'Alerts from ESP32-001 and ESP32-002 appear here with their sensor readings.');
        }
        final pad = Responsive.horizontalPadding(context);
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(pad, 10, pad, 96),
          itemCount: incidents.length + 1,
          itemBuilder: (context, index) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: index == 0 ? _summary(incidents) : _incidentCard(incidents[index - 1]),
            ),
          ),
        );
      },
    );
  }

  Widget _summary(List<AlertLog> list) {
    final critical = list.where((a) => a.isCritical).length;
    final last = list.first.createdAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PgCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          const Icon(Icons.local_fire_department_outlined, color: AppColors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${list.length} sensor alert${list.length == 1 ? '' : 's'} · last ${_time.format(last)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
          PgBadge(critical == 0 ? 'NO FIRE CONFIRMED' : '$critical CRITICAL',
              color: critical == 0 ? AppColors.green : AppColors.red),
        ]),
      ),
    );
  }

  Color _accent(AlertLog a) => a.isCritical ? AppColors.red : AppColors.amber;

  IconData _icon(AlertLog a) => a.isCritical
      ? Icons.local_fire_department_outlined
      : (a.title.startsWith('Smoke') ? Icons.cloud_outlined : Icons.warning_amber_rounded);

  String _num(double? v, String unit, {int digits = 1}) => v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';

  List<(IconData, String, String)> _metrics(AlertLog a) => [
        (Icons.thermostat_outlined, 'Temperature', _num(a.temperatureC, ' °C')),
        (Icons.air_outlined, 'Smoke', a.smokePercent != null ? _num(a.smokePercent, '%') : (a.smokeRaw != null ? 'MQ-2 ${a.smokeRaw}' : '—')),
        (Icons.water_drop_outlined, 'Humidity', _num(a.humidity, '%')),
        (Icons.local_fire_department_outlined, 'Flame', a.flameStatus),
      ];

  Widget _metricTile((IconData, String, String) m, {Color? highlight}) {
    final (icon, label, value) = m;
    return PgTile(
      color: highlight,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(children: [
        Icon(icon, size: 17, color: AppTheme.brandForeground(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, fontWeight: FontWeight.w700)),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 13.5, fontWeight: FontWeight.w900)),
          ]),
        ),
      ]),
    );
  }

  Widget _metricGrid(AlertLog a, double width) {
    final cols = width < 420 ? 2 : 4;
    final metrics = _metrics(a);
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: cols == 2 ? 2.7 : 2.6,
      children: [
        for (final m in metrics)
          _metricTile(m, highlight: m.$2 == 'Flame' && a.flameDetected == true ? AppColors.red : null),
      ],
    );
  }

  Widget _incidentCard(AlertLog a) {
    final accent = _accent(a);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showIncidentDetail(a),
        child: PgCard(
          accent: accent,
          child: LayoutBuilder(builder: (context, c) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: accent.withValues(alpha: .35)),
                  ),
                  child: Icon(_icon(a), color: AppTheme.statusForeground(context, accent), size: 20),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 15, fontWeight: FontWeight.w900)),
                    Text('${a.location} · ${_dateTime.format(a.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(width: 8),
                PgBadge(a.severityLabel.toUpperCase(), color: accent),
              ]),
              if (a.message.isNotEmpty && a.message.toLowerCase() != a.title.toLowerCase()) ...[
                const SizedBox(height: 8),
                Text(a.message, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12.5, height: 1.35)),
              ],
              const SizedBox(height: 10),
              _metricGrid(a, c.maxWidth),
              if (a.photoUrl != null && a.photoUrl!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                _photoBox(a.photoUrl!, height: 190, onTap: () => _showPhotoDetail(a.photoUrl!, a.title, _dateTime.format(a.createdAt))),
              ],
            ]);
          }),
        ),
      ),
    );
  }

  void _showIncidentDetail(AlertLog a) {
    final accent = _accent(a);
    PgGlassDialog.show(
      context,
      PgGlassDialog(
        title: a.title,
        subtitle: '${a.deviceId} · ${_dateTime.format(a.createdAt)}',
        icon: _icon(a),
        accent: accent,
        child: Builder(builder: (ctx) {
          final secondary = AppTheme.textSecondary(ctx);
          final primary = AppTheme.textPrimary(ctx);
          Widget row(String label, String value) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 118,
                    child: Text(label, style: TextStyle(color: secondary, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  Expanded(child: Text(value, style: TextStyle(color: primary, fontSize: 13, fontWeight: FontWeight.w700))),
                ]),
              );
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: LayoutBuilder(builder: (context, c) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _metricGrid(a, c.maxWidth),
                const SizedBox(height: 12),
                PgTile(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(children: [
                    row('Alert', a.alertType),
                    row('Severity', a.severityLabel),
                    row('Location', a.location),
                    row('Controller', a.deviceId),
                    if (a.smokeRaw != null) row('MQ-2 raw', '${a.smokeRaw}'),
                    if (a.message.isNotEmpty) row('Message', a.message),
                    row('Recorded', _dateTime.format(a.createdAt)),
                  ]),
                ),
                if (a.photoUrl != null && a.photoUrl!.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Evidence photo', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
                  const SizedBox(height: 8),
                  _photoBox(a.photoUrl!, height: 300, fit: BoxFit.contain),
                ],
              ]);
            }),
          );
        }),
      ),
    );
  }

  // ── Photos ────────────────────────────────────────────────

  Widget _buildPhotosTab() {
    return FutureBuilder<List<CameraEvent>>(
      future: _photos,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.orange));
        }
        final photos = snapshot.data ?? const <CameraEvent>[];
        if (photos.isEmpty) {
          return _empty(Icons.photo_library_outlined, AppColors.orange, 'No pictures captured yet',
              'Pictures taken from Camera 1 (manual, motion or fire) appear here.');
        }
        final pad = Responsive.horizontalPadding(context);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: LayoutBuilder(builder: (context, constraints) {
              final w = constraints.maxWidth;
              final columns = w < 340 ? 1 : w < 650 ? 2 : w < 950 ? 3 : 4;
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(pad, 10, pad, 96),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: .95,
                ),
                itemCount: photos.length,
                itemBuilder: (context, i) => _photoTile(photos[i]),
              );
            }),
          ),
        );
      },
    );
  }

  String _photoKind(CameraEvent p) {
    final t = p.eventType.toLowerCase();
    if (t.contains('fire') || t.contains('smoke')) return 'Fire evidence';
    if (t.contains('motion')) return 'Motion';
    if (t.contains('manual')) return 'Manual capture';
    return t.isEmpty ? 'Capture' : t.replaceAll('_', ' ');
  }

  String _ptz(CameraEvent p) => (p.panAtCapture == null && p.tiltAtCapture == null)
      ? 'Camera 1'
      : 'Pan ${p.panAtCapture ?? '—'}° · Tilt ${p.tiltAtCapture ?? '—'}°';

  Widget _photoTile(CameraEvent p) {
    final url = p.snapshotUrl!;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showPhotoDetail(url, _photoKind(p), '${_ptz(p)} · ${_dateTime.format(p.createdAt)}'),
      child: PgCard(
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _photoBox(url)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(_photoKind(p),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800, fontSize: 12.5)),
            ),
            Text(_time.format(p.createdAt),
                style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, fontWeight: FontWeight.w600)),
          ]),
          Text(_ptz(p), style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5)),
        ]),
      ),
    );
  }

  void _showPhotoDetail(String photoUrl, String title, String subtitle) {
    PgGlassDialog.show(
      context,
      PgGlassDialog(
        title: title,
        subtitle: subtitle,
        icon: Icons.photo_camera_outlined,
        maxWidth: 960,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: _photoBox(photoUrl, fit: BoxFit.contain, aspect: 4 / 3),
        ),
      ),
    );
  }

  // ── Shared pieces ─────────────────────────────────────────

  Widget _photoBox(String url, {double? height, BoxFit fit = BoxFit.cover, double? aspect, VoidCallback? onTap}) {
    Widget box = Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.orange.withValues(alpha: .3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        Image.network(
          cameraService.getPhotoUrl(url),
          fit: fit,
          loadingBuilder: (c, child, p) =>
              p == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.orange)),
          errorBuilder: (c, e, s) => const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.image_not_supported_outlined, color: Colors.white54, size: 36),
              SizedBox(height: 6),
              Text('Picture unavailable', style: TextStyle(color: Colors.white60, fontSize: 11)),
            ]),
          ),
        ),
        if (onTap != null)
          Positioned(
            right: 8,
            bottom: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: Colors.black.withValues(alpha: .45),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                    SizedBox(width: 4),
                    Text('View', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
    if (aspect != null) {
      box = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .68),
        child: AspectRatio(aspectRatio: aspect, child: box),
      );
    }
    return onTap == null ? box : GestureDetector(onTap: onTap, child: box);
  }

  Widget _empty(IconData icon, Color color, String title, String detail) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: PgCard(
              padding: const EdgeInsets.all(22),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 48, color: color),
                const SizedBox(height: 12),
                Text(title,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 15, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12.5, height: 1.4)),
              ]),
            ),
          ),
        ),
      );
}

/// Pill-style tab bar on a glass strip (same look as the other page tabs).
class _GlassTabs extends StatelessWidget {
  const _GlassTabs({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: dark ? AppColors.darkCard.withValues(alpha: .55) : Colors.white.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.orange.withValues(alpha: .22)),
          ),
          child: TabBar(
            controller: controller,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.red, AppColors.orange]),
              borderRadius: BorderRadius.circular(10),
            ),
            labelColor: Colors.white,
            unselectedLabelColor: AppTheme.textSecondary(context),
            labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            overlayColor: WidgetStateProperty.all(AppColors.orange.withValues(alpha: .08)),
            tabs: const [
              Tab(height: 38, icon: null, text: 'Fire Alerts'),
              Tab(height: 38, text: 'Photos'),
              Tab(height: 38, text: 'Recordings'),
            ],
          ),
        ),
      ),
    );
  }
}
