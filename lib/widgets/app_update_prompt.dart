import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/firebase_bootstrap.dart';

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

@visibleForTesting
bool isNewerAppVersion({required String installed, required String available}) {
  List<int> parts(String value) => value
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: false);

  final installedParts = parts(installed);
  final availableParts = parts(available);
  final length = installedParts.length > availableParts.length
      ? installedParts.length
      : availableParts.length;
  for (var index = 0; index < length; index++) {
    final installedPart = index < installedParts.length
        ? installedParts[index]
        : 0;
    final availablePart = index < availableParts.length
        ? availableParts[index]
        : 0;
    if (availablePart != installedPart) {
      return availablePart > installedPart;
    }
  }
  return false;
}

@visibleForTesting
const appUpdateRetryDelays = <Duration>[
  Duration(seconds: 4),
  Duration(seconds: 15),
];

class AppUpdatePrompt extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  const AppUpdatePrompt({super.key, required this.child, this.navigatorKey});

  @override
  State<AppUpdatePrompt> createState() => _AppUpdatePromptState();
}

class _AppUpdatePromptState extends State<AppUpdatePrompt> {
  bool _checkedThisLaunch = false;
  bool _updateDialogShown = false;
  Timer? _retryTimer;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate(0));
  }

  Future<void> _checkForUpdate(int attempt) async {
    try {
      final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      final packageInfo = await PackageInfo.fromPlatform();
      if (isIOS) {
        final appStoreRelease = await _loadAppStoreRelease();
        if (appStoreRelease != null &&
            isNewerAppVersion(
              installed: packageInfo.version,
              available: appStoreRelease.version,
            )) {
          await _showUpdateDialog(appStoreRelease.url, isIOS: true);
          return;
        }
      } else {
        if (await _playStoreReportsUpdate()) {
          await _showUpdateDialog(_fallbackPlayStoreUrl, isIOS: false);
          return;
        }
      }
      if (Firebase.apps.isEmpty) {
        _scheduleRetry(attempt);
        return;
      }
      final data = await _loadUpdateConfiguration(isIOS: isIOS);
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
      _scheduleRetry(attempt);
    }
  }

  Future<bool> _playStoreReportsUpdate() async {
    try {
      final updateInfo = await InAppUpdate.checkForUpdate();
      return updateInfo.updateAvailability ==
          UpdateAvailability.updateAvailable;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Play Store update check unavailable: $error');
      }
      return false;
    }
  }

  Future<({String version, String url})?> _loadAppStoreRelease() async {
    try {
      final response = await http
          .get(
            Uri.https('itunes.apple.com', '/lookup', {
              'id': _iosAppId,
              'country': 'in',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final results = payload['results'];
      if (results is! List || results.isEmpty || results.first is! Map) {
        return null;
      }
      final release = Map<String, dynamic>.from(results.first as Map);
      final version = release['version']?.toString().trim() ?? '';
      if (version.isEmpty) return null;
      final configuredUrl = release['trackViewUrl']?.toString().trim() ?? '';
      return (
        version: version,
        url: configuredUrl.isEmpty ? _fallbackAppStoreUrl : configuredUrl,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('App Store update check unavailable: $error');
      }
      return null;
    }
  }

  void _scheduleRetry(int attempt) {
    if (!mounted || attempt >= appUpdateRetryDelays.length) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(
      appUpdateRetryDelays[attempt],
      () => _checkForUpdate(attempt + 1),
    );
  }

  Future<Map<String, dynamic>> _loadUpdateConfiguration({
    required bool isIOS,
  }) async {
    try {
      final response =
          await FirebaseFunctions.instanceFor(region: firebaseFunctionsRegion)
              .httpsCallable(isIOS ? 'getIosAppUpdate' : 'getAndroidAppUpdate')
              .call<Map<String, dynamic>>();
      return response.data;
    } catch (_) {
      final snapshot = await FirebaseFirestore.instance
          .collection('appConfig')
          .doc(isIOS ? 'ios' : 'android')
          .get();
      final configured = snapshot.data();
      if (configured != null) return configured;
      rethrow;
    }
  }

  Future<void> _showUpdateDialog(String storeUrl, {required bool isIOS}) {
    if (_updateDialogShown || !mounted) return Future.value();
    final navigatorContext = widget.navigatorKey?.currentContext ?? context;
    _updateDialogShown = true;
    return showDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (dialogContext) {
        var openingStore = false;
        String? storeError;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return PopScope(
              canPop: false,
              child: AlertDialog(
                icon: const Icon(Icons.system_update_alt_rounded),
                title: const Text('Update available'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'A new version of Pritze is available. Update now to continue with the latest features and fixes.',
                    ),
                    if (storeError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        storeError!,
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
                actions: [
                  FilledButton.icon(
                    onPressed: openingStore
                        ? null
                        : () async {
                            setDialogState(() {
                              openingStore = true;
                              storeError = null;
                            });
                            final opened = await _openStore(
                              storeUrl,
                              isIOS: isIOS,
                            );
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              openingStore = false;
                              if (!opened) {
                                storeError =
                                    'The app store could not be opened. Check your connection and try again.';
                              }
                            });
                          },
                    icon: openingStore
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new_rounded),
                    label: Text(openingStore ? 'Opening store…' : 'Update now'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<bool> _openStore(String fallbackUrl, {required bool isIOS}) async {
    final nativeStoreUri = isIOS
        ? Uri.parse('itms-apps://itunes.apple.com/app/id$_iosAppId')
        : Uri.parse('market://details?id=$_androidPackageName');
    try {
      if (await launchUrl(
        nativeStoreUri,
        mode: LaunchMode.externalApplication,
      )) {
        return true;
      }
    } catch (_) {
      // Devices without a native store handler fall back to the HTTPS listing.
    }
    final webUri =
        Uri.tryParse(fallbackUrl) ??
        Uri.parse(isIOS ? _fallbackAppStoreUrl : _fallbackPlayStoreUrl);
    try {
      return await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  int _readBuildNumber(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
