import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';

/// Gives a signed-in salon owner an immediate decision surface while Pritze is
/// open on an iPhone. iOS keeps notification actions behind an expansion
/// gesture, so this is deliberately an in-app, iOS-only complement to APNs.
class IosOwnerBookingRequestGate extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  const IosOwnerBookingRequestGate({
    super.key,
    required this.child,
    this.navigatorKey,
  });

  @override
  State<IosOwnerBookingRequestGate> createState() =>
      _IosOwnerBookingRequestGateState();
}

class _IosOwnerBookingRequestGateState
    extends State<IosOwnerBookingRequestGate> {
  bool _isPresenting = false;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return widget.child;
    }

    final appState = AppStateScope.watch(context);
    final booking = _pendingInstantBooking(appState);
    if (booking != null && !_isPresenting) {
      _isPresenting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          _isPresenting = false;
          return;
        }
        try {
          await _showBookingRequest(booking.id);
        } finally {
          if (mounted) {
            setState(() => _isPresenting = false);
          } else {
            _isPresenting = false;
          }
        }
      });
    }
    return widget.child;
  }

  Booking? _pendingInstantBooking(AppState appState) {
    if (appState.activeRole != UserRole.owner ||
        !appState.hasActiveOwnerSession ||
        appState.ownerSalonId.isEmpty) {
      return null;
    }
    final now = DateTime.now();
    final pending =
        appState
            .bookingsForSalon(appState.ownerSalonId)
            .where(
              (booking) =>
                  booking.isInstant &&
                  booking.status == BookingStatus.pending &&
                  now.isBefore(
                    booking.createdAt.add(instantBookingResponseTimeout),
                  ),
            )
            .toList()
          ..sort(
            (first, second) => first.createdAt.compareTo(second.createdAt),
          );
    return pending.firstOrNull;
  }

  Future<void> _showBookingRequest(String bookingId) {
    final navigatorContext =
        widget.navigatorKey?.currentContext ??
        Navigator.maybeOf(context)?.context;
    if (navigatorContext == null) return Future.value();
    return showGeneralDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      barrierLabel: 'Instant booking request',
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          _IosOwnerBookingRequestDialog(bookingId: bookingId),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }
}

class _IosOwnerBookingRequestDialog extends StatefulWidget {
  final String bookingId;

  const _IosOwnerBookingRequestDialog({required this.bookingId});

  @override
  State<_IosOwnerBookingRequestDialog> createState() =>
      _IosOwnerBookingRequestDialogState();
}

class _IosOwnerBookingRequestDialogState
    extends State<_IosOwnerBookingRequestDialog> {
  bool _isSaving = false;
  String? _error;
  bool _closeQueued = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final booking = appState
        .bookingsForSalon(appState.ownerSalonId)
        .where((item) => item.id == widget.bookingId)
        .firstOrNull;
    final isPending =
        booking != null &&
        booking.isInstant &&
        booking.status == BookingStatus.pending;
    if (!isPending) {
      _closeWhenSafe();
      return const SizedBox.shrink();
    }

    return PopScope(
      canPop: false,
      child: Material(
        color: AppColors.surface,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: AppColors.coral.withAlpha(24),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: AppColors.coral,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'New instant booking',
                  key: const ValueKey('ios-owner-booking-request-title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  '${booking.customerName} is waiting for your decision.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 26),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _BookingRequestDetail(
                        icon: Icons.content_cut_outlined,
                        label: booking.resolvedServiceName(),
                      ),
                      const SizedBox(height: 12),
                      _BookingRequestDetail(
                        icon: Icons.schedule_outlined,
                        label:
                            '${booking.customerArrivalMinutes} min customer ETA · ${booking.salonArrivalMinutes} min salon window',
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    key: const ValueKey('ios-owner-booking-accept'),
                    onPressed: _isSaving
                        ? null
                        : () => _respond(BookingStatus.confirmed),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(_isSaving ? 'Saving…' : 'Accept booking'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton.icon(
                    key: const ValueKey('ios-owner-booking-reject'),
                    onPressed: _isSaving
                        ? null
                        : () => _respond(BookingStatus.rejected),
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Reject booking'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _respond(BookingStatus status) async {
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await AppStateScope.read(
        context,
      ).updateBookingStatus(widget.bookingId, status);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _error = 'Could not save your decision. Please try again.';
        });
      }
    }
  }

  void _closeWhenSafe() {
    if (_closeQueued) return;
    _closeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }
}

class _BookingRequestDetail extends StatelessWidget {
  final IconData icon;
  final String label;

  const _BookingRequestDetail({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}
