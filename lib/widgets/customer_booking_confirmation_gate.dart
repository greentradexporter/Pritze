import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../screens/customer/my_bookings_screen.dart';
import '../screens/customer/customer_completion_receipt_screen.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'booking_status_timeline.dart';

class CustomerBookingConfirmationGate extends StatefulWidget {
  final Widget child;

  const CustomerBookingConfirmationGate({super.key, required this.child});

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
    final now = DateTime.now();
    final completedBooking = appState.customerBookings
        .where(
          (item) =>
              item.status == BookingStatus.completed &&
              item.completedAt != null &&
              now.difference(item.completedAt!).abs() <
                  const Duration(hours: 24) &&
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
              now.difference(_outcomeAt(item)).abs() <
                  const Duration(hours: 24) &&
              !appState.hasSeenNotification(
                UserRole.customer,
                _outcomeKey(item),
              ),
        )
        .firstOrNull;
    final booking = appState.customerBookings
        .where(
          (item) =>
              item.isInstant &&
              item.status == BookingStatus.confirmed &&
              item.acceptedAt != null &&
              now.difference(item.acceptedAt!).abs() <
                  const Duration(minutes: 20) &&
              !appState.hasSeenNotification(
                UserRole.customer,
                _confirmationKey(item),
              ),
        )
        .firstOrNull;

    if (completedBooking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        appState.markNotificationsSeen(UserRole.customer, [
          _completionKey(completedBooking),
        ]);
        _showCompletionReceipt(completedBooking);
      });
    } else if (outcomeBooking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        appState.markNotificationsSeen(UserRole.customer, [
          _outcomeKey(outcomeBooking),
        ]);
        _showOutcome(outcomeBooking);
      });
    } else if (booking != null && !_isShowingConfirmation) {
      _isShowingConfirmation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        appState.markNotificationsSeen(UserRole.customer, [
          _confirmationKey(booking),
        ]);
        _showConfirmation(booking);
      });
    }
    return widget.child;
  }

  Future<void> _showCompletionReceipt(Booking booking) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Service completed payment summary',
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) =>
          CustomerCompletionReceiptScreen(booking: booking, dialogMode: true),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    if (mounted) setState(() => _isShowingConfirmation = false);
  }

  Future<void> _showConfirmation(Booking booking) async {
    final appState = AppStateScope.read(context);
    final salon = appState.getSalon(booking.salonId);
    await showGeneralDialog<void>(
      context: context,
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
                        Navigator.pop(dialogContext);
                        Navigator.of(context).push(
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
    if (mounted) {
      setState(() => _isShowingConfirmation = false);
    }
  }

  Future<void> _showOutcome(Booking booking) async {
    final appState = AppStateScope.read(context);
    final salon = appState.getSalon(booking.salonId);
    final isNoResponse = booking.cancelledBy == 'system';
    final isRejected = booking.status == BookingStatus.rejected;
    final title = isNoResponse
        ? 'No response from salon'
        : isRejected
        ? 'Booking rejected'
        : 'Booking cancelled';
    final message = isNoResponse
        ? 'Oops, looks like the salon is busy. Try again or see other nearby salons.'
        : isRejected
        ? '${salon?.name ?? 'The salon'} could not accept your booking this time.'
        : '${salon?.name ?? 'The salon'} cancelled your booking.';
    final accent = isNoResponse ? AppColors.amber : AppColors.coral;
    final icon = isNoResponse
        ? Icons.hourglass_empty_rounded
        : isRejected
        ? Icons.block_rounded
        : Icons.event_busy_rounded;

    await showGeneralDialog<void>(
      context: context,
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
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.search_rounded),
                      label: const Text('Find another salon'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        Navigator.of(context).push(
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
    if (mounted) {
      setState(() => _isShowingConfirmation = false);
    }
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

String _outcomeKey(Booking booking) {
  final outcome = booking.status == BookingStatus.rejected
      ? 'rejected'
      : booking.cancelledBy == 'system'
      ? 'unanswered'
      : 'cancelled';
  return 'booking-$outcome:${booking.id}:${_outcomeAt(booking).millisecondsSinceEpoch}';
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
