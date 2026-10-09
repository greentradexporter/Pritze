import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state_scope.dart';
import 'app_error_dialog.dart';

Future<bool?> showOwnerPhoneLoginDialog(BuildContext context, String phone) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _OwnerPhoneLoginDialog(phone: phone),
    );

class _OwnerPhoneLoginDialog extends StatefulWidget {
  const _OwnerPhoneLoginDialog({required this.phone});
  final String phone;

  @override
  State<_OwnerPhoneLoginDialog> createState() => _OwnerPhoneLoginDialogState();
}

class _OwnerPhoneLoginDialogState extends State<_OwnerPhoneLoginDialog> {
  final _code = TextEditingController();
  String? _verificationId;
  String? _error;
  bool _busy = false;
  int _resendSeconds = 0;
  Timer? _cooldown;
  StreamSubscription<String>? _autoVerification;

  @override
  void dispose() {
    _code.dispose();
    _cooldown?.cancel();
    _autoVerification?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppStateScope.read(context);
    _autoVerification ??= state.autoVerifiedPhoneNumbers.listen((phone) {
      if (mounted && phone == widget.phone) {
        _verificationId = '';
        if (!_busy) _verify();
      }
    });
    try {
      final id = _verificationId == null
          ? await state.sendPhoneOtp(phone: widget.phone)
          : await state.resendPhoneOtp(phone: widget.phone);
      if (!mounted) return;
      setState(() {
        _verificationId = state.isPhoneAutoVerified(widget.phone) ? '' : id;
        _resendSeconds = 60;
      });
      _cooldown?.cancel();
      _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _resendSeconds <= 1) timer.cancel();
        if (mounted) {
          setState(() => _resendSeconds = (_resendSeconds - 1).clamp(0, 60));
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _verificationId == '') await _verify();
  }

  Future<void> _verify() async {
    if (_busy || _verificationId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppStateScope.read(context).linkOwnerPhoneLogin(
        phone: widget.phone,
        verificationId: _verificationId!,
        smsCode: _code.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Enable phone login'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Verify ${widget.phone} to sign in to this same salon with either email or phone.',
          ),
          if (_verificationId != null) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              key: const ValueKey('owner-phone-link-otp'),
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(labelText: '6-digit OTP'),
              onSubmitted: (_) => _verify(),
            ),
            TextButton(
              onPressed: _busy || _resendSeconds > 0 ? null : _send,
              child: Text(
                _resendSeconds > 0
                    ? 'Resend in ${_resendSeconds}s'
                    : 'Resend OTP',
              ),
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Later'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : _verificationId == null
            ? _send
            : _verify,
        child: Text(
          _busy
              ? 'Please wait...'
              : _verificationId == null
              ? 'Send OTP'
              : 'Verify and enable',
        ),
      ),
    ],
  );
}
