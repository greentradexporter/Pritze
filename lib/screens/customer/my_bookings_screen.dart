import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/status_chip.dart';
import 'salon_booking_screen.dart';

class MyBookingsScreen extends StatelessWidget {
  const MyBookingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final bookings = appState.customerBookings
        .where((booking) => booking.status != BookingStatus.cancelled)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookings'),
        actions: [
          AccountOverflowMenu(
            role: UserRole.customer,
            canLogout: appState.hasActiveCustomerSession,
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(selectedIndex: 1),
      body: RefreshIndicator(
        onRefresh: appState.refresh,
        child: bookings.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 180),
                  EmptyState(
                    icon: Icons.receipt_long,
                    title: 'No bookings yet',
                    message:
                        'Book a service from Discover and your appointments will appear here.',
                  ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                children: [
                  AppHeroHeader(
                    eyebrow: 'Appointments',
                    title: 'Your grooming timeline',
                    subtitle: appState.activeCustomerContact == null
                        ? 'Track booking status from request to completion.'
                        : 'Showing bookings for ${appState.activeCustomerContact}.',
                    icon: Icons.receipt_long,
                  ),
                  const SizedBox(height: 22),
                  const SectionHeader(title: 'Bookings'),
                  const SizedBox(height: 10),
                  for (final booking in bookings) ...[
                    _BookingCard(booking: booking),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  final Booking booking;

  const _BookingCard({required this.booking});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);
    final canCancel =
        booking.status == BookingStatus.pending ||
        booking.status == BookingStatus.confirmed;
    final canReschedule = canCancel;
    final canLeaveFeedback = booking.status == BookingStatus.completed;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SoftIconBox(
                icon: Icons.event_available,
                color: _statusColor(booking.status),
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      salon?.name ?? 'Salon',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      service?.name ??
                          (booking.serviceName.isEmpty
                              ? 'Service'
                              : booking.serviceName),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              StatusChip(status: booking.status),
            ],
          ),
          const SizedBox(height: 16),
          _DetailRow(
            icon: Icons.schedule,
            label:
                '${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}',
          ),
          const SizedBox(height: 9),
          _DetailRow(
            icon: Icons.badge,
            label: barber?.name ?? 'Assigned barber',
          ),
          if (canCancel || canReschedule || canLeaveFeedback) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canReschedule)
                  OutlinedButton.icon(
                    onPressed: () => _reschedule(context, booking),
                    icon: const Icon(Icons.event_repeat_outlined),
                    label: const Text('Reschedule'),
                  ),
                if (canLeaveFeedback)
                  OutlinedButton.icon(
                    onPressed: () => _showFeedbackDialog(context, booking),
                    icon: const Icon(Icons.star_border),
                    label: const Text('Feedback'),
                  ),
                if (canCancel)
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await appState.updateBookingStatus(
                          booking.id,
                          BookingStatus.cancelled,
                        );
                      } catch (error) {
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Cancel failed: $error')),
                        );
                      }
                    },
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _reschedule(BuildContext context, Booking booking) async {
    try {
      await AppStateScope.read(
        context,
      ).updateBookingStatus(booking.id, BookingStatus.cancelled);
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SalonBookingScreen(
            salonId: booking.salonId,
            serviceId: booking.serviceId,
            initialBarberId: booking.barberId,
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reschedule failed: $error')));
    }
  }

  void _showFeedbackDialog(BuildContext context, Booking booking) {
    final controller = TextEditingController();
    var rating = 5;
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text(
                'How was your visit?',
                textAlign: TextAlign.center,
              ),
              actionsAlignment: MainAxisAlignment.center,
              actionsOverflowDirection: VerticalDirection.down,
              actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var index = 1; index <= 5; index++)
                        IconButton(
                          onPressed: () => setDialogState(() => rating = index),
                          icon: Icon(
                            index <= rating ? Icons.star : Icons.star_border,
                            color: AppColors.amber,
                          ),
                          tooltip: '$index stars',
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Feedback',
                      prefixIcon: Icon(Icons.rate_review_outlined),
                    ),
                  ),
                ],
              ),
              actions: [
                SizedBox(
                  width: 220,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Thanks for the $rating-star feedback.',
                          ),
                        ),
                      );
                    },
                    child: const Text('Submit'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _statusColor(BookingStatus status) {
    switch (status) {
      case BookingStatus.pending:
        return AppColors.amber;
      case BookingStatus.confirmed:
        return AppColors.goldDeep;
      case BookingStatus.inProgress:
        return AppColors.primary;
      case BookingStatus.completed:
        return AppColors.success;
      case BookingStatus.cancelled:
        return AppColors.coral;
    }
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DetailRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
