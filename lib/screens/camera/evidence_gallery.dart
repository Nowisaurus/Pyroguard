import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/camera_service.dart';
import '../../theme.dart';
import '../../responsive.dart';

/// Evidence gallery tab - shows fire incidents and captured photos
class EvidenceGalleryTab extends StatefulWidget {
  const EvidenceGalleryTab({super.key});

  @override
  State<EvidenceGalleryTab> createState() => _EvidenceGalleryTabState();
}

class _EvidenceGalleryTabState extends State<EvidenceGalleryTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late CameraService cameraService;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    cameraService = CameraService.instance;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Evidence & Gallery'),
        backgroundColor: Colors.transparent,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.red,
          labelColor: AppTheme.brandForeground(context),
          unselectedLabelColor: AppTheme.textSecondary(context),
          tabs: const [
            Tab(text: 'Fire Incidents'),
            Tab(text: 'All Photos'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildIncidentsTab(),
          _buildPhotosTab(),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // Fire Incidents Tab
  // ──────────────────────────────────────────────────────────

  Widget _buildIncidentsTab() {
    return FutureBuilder<List<AlertLog>>(
      future: cameraService.getEvidencePhotos(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.red),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading incidents',
              style: TextStyle(color: AppTheme.textSecondary(context)),
            ),
          );
        }

        final incidents = snapshot.data ?? [];

        if (incidents.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: AppColors.green,
                ),
                const SizedBox(height: 16),
                Text(
                  'No fire incidents detected',
                  style: TextStyle(
                    color: AppTheme.textSecondary(context),
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 12, Responsive.horizontalPadding(context), 96),
          itemCount: incidents.length,
          itemBuilder: (context, index) {
            final incident = incidents[index];
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: _buildIncidentCard(incident),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildIncidentCard(AlertLog incident) {
    final dateFormatter = DateFormat('MMM dd, yyyy • HH:mm:ss');
    final formattedDate = dateFormatter.format(incident.createdAt);

    return GestureDetector(
      onTap: () => _showIncidentDetail(incident),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: GlassStyle.card(
          light: !AppTheme.isDark(context),
          border: AppColors.red.withValues(alpha: .3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Alert type + severity
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.red, width: 1.5),
                  ),
                  child: Text(
                    incident.alertType,
                    style: const TextStyle(
                      color: AppColors.red,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.orange, width: 1),
                  ),
                  child: Text(
                    incident.severityLevel,
                    style: TextStyle(
                      color: AppTheme.warningForeground(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  formattedDate,
                  style: TextStyle(
                    color: AppTheme.textSecondary(context),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Sensor data grid
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.bg(context),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.orange.withValues(alpha: .2)),
              ),
              child: Column(
                children: [
                  _sensorRow(Icons.thermostat_outlined, 'Temperature', '${incident.temperature.toStringAsFixed(1)}°C'),
                  const SizedBox(height: 8),
                  _sensorRow(Icons.air_outlined, 'Smoke Level', '${incident.smokeLevel}'),
                  const SizedBox(height: 8),
                  _sensorRow(Icons.local_fire_department_outlined, 'Flame Status', incident.flameStatus),
                  const SizedBox(height: 8),
                  _sensorRow(Icons.location_on_outlined, 'Location', incident.location),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Evidence photo (if available)
            if (incident.photoUrl != null)
              GestureDetector(
                onTap: () => _showPhotoDetail(incident.photoUrl!, incident.alertType),
                child: Container(
                  width: double.infinity,
                  height: 200,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.black,
                    border: Border.all(
                      color: AppColors.orange.withValues(alpha: .3),
                      width: 1.5,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        cameraService.getPhotoUrl(incident.photoUrl!),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(
                              Icons.image_not_supported,
                              color: Colors.white30,
                              size: 48,
                            ),
                          );
                        },
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.zoom_in, color: Colors.white70, size: 14),
                              SizedBox(width: 4),
                              Text(
                                'Tap to view',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sensorRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.brandForeground(context)),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: TextStyle(
              color: AppTheme.textPrimary(context),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────
  // All Photos Tab
  // ──────────────────────────────────────────────────────────

  Widget _buildPhotosTab() {
    return FutureBuilder<List<CameraEvent>>(
      future: cameraService.getCapturedPhotos(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.orange),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading photos',
              style: TextStyle(color: AppTheme.textSecondary(context)),
            ),
          );
        }

        final photos = snapshot.data ?? [];

        if (photos.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.photo_library_outlined,
                  size: 64,
                  color: AppTheme.textSecondary(context).withValues(alpha: .55),
                ),
                const SizedBox(height: 16),
                Text(
                  'No photos captured yet',
                  style: TextStyle(
                    color: AppTheme.textSecondary(context),
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width < 340 ? 1 : width < 650 ? 2 : width < 950 ? 3 : 4;
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 12, Responsive.horizontalPadding(context), 96),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.05,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, index) {
                    final photo = photos[index];
                    return _buildPhotoTile(photo);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotoTile(CameraEvent photo) {
    return GestureDetector(
      onTap: () => _showPhotoDetail(
        photo.snapshotUrl!,
        'Pan: ${photo.panAtCapture}° • Tilt: ${photo.tiltAtCapture}°',
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: AppTheme.card(context),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Photo
              photo.snapshotUrl != null
                  ? Image.network(
                      cameraService.getPhotoUrl(photo.snapshotUrl!),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Center(
                          child: Icon(
                            Icons.image_not_supported_outlined,
                            color: AppTheme.textSecondary(context).withValues(alpha: .6),
                          ),
                        );
                      },
                    )
                  : Center(
                      child: Icon(Icons.photo_outlined, color: AppTheme.textSecondary(context).withValues(alpha: .6)),
                    ),

              // Timestamp overlay
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    DateFormat('HH:mm:ss').format(photo.createdAt),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
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

  // ──────────────────────────────────────────────────────────
  // Detail Views
  // ──────────────────────────────────────────────────────────

  void _showIncidentDetail(AlertLog incident) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppTheme.surface(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              title: Text(incident.alertType),
              backgroundColor: AppTheme.surface(context),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDetailRow('Alert Type', incident.alertType),
                    _buildDetailRow('Severity', incident.severityLevel),
                    _buildDetailRow('Temperature', '${incident.temperature}°C'),
                    _buildDetailRow('Smoke Level', incident.smokeLevel.toString()),
                    _buildDetailRow('Flame Status', incident.flameStatus),
                    _buildDetailRow('Location', incident.location),
                    _buildDetailRow(
                      'Timestamp',
                      DateFormat('MMM dd, yyyy • HH:mm:ss').format(incident.createdAt),
                    ),
                    if (incident.photoUrl != null) ...[
                      const SizedBox(height: 16),
                      const Text('Evidence Photo',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 12)),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          cameraService.getPhotoUrl(incident.photoUrl!),
                          fit: BoxFit.cover,
                          height: 300,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textSecondary(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: AppTheme.textPrimary(context),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPhotoDetail(String photoUrl, String subtitle) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              title: Text(subtitle),
              backgroundColor: AppTheme.surface(context),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black,
                child: Image.network(
                  cameraService.getPhotoUrl(photoUrl),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Text(
                        'Failed to load image',
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
