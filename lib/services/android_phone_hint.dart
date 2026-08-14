import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _phoneHintChannel = MethodChannel('com.trimtime.app/phone_hint');

@visibleForTesting
String? indianMobileDigitsFromHint(String? value) {
  final digits = value?.replaceAll(RegExp(r'\D'), '') ?? '';
  if (digits.length == 10) {
    return digits;
  }
  if (digits.length == 12 && digits.startsWith('91')) {
    return digits.substring(2);
  }
  if (digits.length == 11 && digits.startsWith('0')) {
    return digits.substring(1);
  }
  return null;
}

class DevicePhoneHint {
  const DevicePhoneHint._();

  static Future<String?> request() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return null;
    }
    try {
      final value = await _phoneHintChannel.invokeMethod<String>(
        'requestPhoneNumber',
      );
      return indianMobileDigitsFromHint(value);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled' || error.code == 'unavailable') {
        return null;
      }
      rethrow;
    }
  }
}
