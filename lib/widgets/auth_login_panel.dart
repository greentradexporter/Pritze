import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'app_ui.dart';

enum AuthLoginMethod { phone, email }

class AuthLoginPanel extends StatefulWidget {
  final UserRole role;
  final VoidCallback? onLoggedIn;
  final String? phoneHelperText;
  final bool embedded;

  const AuthLoginPanel({
    super.key,
    required this.role,
    this.onLoggedIn,
    this.phoneHelperText,
    this.embedded = false,
  });

  @override
  State<AuthLoginPanel> createState() => _AuthLoginPanelState();
}

class _AuthLoginPanelState extends State<AuthLoginPanel> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailOtpController = TextEditingController();
  final _nameFocusNode = FocusNode();
  final _phoneFocusNode = FocusNode();
  final _phoneOtpFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _emailOtpFocusNode = FocusNode();
  AuthLoginMethod _method = AuthLoginMethod.phone;
  bool _isSubmitting = false;
  bool _phoneOtpSent = false;
  bool _emailOtpSent = false;
  String _verificationId = '';
  Timer? _resendTimer;
  int _resendSeconds = 0;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _emailController.dispose();
    _emailOtpController.dispose();
    _nameFocusNode.dispose();
    _phoneFocusNode.dispose();
    _phoneOtpFocusNode.dispose();
    _emailFocusNode.dispose();
    _emailOtpFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phoneOnly = widget.role == UserRole.customer;
    final content = AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!phoneOnly) ...[
            SegmentedButton<AuthLoginMethod>(
              segments: const [
                ButtonSegment(
                  value: AuthLoginMethod.phone,
                  icon: Icon(Icons.phone_android_outlined),
                  label: Text('Phone'),
                ),
                ButtonSegment(
                  value: AuthLoginMethod.email,
                  icon: Icon(Icons.alternate_email),
                  label: Text('Email'),
                ),
              ],
              selected: {_method},
              onSelectionChanged: _isSubmitting
                  ? null
                  : (selection) {
                      _switchMethod(selection.first);
                    },
            ),
            const SizedBox(height: 14),
          ],
          if (_method == AuthLoginMethod.phone) ...[
            if (phoneOnly) ...[
              TextField(
                key: const ValueKey('customer-name-field'),
                controller: _nameController,
                focusNode: _nameFocusNode,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                readOnly: _phoneOtpSent,
                autofillHints: const [AutofillHints.name],
                onSubmitted: (_) => _phoneFocusNode.requestFocus(),
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  hintText: 'Enter your full name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('phone-login-field'),
              controller: _phoneController,
              focusNode: _phoneFocusNode,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              readOnly: _phoneOtpSent,
              autofillHints: const [AutofillHints.telephoneNumber],
              onSubmitted: (_) {
                if (!_phoneOtpSent && !_isSubmitting) {
                  _submit();
                }
              },
              decoration: InputDecoration(
                labelText: 'Phone number',
                hintText: 'Enter mobile number',
                helperText: widget.phoneHelperText ?? 'We will send an OTP.',
                prefixIcon: const Icon(Icons.phone_android_outlined),
              ),
            ),
            if (_phoneOtpSent) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('phone-otp-field'),
                controller: _otpController,
                focusNode: _phoneOtpFocusNode,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 6,
                autofillHints: const [AutofillHints.oneTimeCode],
                onSubmitted: (_) {
                  if (!_isSubmitting) {
                    _submit();
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Enter OTP',
                  counterText: '',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('change-phone-number-button'),
                    onPressed: _isSubmitting ? null : _resetPhoneOtp,
                    child: const Text('Change number'),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    key: const ValueKey('resend-phone-otp-button'),
                    onPressed: _isSubmitting || _resendSeconds > 0
                        ? null
                        : _resendPhoneOtp,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      _resendSeconds > 0
                          ? 'Resend in ${_resendSeconds}s'
                          : 'Resend code',
                    ),
                  ),
                ],
              ),
            ],
          ] else if (_method == AuthLoginMethod.email) ...[
            TextField(
              key: const ValueKey('email-login-field'),
              controller: _emailController,
              focusNode: _emailFocusNode,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            if (_emailOtpSent) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('email-otp-field'),
                controller: _emailOtpController,
                focusNode: _emailOtpFocusNode,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 6,
                autofillHints: const [AutofillHints.oneTimeCode],
                onSubmitted: (_) {
                  if (!_isSubmitting) {
                    _submit();
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Enter email OTP',
                  helperText: 'Check your inbox for the 6-digit code.',
                  counterText: '',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isSubmitting ? null : _submit,
            icon: _isSubmitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_buttonIcon),
            label: Text(_buttonLabel),
          ),
          if (!phoneOnly) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'or',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _isSubmitting ? null : _submitGoogle,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Continue with Gmail'),
            ),
          ],
        ],
      ),
    );
    if (widget.embedded) {
      return content;
    }
    return GlassCard(child: content);
  }

  void _switchMethod(AuthLoginMethod method) {
    if (method == _method) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _resendTimer?.cancel();
    setState(() {
      _method = method;
      _phoneOtpSent = false;
      _emailOtpSent = false;
      _verificationId = '';
      _resendSeconds = 0;
      _otpController.clear();
      _emailOtpController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      switch (method) {
        case AuthLoginMethod.phone:
          _phoneFocusNode.requestFocus();
        case AuthLoginMethod.email:
          _emailFocusNode.requestFocus();
      }
    });
  }

  IconData get _buttonIcon {
    return switch (_method) {
      AuthLoginMethod.phone => Icons.sms_outlined,
      AuthLoginMethod.email => Icons.mark_email_unread_outlined,
    };
  }

  String get _buttonLabel {
    return switch (_method) {
      AuthLoginMethod.phone =>
        _phoneOtpSent ? 'Verify and sign in' : 'Continue',
      AuthLoginMethod.email =>
        _emailOtpSent ? 'Verify and sign in' : 'Continue',
    };
  }

  Future<void> _submit() async {
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      switch (_method) {
        case AuthLoginMethod.phone:
          await _submitPhone(appState);
        case AuthLoginMethod.email:
          await _submitEmail(appState);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyLoginError(error))));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _submitGoogle() async {
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      await _loginWithGoogle(appState);
      widget.onLoggedIn?.call();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyLoginError(error))));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _submitPhone(AppState appState) async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    if (widget.role == UserRole.customer && name.isEmpty) {
      _showSnack('Enter your name');
      _nameFocusNode.requestFocus();
      return;
    }
    if (phone.isEmpty) {
      _showSnack('Enter your phone number');
      return;
    }
    if (!_phoneOtpSent) {
      final verificationId = await appState.sendPhoneOtp(phone: phone);
      if (!mounted) {
        return;
      }
      if (verificationId.isEmpty) {
        await _loginWithPhone(appState);
        widget.onLoggedIn?.call();
        return;
      }
      setState(() {
        _verificationId = verificationId;
        _phoneOtpSent = true;
      });
      _startResendCountdown();
      _showSnack('OTP sent to ${appState.normalizePhone(phone)}');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _phoneOtpFocusNode.requestFocus();
        }
      });
      return;
    }
    await _loginWithPhone(appState);
    widget.onLoggedIn?.call();
  }

  Future<void> _resendPhoneOtp() async {
    if (_isSubmitting || _resendSeconds > 0) {
      return;
    }
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      final verificationId = await appState.resendPhoneOtp(
        phone: _phoneController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      _otpController.clear();
      _verificationId = verificationId;
      if (verificationId.isEmpty) {
        await _loginWithPhone(appState);
        widget.onLoggedIn?.call();
        return;
      }
      _startResendCountdown();
      _showSnack(
        'A new OTP was sent to ${appState.normalizePhone(_phoneController.text)}',
      );
      _phoneOtpFocusNode.requestFocus();
    } catch (error) {
      if (mounted) {
        _showSnack(_friendlyLoginError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
        return;
      }
      setState(() => _resendSeconds -= 1);
    });
  }

  void _resetPhoneOtp() {
    _resendTimer?.cancel();
    setState(() {
      _phoneOtpSent = false;
      _verificationId = '';
      _resendSeconds = 0;
      _otpController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _phoneFocusNode.requestFocus();
      }
    });
  }

  Future<void> _submitEmail(AppState appState) async {
    final email = _emailController.text.trim();
    final hasValidEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
    if (!hasValidEmail) {
      _showSnack('Enter a valid email address');
      return;
    }
    if (!_emailOtpSent) {
      await appState.sendEmailOtp(email: email);
      if (!mounted) {
        return;
      }
      setState(() => _emailOtpSent = true);
      _showSnack('Email OTP sent. Enter the code to continue.');
      return;
    }
    final otp = _emailOtpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
      _showSnack('Enter the 6-digit code from your email');
      _emailOtpFocusNode.requestFocus();
      return;
    }
    await _loginWithEmail(appState);
    widget.onLoggedIn?.call();
  }

  Future<void> _loginWithPhone(AppState appState) {
    final phone = _phoneController.text.trim();
    final otp = _otpController.text.trim();
    return switch (widget.role) {
      UserRole.customer => appState.loginCustomerWithPhone(
        name: _nameController.text.trim(),
        phone: phone,
        verificationId: _verificationId,
        smsCode: otp,
      ),
      UserRole.owner => appState.loginOwnerWithPhone(
        phone: phone,
        verificationId: _verificationId,
        smsCode: otp,
      ),
      UserRole.barber => Future<void>.error(
        StateError('Barber access is managed by the salon owner.'),
      ),
    };
  }

  Future<void> _loginWithEmail(AppState appState) {
    final email = _emailController.text.trim();
    final otp = _emailOtpController.text.trim();
    return switch (widget.role) {
      UserRole.customer => appState.loginCustomerWithEmail(
        name: '',
        email: email,
        emailLink: otp,
      ),
      UserRole.owner => appState.loginOwnerWithEmail(
        name: '',
        email: email,
        emailLink: otp,
      ),
      UserRole.barber => Future<void>.error(
        StateError('Barber access is managed by the salon owner.'),
      ),
    };
  }

  Future<void> _loginWithGoogle(AppState appState) {
    return switch (widget.role) {
      UserRole.customer => appState.loginCustomerWithGmail(name: '', email: ''),
      UserRole.owner => appState.loginOwnerWithGmail(name: '', email: ''),
      UserRole.barber => Future<void>.error(
        StateError('Barber access is managed by the salon owner.'),
      ),
    };
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyLoginError(Object error) {
    if (error is FirebaseFunctionsException) {
      final detail = error.message?.toLowerCase() ?? '';
      if (error.code == 'permission-denied' &&
          detail.contains('incorrect email otp')) {
        return 'That email OTP is not correct. Please check the code and try again.';
      }
      if (error.code == 'not-found') {
        return 'Request a new email OTP, then try again.';
      }
      if (error.code == 'deadline-exceeded') {
        return 'That email OTP has expired. Request a new code.';
      }
      if (error.code == 'resource-exhausted') {
        return detail.contains('wait')
            ? 'Please wait before requesting another email OTP.'
            : 'Too many OTP attempts. Request a new code.';
      }
      if (error.code == 'invalid-argument') {
        return error.message ?? 'Enter a valid email address and OTP.';
      }
    }
    final message = error.toString();
    if (message.contains('firebase_functions/permission-denied') ||
        message.contains('PERMISSION_DENIED')) {
      return 'Email OTP is blocked by Firebase app verification. Please install the latest build and make sure this app is registered in Firebase App Check.';
    }
    if (message.contains('firebase_functions/failed-precondition') ||
        message.contains('Service Account Token Creator') ||
        message.contains('signBlob') ||
        message.contains('auth/insufficient-permission')) {
      return 'Email OTP is verified, but Firebase cannot finish sign-in yet. The Cloud Function service account needs the Service Account Token Creator role.';
    }
    if (message.contains('firebase_functions/internal')) {
      return 'Email OTP verification reached Firebase, but sign-in could not be completed. Please try again after the server permission fix is applied.';
    }
    if (message.contains('Invalid app info') ||
        message.contains('app-not-authorized') ||
        message.contains('17028')) {
      return 'Phone OTP is blocked by Firebase app verification. Add the app signing certificate in Firebase, wait a few minutes, then try again.';
    }
    if (message.contains('too-many-requests') || message.contains('quota')) {
      return 'Too many OTP attempts. Please wait and try again.';
    }
    if (message.contains('invalid-phone-number')) {
      return 'Enter the phone number with country code, for example +91 98765 43210.';
    }
    if (message.contains('invalid-verification-code')) {
      return 'That OTP is not correct. Please check the code and try again.';
    }
    return 'Login failed: $message';
  }
}
