import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../services/android_phone_hint.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../screens/referrals/referral_onboarding_screen.dart';
import 'app_ui.dart';
import 'app_error_dialog.dart';

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
  bool _customerNameRequired = false;
  bool _customerGooglePhoneRequired = false;
  String? _phoneValidationMessage;
  bool _emailOtpSent = false;
  String _verificationId = '';
  Timer? _resendTimer;
  int _resendSeconds = 0;
  AppState? _subscribedAppState;
  StreamSubscription<String>? _autoVerificationSubscription;
  bool _isAutoCompletingPhoneOtp = false;
  bool _isPickingPhoneNumber = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = AppStateScope.maybeRead(context);
    if (identical(appState, _subscribedAppState)) {
      return;
    }
    unawaited(_autoVerificationSubscription?.cancel());
    _subscribedAppState = appState;
    _autoVerificationSubscription = appState?.autoVerifiedPhoneNumbers.listen(
      _handleAutoVerifiedPhone,
    );
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    unawaited(_autoVerificationSubscription?.cancel());
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
    final customerLogin = widget.role == UserRole.customer;
    final content = AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!customerLogin) ...[
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
            TextField(
              key: const ValueKey('phone-login-field'),
              controller: _phoneController,
              focusNode: _phoneFocusNode,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                IndianMobileNumberFormatter(
                  onTooLong: () => _setPhoneValidation(
                    'Indian mobile numbers contain exactly 10 digits.',
                  ),
                ),
              ],
              onChanged: (value) {
                if (value.length == 10 && _phoneValidationMessage != null) {
                  setState(() => _phoneValidationMessage = null);
                }
              },
              textInputAction: TextInputAction.next,
              readOnly: _phoneOtpSent,
              autofillHints: const [
                AutofillHints.telephoneNumberDevice,
                AutofillHints.telephoneNumber,
              ],
              onSubmitted: (_) {
                if (!_phoneOtpSent && !_isSubmitting) {
                  _submit();
                }
              },
              decoration: InputDecoration(
                labelText: 'Phone number',
                hintText: '10-digit mobile number',
                helperText: _customerNameRequired
                    ? 'Phone verified. Enter your name once to create the account.'
                    : _customerGooglePhoneRequired
                    ? 'Add your mobile number. No phone OTP is required.'
                    : widget.phoneHelperText ?? 'We will send an OTP.',
                errorText: _phoneValidationMessage,
                prefixIcon: const _PhonePrefix(),
              ),
            ),
            if (!_phoneOtpSent && !_customerNameRequired) ...[
              Align(
                alignment: Alignment.center,
                child: TextButton.icon(
                  key: const ValueKey('suggest-phone-number-button'),
                  onPressed: _isSubmitting || _isPickingPhoneNumber
                      ? null
                      : _pickDevicePhoneNumber,
                  icon: _isPickingPhoneNumber
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sim_card_outlined, size: 18),
                  label: const Text('Use number from this phone'),
                ),
              ),
            ],
            if (customerLogin && _customerNameRequired) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('customer-name-field'),
                controller: _nameController,
                focusNode: _nameFocusNode,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.name],
                onSubmitted: (_) {
                  if (!_isSubmitting) {
                    _submit();
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  hintText: 'Enter your full name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('change-phone-number-button'),
                  onPressed: _isSubmitting ? null : _resetPhoneOtp,
                  child: const Text('Change number'),
                ),
              ),
            ] else if (_phoneOtpSent) ...[
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
            if (_customerGooglePhoneRequired) ...[
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('cancel-customer-gmail-button'),
                onPressed: _isSubmitting ? null : _cancelCustomerGoogleLogin,
                child: const Text('Use another login method'),
              ),
            ],
          ] else if (_method == AuthLoginMethod.email) ...[
            TextField(
              key: const ValueKey('email-login-field'),
              controller: _emailController,
              focusNode: _emailFocusNode,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              readOnly: _emailOtpSent,
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
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('change-email-button'),
                    onPressed: _isSubmitting ? null : _resetEmailOtp,
                    child: const Text('Change email'),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    key: const ValueKey('resend-email-otp-button'),
                    onPressed: _isSubmitting || _resendSeconds > 0
                        ? null
                        : _resendEmailOtp,
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
          if (widget.role != UserRole.barber &&
              !_customerGooglePhoneRequired) ...[
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
      _customerNameRequired = false;
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
    if (_customerNameRequired) {
      return Icons.person_add_alt_1_outlined;
    }
    if (_customerGooglePhoneRequired) {
      return Icons.save_outlined;
    }
    return switch (_method) {
      AuthLoginMethod.phone => Icons.sms_outlined,
      AuthLoginMethod.email => Icons.mark_email_unread_outlined,
    };
  }

  String get _buttonLabel {
    if (_customerNameRequired) {
      return 'Create customer account';
    }
    return switch (_method) {
      AuthLoginMethod.phone =>
        _phoneOtpSent
            ? 'Verify and sign in'
            : _customerGooglePhoneRequired
            ? 'Save phone and continue'
            : 'Continue',
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
      await _showLoginError(error);
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
      await _finishLogin();
    } on CustomerPhoneRequiredException {
      if (!mounted) {
        return;
      }
      setState(() {
        _method = AuthLoginMethod.phone;
        _customerGooglePhoneRequired = true;
        _phoneOtpSent = false;
        _customerNameRequired = false;
        _verificationId = '';
        _otpController.clear();
      });
      _showSnack('Gmail connected. Add your 10-digit mobile number.');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _phoneFocusNode.requestFocus();
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      await _showLoginError(error);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _submitPhone(AppState appState) async {
    final phoneDigits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    if (phoneDigits.isEmpty) {
      _setPhoneValidation('Enter your phone number');
      return;
    }
    if (phoneDigits.length != 10) {
      _setPhoneValidation(
        phoneDigits.length == 9
            ? 'Enter one more digit. Mobile number must contain 10 digits.'
            : 'Enter a valid 10-digit Indian mobile number.',
      );
      _phoneFocusNode.requestFocus();
      return;
    }
    if (_phoneValidationMessage != null) {
      setState(() => _phoneValidationMessage = null);
    }
    final phone = '+91$phoneDigits';
    if (_customerGooglePhoneRequired) {
      await appState.completeCustomerGmailPhone(phone: phone);
      if (mounted) {
        setState(() => _customerGooglePhoneRequired = false);
      }
      await _finishLogin();
      return;
    }
    if (_customerNameRequired) {
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        _showSnack('Enter your name to create your customer account');
        _nameFocusNode.requestFocus();
        return;
      }
      await appState.completeCustomerPhoneRegistration(
        name: name,
        phone: phone,
      );
      await _finishLogin();
      return;
    }
    if (!_phoneOtpSent) {
      final verificationId = await appState.sendPhoneOtp(phone: phone);
      if (!mounted) {
        return;
      }
      if (verificationId.isEmpty) {
        await _completePhoneOtpLogin(appState);
        return;
      }
      setState(() {
        _verificationId = verificationId;
        _phoneOtpSent = true;
      });
      if (appState.isPhoneAutoVerified(phone)) {
        _verificationId = '';
        await _completePhoneOtpLogin(appState);
        return;
      }
      _startResendCountdown();
      _showSnack(
        'OTP requested for ${appState.normalizePhone(phone)}. If it does not '
        'arrive, resend it or change the number.',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _phoneOtpFocusNode.requestFocus();
        }
      });
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_otpController.text.trim())) {
      _showSnack('Enter the latest 6-digit OTP');
      _phoneOtpFocusNode.requestFocus();
      return;
    }
    await _completePhoneOtpLogin(appState);
  }

  Future<void> _completePhoneOtpLogin(AppState appState) async {
    try {
      await _loginWithPhone(appState);
      await _finishLogin();
    } on CustomerNameRequiredException {
      if (!mounted) {
        return;
      }
      _resendTimer?.cancel();
      _otpController.clear();
      setState(() {
        _phoneOtpSent = true;
        _customerNameRequired = true;
        _resendSeconds = 0;
      });
      _showSnack('Phone verified. Enter your name once to create the account.');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _nameFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _handleAutoVerifiedPhone(String phone) async {
    if (!mounted ||
        _isAutoCompletingPhoneOtp ||
        !_phoneOtpSent ||
        _customerNameRequired ||
        _customerGooglePhoneRequired) {
      return;
    }
    final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10 || phone != '+91$digits') {
      return;
    }
    _isAutoCompletingPhoneOtp = true;
    setState(() {
      _verificationId = '';
      _isSubmitting = true;
    });
    try {
      await _completePhoneOtpLogin(
        _subscribedAppState ?? AppStateScope.read(context),
      );
    } catch (error) {
      if (mounted) {
        await _showLoginError(error);
      }
    } finally {
      _isAutoCompletingPhoneOtp = false;
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _pickDevicePhoneNumber() async {
    setState(() => _isPickingPhoneNumber = true);
    try {
      final digits = await DevicePhoneHint.request();
      if (!mounted) {
        return;
      }
      if (digits == null) {
        _showSnack(
          'No phone number was selected. You can enter the number manually.',
        );
        return;
      }
      _phoneController.value = TextEditingValue(
        text: digits,
        selection: TextSelection.collapsed(offset: digits.length),
      );
      setState(() => _phoneValidationMessage = null);
      _phoneFocusNode.requestFocus();
    } catch (error) {
      if (mounted) {
        _showSnack('Could not read a phone number from this device.');
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingPhoneNumber = false);
      }
    }
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
        await _completePhoneOtpLogin(appState);
        return;
      }
      _startResendCountdown();
      _showSnack(
        'A new OTP was sent to ${appState.normalizePhone(_phoneController.text)}',
      );
      _phoneOtpFocusNode.requestFocus();
    } catch (error) {
      if (mounted) {
        await _showLoginError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _startResendCountdown({int seconds = 30}) {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = seconds);
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
      _customerNameRequired = false;
      _verificationId = '';
      _resendSeconds = 0;
      _otpController.clear();
      _nameController.clear();
      _phoneValidationMessage = null;
    });
    if (!_customerGooglePhoneRequired) {
      unawaited(AppStateScope.read(context).cancelPendingCustomerPhoneLogin());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _phoneFocusNode.requestFocus();
      }
    });
  }

  Future<void> _cancelCustomerGoogleLogin() async {
    await AppStateScope.read(context).cancelPendingCustomerGmailLogin();
    if (!mounted) {
      return;
    }
    _resendTimer?.cancel();
    setState(() {
      _customerGooglePhoneRequired = false;
      _phoneOtpSent = false;
      _verificationId = '';
      _resendSeconds = 0;
      _phoneController.clear();
      _otpController.clear();
      _phoneValidationMessage = null;
    });
    _phoneFocusNode.requestFocus();
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
      _startResendCountdown(seconds: 45);
      _showSnack('Email OTP requested. Enter the latest code to continue.');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _emailOtpFocusNode.requestFocus();
        }
      });
      return;
    }
    final otp = _emailOtpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
      _showSnack('Enter the 6-digit code from your email');
      _emailOtpFocusNode.requestFocus();
      return;
    }
    await _loginWithEmail(appState);
    await _finishLogin();
  }

  Future<void> _finishLogin() async {
    if (!mounted) {
      return;
    }
    await showReferralOnboardingIfRequired(context);
    if (mounted) {
      widget.onLoggedIn?.call();
    }
  }

  Future<void> _resendEmailOtp() async {
    if (_isSubmitting || _resendSeconds > 0) {
      return;
    }
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      await appState.sendEmailOtp(email: _emailController.text.trim());
      if (!mounted) {
        return;
      }
      _emailOtpController.clear();
      _startResendCountdown(seconds: 45);
      _showSnack('A new email OTP was requested. Use only the latest code.');
      _emailOtpFocusNode.requestFocus();
    } catch (error) {
      if (mounted) {
        await _showLoginError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _resetEmailOtp() {
    _resendTimer?.cancel();
    setState(() {
      _emailOtpSent = false;
      _resendSeconds = 0;
      _emailOtpController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _emailFocusNode.requestFocus();
      }
    });
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

  void _setPhoneValidation(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _phoneValidationMessage = message);
    _showSnack(message);
  }

  Future<void> _showLoginError(Object error) {
    return showAppErrorDialog(context, friendlyAuthenticationError(error));
  }
}

class _PhonePrefix extends StatelessWidget {
  const _PhonePrefix();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 78,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.phone_android_outlined,
            size: 21,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '+91',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class IndianMobileNumberFormatter extends TextInputFormatter {
  final VoidCallback onTooLong;

  IndianMobileNumberFormatter({required this.onTooLong});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    }
    if (digits.length > 10) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onTooLong());
      digits = digits.substring(0, 10);
    }
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}
