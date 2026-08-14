import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class UrlLauncherUtils {
  static Future<void> launchAction(
    BuildContext context,
    String urlString,
    String errorMessage,
  ) async {
    final Uri? url = Uri.tryParse(urlString);
    if (url == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMessage)));
      }
      return;
    }
    final launched = await _tryLaunch(url, const [
      LaunchMode.externalApplication,
      LaunchMode.platformDefault,
    ]);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  static Future<void> makePhoneCall(
    BuildContext context,
    String phoneNumber,
  ) async {
    await launchAction(
      context,
      'tel:$phoneNumber',
      'Could not launch phone dialer.',
    );
  }

  static Future<void> openWhatsApp(
    BuildContext context,
    String phoneNumber,
  ) async {
    String cleanPhone = phoneNumber.replaceAll(RegExp(r'\D'), '');
    if (!cleanPhone.startsWith('91') && cleanPhone.length == 10) {
      cleanPhone = '91$cleanPhone';
    }
    await launchAction(
      context,
      'https://wa.me/$cleanPhone',
      'Could not open WhatsApp.',
    );
  }

  static Future<void> openDirectionsLink(
    BuildContext context,
    String directionsUrl,
  ) async {
    var trimmed = directionsUrl.trim();
    if (trimmed.isNotEmpty && !trimmed.contains('://')) {
      trimmed = 'https://$trimmed';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Directions link has not been added by this salon.'),
        ),
      );
      return;
    }
    final launched = await _tryLaunch(uri, const [
      LaunchMode.externalNonBrowserApplication,
      LaunchMode.externalApplication,
      LaunchMode.platformDefault,
    ]);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps.')),
      );
    }
  }

  static Future<bool> _tryLaunch(Uri uri, List<LaunchMode> modes) async {
    for (final mode in modes) {
      try {
        if (await launchUrl(uri, mode: mode)) {
          return true;
        }
      } catch (_) {
        // Some Android devices reject one launch mode even though another mode
        // can handle the same Maps, phone, or web URI.
      }
    }
    return false;
  }
}
