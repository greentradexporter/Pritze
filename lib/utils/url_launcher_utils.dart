import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class UrlLauncherUtils {
  static Future<void> launchAction(
    BuildContext context,
    String urlString,
    String errorMessage,
  ) async {
    final Uri url = Uri.parse(urlString);
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(errorMessage)));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
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
    final trimmed = directionsUrl.trim();
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
    await launchAction(context, trimmed, 'Could not open the directions link.');
  }
}
