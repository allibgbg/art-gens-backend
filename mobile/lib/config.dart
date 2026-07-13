/// Compile-time flag: true for admin APK, false for lambda APK.
/// Build admin: flutter build apk --dart-define=ADMIN_BUILD=true
/// Build lambda: flutter build apk
const bool kAdminBuild = bool.fromEnvironment('ADMIN_BUILD');
