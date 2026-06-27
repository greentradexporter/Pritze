import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

enum AuthLoginMethod { phone, email, google }

class AuthLoginPanel extends StatefulWidget {
  final UserRole role;
  final VoidCallback? onLoggedIn;
  final String googleTitle;
  final String googleMessage;
  final String? phoneHelperText;

  const AuthLoginPanel({
    super.key,
    required this.role,
    this.onLoggedIn,
    required this.googleTitle,
    required this.googleMessage,
    this.phoneHelperText,
  });

  @override
  State<AuthLoginPanel> createState() => _AuthLoginPanelState();
}

class _AuthLoginPanelState extends State<AuthLoginPanel> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailOtpController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  final _phoneOtpFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _emailOtpFocusNode = FocusNode();
  AuthLoginMethod _method = AuthLoginMethod.phone;
  bool _isSubmitting = false;
  bool _phoneOtpSent = false;
  bool _emailOtpSent = false;
  String _verificationId = '';

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    _emailController.dispose();
    _emailOtpController.dispose();
    _phoneFocusNode.dispose();
    _phoneOtpFocusNode.dispose();
    _emailFocusNode.dispose();
    _emailOtpFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              ButtonSegment(
                value: AuthLoginMethod.google,
                icon: Icon(Icons.account_circle_outlined),
                label: Text('Gmail'),
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
          if (_method == AuthLoginMethod.phone) ...[
            TextField(
              key: const ValueKey('phone-login-field'),
              controller: _phoneController,
              focusNode: _phoneFocusNode,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Phone number',
                hintText: '+91 98765 43210',
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
                decoration: const InputDecoration(
                  labelText: 'Enter OTP',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
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
                decoration: const InputDecoration(
                  labelText: 'Enter email OTP',
                  helperText: 'Check your inbox for the 6-digit code.',
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              ),
            ],
          ] else
            _AuthNotice(
              title: widget.googleTitle,
              message: widget.googleMessage,
            ),
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
        ],
      ),
    );
  }

  void _switchMethod(AuthLoginMethod method) {
    if (method == _method) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _method = method;
      _phoneOtpSent = false;
      _emailOtpSent = false;
      _verificationId = '';
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
        case AuthLoginMethod.google:
          FocusManager.instance.primaryFocus?.unfocus();
      }
    });
  }

  IconData get _buttonIcon {
    return switch (_method) {
      AuthLoginMethod.phone => Icons.sms_outlined,
      AuthLoginMethod.email => Icons.mark_email_unread_outlined,
      AuthLoginMethod.google => Icons.account_circle_outlined,
    };
  }

  String get _buttonLabel {
    return switch (_method) {
      AuthLoginMethod.phone =>
        _phoneOtpSent ? 'Verify phone OTP' : 'Send phone OTP',
      AuthLoginMethod.email =>
        _emailOtpSent ? 'Verify email OTP' : 'Send email OTP',
      AuthLoginMethod.google => 'Continue with Gmail',
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
        case AuthLoginMethod.google:
          await _loginWithGoogle(appState);
          widget.onLoggedIn?.call();
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

  Future<void> _submitPhone(AppState appState) async {
    final phone = _phoneController.text.trim();
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
      _showSnack('OTP sent to ${appState.normalizePhone(phone)}');
      return;
    }
    await _loginWithPhone(appState);
    widget.onLoggedIn?.call();
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
    await _loginWithEmail(appState);
    widget.onLoggedIn?.call();
  }

  Future<void> _loginWithPhone(AppState appState) {
    final phone = _phoneController.text.trim();
    final otp = _otpController.text.trim();
    return switch (widget.role) {
      UserRole.customer => appState.loginCustomerWithPhone(
        phone: phone,
        verificationId: _verificationId,
        smsCode: otp,
      ),
      UserRole.owner => appState.loginOwnerWithPhone(
        phone: phone,
        verificationId: _verificationId,
        smsCode: otp,
      ),
      UserRole.barber => appState.loginBarberWithPhone(
        phone: phone,
        verificationId: _verificationId,
        smsCode: otp,
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
      UserRole.barber => appState.loginBarberWithEmail(
        name: '',
        email: email,
        emailLink: otp,
      ),
    };
  }

  Future<void> _loginWithGoogle(AppState appState) {
    return switch (widget.role) {
      UserRole.customer => appState.loginCustomerWithGmail(name: '', email: ''),
      UserRole.owner => appState.loginOwnerWithGmail(name: '', email: ''),
      UserRole.barber => appState.loginBarberWithGmail(name: '', email: ''),
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
    final message = error.toString();
    if (message.contains('firebase_functions/permission-denied') ||
        message.contains('PERMISSION_DENIED')) {
      return 'Email OTP is blocked by Firebase app verification. Please install the latest build and make sure this Play Store app is registered in Firebase App Check.';
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
      return 'Phone OTP is blocked by Firebase app verification. Add the Play app-signing SHA certificate in Firebase, wait a few minutes, then try again.';
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

class _AuthNotice extends StatelessWidget {
  final String title;
  final String message;

  const _AuthNotice({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          const SoftIconBox(
            icon: Icons.account_circle_outlined,
            color: AppColors.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
