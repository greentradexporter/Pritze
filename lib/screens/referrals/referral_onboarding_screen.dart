import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_models.dart';
import '../../services/referral_link_service.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_error_dialog.dart';

class ReferralOnboardingScreen extends StatefulWidget {
  final bool dialogStyle;

  const ReferralOnboardingScreen({super.key, this.dialogStyle = false});

  @override
  State<ReferralOnboardingScreen> createState() =>
      _ReferralOnboardingScreenState();
}

class _ReferralOnboardingScreenState extends State<ReferralOnboardingScreen> {
  final _codeController = TextEditingController();
  bool _enteringCode = false;
  bool _submitting = false;
  bool _pendingReferralLoaded = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_pendingReferralLoaded && _codeController.text.isEmpty) {
      _pendingReferralLoaded = true;
      _loadPendingReferral();
    }
  }

  Future<void> _loadPendingReferral() async {
    final code = await ReferralLinkService.pendingCodeFor(
      AppStateScope.read(context).activeRole,
    );
    if (!mounted || code.isEmpty || _codeController.text.isNotEmpty) {
      return;
    }
    setState(() {
      _codeController.text = code;
      _enteringCode = true;
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final role = appState.activeRole;
    final content = PopScope<void>(
      canPop: !appState.referralOnboardingRequired,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SoftIconBox(
                icon: Icons.redeem_rounded,
                color: AppColors.primary,
                size: 56,
              ),
              const SizedBox(height: 14),
              Text(
                'Do you have a referral code?',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 7),
              Text(
                role == UserRole.owner
                    ? 'Enter a salon referral code. This is asked only once while creating your salon-owner account.'
                    : 'Enter a customer referral code. This is asked only once while creating your account.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (_enteringCode) ...[
                TextField(
                  key: const ValueKey('referral-onboarding-code'),
                  controller: _codeController,
                  enabled: !_submitting,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 6,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(6),
                    _UpperCaseTextFormatter(),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Referral code',
                    hintText: 'Example: A7B2C9',
                    errorText: _error,
                    prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  ),
                  onSubmitted: (_) => _submitCode(),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('apply-referral-code'),
                  onPressed: _submitting ? null : _submitCode,
                  child: _submitting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Apply code and continue'),
                ),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                          _enteringCode = false;
                          _error = null;
                          _codeController.clear();
                        }),
                  child: const Text('Back'),
                ),
              ] else ...[
                FilledButton.icon(
                  key: const ValueKey('enter-referral-code'),
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _enteringCode = true),
                  icon: const Icon(Icons.keyboard_alt_outlined),
                  label: const Text('Put referral code'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  key: const ValueKey('skip-referral-code'),
                  onPressed: _submitting ? null : _skip,
                  child: const Text("I don't have a referral code"),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.dialogStyle) {
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: content,
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: GlassCard(child: content),
          ),
        ),
      ),
    );
  }

  Future<void> _submitCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (!RegExp(r'^(?=.*[A-Z])(?=.*\d)[A-Z\d]{6}$').hasMatch(code)) {
      setState(
        () => _error = 'Enter all 6 characters, including letters and numbers.',
      );
      return;
    }
    await _complete(code);
  }

  Future<void> _skip() => _complete('');

  Future<void> _complete(String code) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AppStateScope.read(
        context,
      ).completeReferralOnboarding(referralCode: code);
      await ReferralLinkService.clearPendingCode();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        await showAppErrorDialog(context, friendlyOnboardingError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

Future<void> showReferralOnboardingIfRequired(BuildContext context) async {
  final state = AppStateScope.read(context);
  if (!state.referralOnboardingRequired) {
    return;
  }
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ReferralOnboardingScreen(dialogStyle: true),
  );
}
