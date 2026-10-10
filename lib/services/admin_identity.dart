class FixedAdminIdentity {
  final int order;
  final String email;
  final String displayName;
  final String role;
  final String referenceCode;

  const FixedAdminIdentity({
    required this.order,
    required this.email,
    required this.displayName,
    required this.role,
    required this.referenceCode,
  });
}

class AdminIdentity {
  const AdminIdentity._();

  static const fixedAdmins = <FixedAdminIdentity>[
    FixedAdminIdentity(
      order: 1,
      email: 'nowel@pyroguard.local',
      displayName: 'Nowel C. Fajardo II',
      role: 'head_developer',
      referenceCode: 'PG-NWL-84QF-29MX',
    ),
    FixedAdminIdentity(
      order: 2,
      email: 'benedict@pyroguard.local',
      displayName: 'Benedict A. Carungcong',
      role: 'administrator',
      referenceCode: 'PG-BEN-61KD-73RV',
    ),
    FixedAdminIdentity(
      order: 3,
      email: 'danahia@pyroguard.local',
      displayName: 'Ma. Danahia Meish R. Lubgoban',
      role: 'administrator',
      referenceCode: 'PG-DAN-95TS-42HC',
    ),
    FixedAdminIdentity(
      order: 4,
      email: 'christian@pyroguard.local',
      displayName: 'Christian Dave M. Sapata',
      role: 'administrator',
      referenceCode: 'PG-CHR-38WP-57LJ',
    ),
  ];

  static String normalize(String? email) => (email ?? '').trim().toLowerCase();

  static bool isFixedAdminEmail(String? email) {
    final e = normalize(email);
    return fixedAdmins.any((admin) => admin.email.toLowerCase() == e);
  }

  static FixedAdminIdentity? byEmail(String? email) {
    final e = normalize(email);
    for (final admin in fixedAdmins) {
      if (admin.email.toLowerCase() == e) return admin;
    }
    return null;
  }

  static bool userMetadataMarksAdmin(Map<String, dynamic>? appMetadata) {
    return appMetadata?['pyroguard_admin'] == true ||
        appMetadata?['role'] == 'head_developer' ||
        appMetadata?['role'] == 'administrator';
  }
}
