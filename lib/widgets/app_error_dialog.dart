import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AppErrorPresentation {
  final String title;
  final String message;

  const AppErrorPresentation({required this.title, required this.message});
}

const _genericError = AppErrorPresentation(
  title: 'Something went wrong',
  message:
      'Please try again. If the problem continues, contact Pritze support.',
);

const _secureSessionError = AppErrorPresentation(
  title: 'Secure session check failed',
  message:
      'We could not verify this app session. Try again, or reopen the app if it continues.',
);

/// Converts operational failures into copy that is safe to render in the app.
///
/// Backend SDK labels, stack traces, document paths and implementation details
/// must never be shown to customers, salon owners or barbers. Known validation
/// messages are retained so that users still know how to correct their input.
AppErrorPresentation friendlyOperationError(
  Object? error, {
  String title = 'Something went wrong',
  String message = 'Please try again in a moment.',
}) {
  if (error is FirebaseAuthException) {
    return friendlyAuthenticationError(error);
  }

  if (error is FirebaseException) {
    final code = error.code.toLowerCase();
    final detail = error.message?.trim() ?? '';
    if (code == 'unauthenticated' || code == 'user-token-expired') {
      return _secureSessionError;
    }
    if (code == 'permission-denied') {
      return const AppErrorPresentation(
        title: 'Unable to continue',
        message: 'This action is not available for your account.',
      );
    }
    if (code == 'unavailable' || code == 'network-request-failed') {
      return const AppErrorPresentation(
        title: 'Connection problem',
        message: 'Check your internet connection and try again.',
      );
    }
    if (code == 'deadline-exceeded' || code == 'timeout') {
      return const AppErrorPresentation(
        title: 'Request timed out',
        message: 'The request took too long. Please try again.',
      );
    }
    if (code == 'resource-exhausted' || code == 'too-many-requests') {
      return const AppErrorPresentation(
        title: 'Please wait',
        message: 'Too many requests were made. Wait a little and try again.',
      );
    }
    if ({
          'invalid-argument',
          'failed-precondition',
          'not-found',
          'already-exists',
          'aborted',
        }.contains(code) &&
        _isSafeUserMessage(detail)) {
      return AppErrorPresentation(title: title, message: detail);
    }
    return AppErrorPresentation(title: title, message: message);
  }

  final raw = _cleanErrorText(error?.toString() ?? '');
  final lower = raw.toLowerCase();
  if (lower.contains('unauthenticated') ||
      lower.contains('sign in again') ||
      lower.contains('sign in first') ||
      lower.contains('login is required') ||
      lower.contains('log in as a')) {
    return _secureSessionError;
  }
  if (lower.contains('network') ||
      lower.contains('socketexception') ||
      lower.contains('connection') ||
      lower.contains('unavailable')) {
    return const AppErrorPresentation(
      title: 'Connection problem',
      message: 'Check your internet connection and try again.',
    );
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return const AppErrorPresentation(
      title: 'Request timed out',
      message: 'The request took too long. Please try again.',
    );
  }
  if (_isSafeUserMessage(raw)) {
    return AppErrorPresentation(title: title, message: raw);
  }
  return AppErrorPresentation(title: title, message: message);
}

String friendlyErrorMessage(
  Object? error, {
  String fallback = 'Please try again in a moment.',
}) => friendlyOperationError(error, message: fallback).message;

String _cleanErrorText(String raw) => raw
    .replaceFirst(
      RegExp(
        r'^(Bad state|StateError|FormatException|Invalid argument|Exception):\s*',
        caseSensitive: false,
      ),
      '',
    )
    .replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '')
    .trim();

bool _isSafeUserMessage(String value) {
  final text = _cleanErrorText(value);
  if (text.isEmpty || text.length > 180 || text.contains('\n')) return false;
  final lower = text.toLowerCase();
  const internalMarkers = <String>[
    'firebase',
    'platformexception',
    'methodchannel',
    'stack trace',
    'package:',
    '.dart:',
    '.js:',
    'cloud_firestore',
    'firebase_functions',
    'firebase_auth',
    'documentreference',
    'null check operator',
    'nosuchmethod',
    'internal error',
  ];
  return !internalMarkers.any(lower.contains);
}

AppErrorPresentation friendlyAuthenticationError(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-phone-number':
        return const AppErrorPresentation(
          title: 'Check phone number',
          message: 'Enter a valid 10-digit Indian mobile number.',
        );
      case 'operation-not-allowed':
        return const AppErrorPresentation(
          title: 'Phone login unavailable',
          message:
              'Phone login is not available right now. Please try again shortly.',
        );
      case 'app-not-authorized':
      case 'invalid-app-credential':
      case 'captcha-check-failed':
      case 'missing-client-identifier':
        return const AppErrorPresentation(
          title: 'Phone verification blocked',
          message:
              'We could not start phone verification on this app build. Please update the app or try again shortly.',
        );
      case 'credential-already-in-use':
      case 'account-exists-with-different-credential':
      case 'email-already-in-use':
        return const AppErrorPresentation(
          title: 'Phone number already linked',
          message:
              'This phone number is already linked to another account. Sign in with that account or use a different number.',
        );
      case 'invalid-verification-code':
        return const AppErrorPresentation(
          title: 'Incorrect OTP',
          message: 'That OTP is not correct. Check the code and try again.',
        );
      case 'session-expired':
      case 'invalid-verification-id':
        return const AppErrorPresentation(
          title: 'OTP expired',
          message: 'Request a new OTP and enter only the latest code.',
        );
      case 'too-many-requests':
      case 'quota-exceeded':
        return const AppErrorPresentation(
          title: 'Please wait',
          message:
              'Too many OTP attempts were made. Wait a little and try again.',
        );
      case 'network-request-failed':
        return const AppErrorPresentation(
          title: 'Connection problem',
          message: 'Check your internet connection and try again.',
        );
    }
  }

  if (error is FirebaseFunctionsException) {
    final detail = error.message?.trim() ?? '';
    final lowerDetail = detail.toLowerCase();
    if (error.code == 'already-exists') {
      return AppErrorPresentation(
        title: 'Phone number already registered',
        message: _accountConflictMessage(detail),
      );
    }
    if (error.code == 'permission-denied' &&
        lowerDetail.contains('incorrect email otp')) {
      return const AppErrorPresentation(
        title: 'Incorrect OTP',
        message: 'That email OTP is not correct. Check the code and try again.',
      );
    }
    if (error.code == 'not-found') {
      return const AppErrorPresentation(
        title: 'Request a new OTP',
        message: 'Request a new email OTP, then try again.',
      );
    }
    if (error.code == 'deadline-exceeded') {
      return const AppErrorPresentation(
        title: 'OTP expired',
        message: 'That email OTP has expired. Request a new code.',
      );
    }
    if (error.code == 'resource-exhausted') {
      return const AppErrorPresentation(
        title: 'Please wait',
        message:
            'Too many OTP attempts were made. Wait a little and try again.',
      );
    }
    if (error.code == 'invalid-argument') {
      return const AppErrorPresentation(
        title: 'Check your details',
        message: 'Check the information you entered and try again.',
      );
    }
    if (error.code == 'unavailable') {
      return const AppErrorPresentation(
        title: 'Connection problem',
        message: 'The login service is unavailable. Please try again shortly.',
      );
    }
    return _genericError;
  }

  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('already registered as a') ||
      lower.contains('already registered as an') ||
      lower.contains('already registered as owner') ||
      lower.contains('already registered as customer')) {
    return AppErrorPresentation(
      title: 'Phone number already registered',
      message: _accountConflictMessage(raw),
    );
  }
  if (lower.contains('credential-already-in-use') ||
      lower.contains('account-exists-with-different-credential') ||
      lower.contains('phone number is already linked')) {
    return const AppErrorPresentation(
      title: 'Phone number already linked',
      message:
          'This phone number is already linked to another account. Sign in with that account or use a different number.',
    );
  }
  if (lower.contains('invalid-phone-number')) {
    return const AppErrorPresentation(
      title: 'Check phone number',
      message: 'Enter a valid 10-digit Indian mobile number.',
    );
  }
  if (lower.contains('operation-not-allowed')) {
    return const AppErrorPresentation(
      title: 'Phone login unavailable',
      message:
          'Phone login is not available right now. Please try again shortly.',
    );
  }
  if (lower.contains('app-not-authorized') ||
      lower.contains('invalid-app-credential') ||
      lower.contains('captcha-check-failed') ||
      lower.contains('missing-client-identifier')) {
    return const AppErrorPresentation(
      title: 'Phone verification blocked',
      message:
          'We could not start phone verification on this app build. Please update the app or try again shortly.',
    );
  }
  if (lower.contains('invalid-verification-code') ||
      lower.contains('incorrect otp')) {
    return const AppErrorPresentation(
      title: 'Incorrect OTP',
      message: 'That OTP is not correct. Check the code and try again.',
    );
  }
  if (lower.contains('replaced by a newer code') ||
      lower.contains('session-expired')) {
    return const AppErrorPresentation(
      title: 'Use the latest OTP',
      message: 'That OTP is no longer valid. Enter the latest code we sent.',
    );
  }
  if (lower.contains('too-many-requests') || lower.contains('quota')) {
    return const AppErrorPresentation(
      title: 'Please wait',
      message: 'Too many OTP attempts were made. Wait a little and try again.',
    );
  }
  if (lower.contains('network-request-failed') ||
      lower.contains('unavailable')) {
    return const AppErrorPresentation(
      title: 'Connection problem',
      message: 'Check your internet connection and try again.',
    );
  }
  if (lower.contains('cancelled') || lower.contains('canceled')) {
    return const AppErrorPresentation(
      title: 'Sign-in cancelled',
      message: 'Google sign-in was cancelled. You can try again when ready.',
    );
  }
  return _genericError;
}

AppErrorPresentation friendlyOnboardingError(Object error) {
  if (error is FirebaseAuthException) {
    return friendlyAuthenticationError(error);
  }
  if (error is FirebaseFunctionsException) {
    if (error.code == 'already-exists') {
      return friendlyAuthenticationError(error);
    }
    final detail = error.message?.trim() ?? '';
    final lowerDetail = detail.toLowerCase();
    final safeDetail =
        detail.isNotEmpty &&
        detail.length <= 160 &&
        !lowerDetail.contains('firebase') &&
        !lowerDetail.contains('exception') &&
        !lowerDetail.contains('permission') &&
        !lowerDetail.contains('internal');
    if ((error.code == 'invalid-argument' || error.code == 'not-found') &&
        safeDetail) {
      return AppErrorPresentation(title: 'Check your details', message: detail);
    }
    return _genericError;
  }
  final raw = error
      .toString()
      .replaceFirst(
        RegExp(r'^(Bad state|StateError|FormatException|Invalid argument):\s*'),
        '',
      )
      .trim();
  final lower = raw.toLowerCase();
  final looksInternal =
      lower.contains('firebase') ||
      lower.contains('exception') ||
      lower.contains('permission-denied') ||
      lower.contains('failed-precondition') ||
      lower.contains('stack') ||
      lower.contains('null check');
  if (raw.isNotEmpty && raw.length <= 160 && !looksInternal) {
    return AppErrorPresentation(title: 'Check your details', message: raw);
  }
  return _genericError;
}

String _accountConflictMessage(String raw) {
  final cleaned = raw
      .replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '')
      .replaceFirst(
        RegExp(r'^(Bad state|StateError|Exception):\s*', caseSensitive: false),
        '',
      )
      .trim();
  final lower = cleaned.toLowerCase();
  if (lower.contains('salon owner') || lower.contains('registered as owner')) {
    return 'This phone number is already registered as a salon owner and cannot be used for a customer account.';
  }
  if (lower.contains('customer')) {
    return 'This phone number is already registered as a customer and cannot be used for a salon owner account.';
  }
  return 'This phone number is already linked to another account. Sign in with that account or use a different number.';
}

Future<void> showAppErrorDialog(
  BuildContext context,
  AppErrorPresentation error,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      icon: Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.coral.withAlpha(22),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline_rounded,
            color: AppColors.coral,
            size: 36,
          ),
        ),
      ),
      title: Text(error.title, textAlign: TextAlign.center),
      content: Text(
        error.message,
        textAlign: TextAlign.center,
        style: Theme.of(
          dialogContext,
        ).textTheme.bodyLarge?.copyWith(color: AppColors.muted, height: 1.45),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Try again'),
          ),
        ),
      ],
    ),
  );
}
