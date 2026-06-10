import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/status_chip.dart';

class MyBookingsScreen extends StatelessWidget {
  const MyBookingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final bookings = appState.customerBookings;

    return Scaffold(
      bottomNavigationBar: const AppBottomNav(selectedIndex: 1),
      body: SafeArea(
        child: bookings.isEmpty
            ? const EmptyState(
                icon: Icons.receipt_long,
                title: 'No bookings yet',
                message:
                    'Book a service from Discover and your appointments will appear here.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                children: [
                  AppHeroHeader(
                    eyebrow: 'Appointments',
                    title: 'Your grooming timeline',
                    subtitle: appState.activeCustomerPhone == null
                        ? 'Track booking status from request to completion.'
                        : 'Showing bookings for ${appState.activeCustomerPhone}.',
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
                      service?.name ?? 'Service',
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
          if (canCancel) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
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
                label: const Text('Cancel booking'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _statusColor(BookingStatus status) {
    switch (status) {
      case BookingStatus.pending:
        return AppColors.amber;
      case BookingStatus.confirmed:
        return AppColors.blue;
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
