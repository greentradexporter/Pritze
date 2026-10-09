import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../screens/customer/my_bookings_screen.dart';
import '../screens/customer/customer_completion_receipt_screen.dart';
import '../screens/customer/customer_home_screen.dart';
import '../screens/customer/salon_booking_screen.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'booking_status_timeline.dart';

const customerAutomaticPopupLifetime = Duration(minutes: 2);

bool isCustomerAutomaticPopupFresh(DateTime occurredAt, DateTime now) {
  final age = now.difference(occurredAt);
  // A small device/server clock skew must not hide a genuinely new event.
  return age.isNegative || age <= customerAutomaticPopupLifetime;
}

class CustomerBookingConfirmationGate extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  const CustomerBookingConfirmationGate({
    super.key,
    required this.child,
    this.navigatorKey,
  });

  @override
  State<CustomerBookingConfirmationGate> createState() =>
      _CustomerBookingConfirmationGateState();
}

class _CustomerBookingConfirmationGateState
    extends State<CustomerBookingConfirmationGate> {
  bool _isShowingConfirmation = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    if (appState.activeRole != UserRole.customer) {
      return widget.child;
    }
    final now = DateTime.now();
    final requestedCompletionId = appState.pendingCompletionReceiptBookingId;
    final requestedCompletedBooking = requestedCompletionId.isNotEmpty
        ? appState.customerBookings
              .where(
                (item) =>
                    item.id == requestedCompletionId &&
                    item.status == BookingStatus.completed &&
                    item.completedAt != null &&
                    isCustomerAutomaticPopupFresh(item.completedAt!, now),
              )
              .firstOrNull
        : null;
    final completedBooking =
        requestedCompletedBooking ??
        appState.customerBookings
            .where(
              (item) =>
                  item.status == BookingStatus.completed &&
                  item.completedAt != null &&
                  isCustomerAutomaticPopupFresh(item.completedAt!, now) &&
                  !appState.hasSeenNotification(
                    UserRole.customer,
                    _completionKey(item),
                  ),
            )
            .firstOrNull;
    final outcomeBooking = appState.customerBookings
        .where(
          (item) =>
              _isCustomerVisibleOutcome(item) &&
              isCustomerAutomaticPopupFresh(_outcomeAt(item), now) &&
              !_hasSeenOutcome(appState, item),
        )
        .firstOrNull;
    final booking = appState.customerBookings
        .where(
          (item) =>
              item.isInstant &&
              item.status == BookingStatus.confirmed &&
              item.acceptedAt != null &&
              isCustomerAutomaticPopupFresh(item.acceptedAt!, now) &&
              !appState.hasSeenNotification(
                UserRole.customer,
                _confirmationKey(item),
              ),
        )
        .firstOrNull;

    if (completedBooking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          _isShowingConfirmation = false;
          return;
        }
        var presented = false;
        try {
          await _showCompletionReceipt(completedBooking);
          presented = true;
        } finally {
          if (presented) {
            appState.markNotificationsSeen(UserRole.customer, [
              _completionKey(completedBooking),
            ]);
            appState.clearPendingCompletionReceipt(completedBooking.id);
          }
          if (mounted) setState(() => _isShowingConfirmation = false);
        }
      });
    } else if (outcomeBooking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          _isShowingConfirmation = false;
          return;
        }
        var presented = false;
        try {
          await _showOutcome(outcomeBooking);
          presented = true;
        } finally {
          if (presented) {
            appState.markNotificationsSeen(
              UserRole.customer,
              _outcomeKeys(outcomeBooking),
            );
          }
          if (mounted) setState(() => _isShowingConfirmation = false);
        }
      });
    } else if (booking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          _isShowingConfirmation = false;
          return;
        }
        var presented = false;
        try {
          await _showConfirmation(booking);
          presented = true;
        } finally {
          if (presented) {
            appState.markNotificationsSeen(UserRole.customer, [
              _confirmationKey(booking),
            ]);
          }
          if (mounted) setState(() => _isShowingConfirmation = false);
        }
      });
    }
    return widget.child;
  }

  Future<void> _showCompletionReceipt(Booking booking) async {
    final navigatorContext = _navigatorContext;
    if (navigatorContext == null) return;
    await showGeneralDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      barrierLabel: 'Service completed payment summary',
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) =>
          CustomerCompletionReceiptScreen(booking: booking, dialogMode: true),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  Future<void> _showConfirmation(Booking booking) async {
    final appState = AppStateScope.read(context);
    final salon = appState.getSalon(booking.salonId);
    final navigatorContext = _navigatorContext;
    if (navigatorContext == null) return;
    await showGeneralDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      barrierLabel: 'Booking confirmed',
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Material(
          color: AppColors.surface,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: ListView(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(24),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle,
                      size: 56,
                      color: AppColors.success,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Booking confirmed',
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${salon?.name ?? 'The salon'} accepted your '
                    '${booking.resolvedServiceName()} booking.',
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ConfirmationDetail(
                          icon: Icons.storefront_outlined,
                          label: salon?.name ?? 'Salon',
                        ),
                        const SizedBox(height: 12),
                        _ConfirmationDetail(
                          icon: Icons.content_cut_outlined,
                          label: booking.resolvedServiceName(),
                        ),
                        const SizedBox(height: 12),
                        _ConfirmationDetail(
                          icon: Icons.schedule_outlined,
                          label:
                              '${appState.formatDate(booking.start)}, '
                              '${appState.formatTime(booking.start)}',
                        ),
                        if (booking.isInstant) ...[
                          const SizedBox(height: 12),
                          _ConfirmationDetail(
                            icon: Icons.directions_walk_outlined,
                            label:
                                'Reach within '
                                '${booking.customerArrivalMinutes} minutes',
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  BookingStatusTimeline(
                    status: booking.status,
                    isInstant: booking.isInstant,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pushReplacement(
                          MaterialPageRoute<void>(
                            builder: (_) => const MyBookingsScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('View booking'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  Future<void> _showOutcome(Booking booking) async {
    final appState = AppStateScope.read(context);
    final salon = appState.getSalon(booking.salonId);
    final isNoResponse = booking.cancelledBy == 'system';
    final isRejected = booking.status == BookingStatus.rejected;
    final title = isNoResponse
        ? 'No response from salon'
        : isRejected
        ? 'Salon is busy'
        : 'Booking cancelled';
    final message = isNoResponse
        ? 'Oops, looks like the salon is busy. Try again or see other nearby salons.'
        : isRejected
        ? '${salon?.name ?? 'The salon'} is busy right now. Try a different salon.'
        : '${salon?.name ?? 'The salon'} cancelled your booking.';
    final accent = isNoResponse ? AppColors.amber : AppColors.coral;
    final icon = isNoResponse
        ? Icons.hourglass_empty_rounded
        : isRejected
        ? Icons.block_rounded
        : Icons.event_busy_rounded;
    // Being turned away does not mean the salon has nothing left today, so
    // offer its next slot rather than sending the customer away empty handed.
    final nextSlot = appState
        .slotsForService(booking.salonId, booking.serviceId)
        .firstOrNull;
    final navigatorContext = _navigatorContext;
    if (navigatorContext == null) return;

    await showGeneralDialog<void>(
      context: navigatorContext,
      barrierDismissible: false,
      barrierLabel: title,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Material(
          color: AppColors.surface,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: ListView(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(24),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 50, color: accent),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.canvas,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ConfirmationDetail(
                          icon: Icons.storefront_outlined,
                          label: salon?.name ?? 'Salon',
                        ),
                        const SizedBox(height: 12),
                        _ConfirmationDetail(
                          icon: Icons.content_cut_outlined,
                          label: booking.resolvedServiceName(),
                        ),
                        if (booking.cancellationReason.trim().isNotEmpty &&
                            !isNoResponse) ...[
                          const SizedBox(height: 12),
                          _ConfirmationDetail(
                            icon: Icons.info_outline_rounded,
                            label: booking.cancellationReason.trim(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (nextSlot != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('rejected-book-later-slot'),
                        onPressed: () {
                          Navigator.of(dialogContext).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => SalonBookingScreen(
                                salonId: booking.salonId,
                                serviceId: booking.serviceId,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.event_available_outlined),
                        label: Text(
                          'Book a slot from '
                          '${appState.formatTime(nextSlot.start)}',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity,
                    // Steps down to secondary only when a slot is offered
                    // above it, so the dialog always has one primary action.
                    child: _FindAnotherSalonButton(
                      isPrimary: nextSlot == null,
                      onPressed: () {
                        Navigator.of(dialogContext).pushAndRemoveUntil(
                          MaterialPageRoute<void>(
                            builder: (_) => const CustomerHomeScreen(),
                          ),
                          (_) => false,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pushReplacement(
                          MaterialPageRoute<void>(
                            builder: (_) => const MyBookingsScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('View bookings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  BuildContext? get _navigatorContext =>
      widget.navigatorKey?.currentContext ??
      (Navigator.maybeOf(context)?.context);
}

class _FindAnotherSalonButton extends StatelessWidget {
  final bool isPrimary;
  final VoidCallback onPressed;

  const _FindAnotherSalonButton({
    required this.isPrimary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.search_rounded);
    const label = Text('Find another salon');
    return isPrimary
        ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label)
        : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label);
  }
}

String _confirmationKey(Booking booking) =>
    'booking-confirmed:${booking.id}:${booking.acceptedAt?.millisecondsSinceEpoch}';

String _completionKey(Booking booking) =>
    'booking-completed-receipt:${booking.id}:${booking.completedAt?.millisecondsSinceEpoch}';

bool _isCustomerVisibleOutcome(Booking booking) {
  if (booking.status == BookingStatus.rejected) {
    return booking.rejectedAt != null;
  }
  return booking.status == BookingStatus.cancelled &&
      booking.cancelledAt != null &&
      booking.cancelledBy != 'customer';
}

DateTime _outcomeAt(Booking booking) {
  return booking.status == BookingStatus.rejected
      ? booking.rejectedAt!
      : booking.cancelledAt!;
}

Iterable<String> _outcomeKeys(Booking booking) sync* {
  if (booking.cancelledBy == 'system') {
    // Keep timeout delivery stable while the client-side deadline projection
    // is replaced by the server cancellation timestamp.
    yield 'booking-unanswered:${booking.id}';
    if (booking.cancelledAt != null) {
      yield 'booking-unanswered:${booking.id}:${booking.cancelledAt!.millisecondsSinceEpoch}';
    }
    return;
  }
  final outcome = booking.status == BookingStatus.rejected
      ? 'rejected'
      : 'cancelled';
  yield 'booking-$outcome:${booking.id}:${_outcomeAt(booking).millisecondsSinceEpoch}';
}

bool _hasSeenOutcome(AppState appState, Booking booking) {
  return _outcomeKeys(
    booking,
  ).any((key) => appState.hasSeenNotification(UserRole.customer, key));
}

class _ConfirmationDetail extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ConfirmationDetail({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
