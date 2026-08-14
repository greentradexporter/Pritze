import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _androidPackageName = 'com.trimtime.app';
const _fallbackPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=$_androidPackageName';
const _iosAppId = '6792811282';
const _fallbackAppStoreUrl =
    'https://apps.apple.com/in/app/pritze/id$_iosAppId';

@visibleForTesting
bool shouldShowAppUpdate({
  required int installedBuild,
  required int latestBuild,
}) {
  return latestBuild > installedBuild;
}

class AppUpdatePrompt extends StatefulWidget {
  final Widget child;

  const AppUpdatePrompt({super.key, required this.child});

  @override
  State<AppUpdatePrompt> createState() => _AppUpdatePromptState();
}

class _AppUpdatePromptState extends State<AppUpdatePrompt> {
  bool _checkedThisLaunch = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final supportedPlatform =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (_checkedThisLaunch || kIsWeb || !supportedPlatform) {
      return;
    }
    _checkedThisLaunch = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    try {
      if (Firebase.apps.isEmpty) return;
      final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      final results = await Future.wait<Object>([
        PackageInfo.fromPlatform(),
        _loadUpdateConfiguration(isIOS: isIOS),
      ]);
      final packageInfo = results[0] as PackageInfo;
      final data = results[1] as Map<String, dynamic>;
      if (!mounted) return;

      final installedBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      final latestBuild = _readBuildNumber(
        isIOS
            ? data['latestBuildNumber'] ?? data['latestVersionCode']
            : data['latestVersionCode'] ?? data['latestBuildNumber'],
      );
      if (!shouldShowAppUpdate(
        installedBuild: installedBuild,
        latestBuild: latestBuild,
      )) {
        return;
      }
      final configuredUrl =
          data[isIOS ? 'appStoreUrl' : 'playStoreUrl']?.toString().trim() ?? '';
      await _showUpdateDialog(
        configuredUrl.isEmpty
            ? isIOS
                  ? _fallbackAppStoreUrl
                  : _fallbackPlayStoreUrl
            : configuredUrl,
        isIOS: isIOS,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Could not check for a Pritze update: $error');
      }
    }
  }

  Future<Map<String, dynamic>> _loadUpdateConfiguration({
    required bool isIOS,
  }) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('appConfig')
        .doc(isIOS ? 'ios' : 'android')
        .get();
    final configured = snapshot.data();
    if (configured != null) return configured;
    final response = await FirebaseFunctions.instance
        .httpsCallable(isIOS ? 'getIosAppUpdate' : 'getAndroidAppUpdate')
        .call<Map<String, dynamic>>();
    return response.data;
  }

  Future<void> _showUpdateDialog(String storeUrl, {required bool isIOS}) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: const Text('Update available'),
        content: const Text(
          'There is an update available for Pritze. Update the app to get the latest features and fixes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _openStore(storeUrl, isIOS: isIOS);
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Update'),
          ),
        ],
      ),
    );
  }

  Future<void> _openStore(String fallbackUrl, {required bool isIOS}) async {
    final nativeStoreUri = isIOS
        ? Uri.parse('itms-apps://itunes.apple.com/app/id$_iosAppId')
        : Uri.parse('market://details?id=$_androidPackageName');
    try {
      if (await launchUrl(
        nativeStoreUri,
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Devices without a native store handler fall back to the HTTPS listing.
    }
    final webUri =
        Uri.tryParse(fallbackUrl) ??
        Uri.parse(isIOS ? _fallbackAppStoreUrl : _fallbackPlayStoreUrl);
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  int _readBuildNumber(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
