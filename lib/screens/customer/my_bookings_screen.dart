import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/status_chip.dart';
import 'salon_booking_screen.dart';

class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  CustomerBookingBucket _selectedBucket = CustomerBookingBucket.active;
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final now = DateTime.now();
    final allBookings = appState.customerBookings;
    final counts = {
      for (final bucket in CustomerBookingBucket.values)
        bucket: allBookings
            .where(
              (booking) =>
                  appState.customerBookingBucket(booking, now: now) == bucket,
            )
            .length,
    };
    final bookings =
        allBookings.where((booking) {
          return appState.customerBookingBucket(booking, now: now) ==
              _selectedBucket;
        }).toList()..sort((a, b) {
          if (_selectedBucket == CustomerBookingBucket.active) {
            return a.start.compareTo(b.start);
          }
          return b.start.compareTo(a.start);
        });

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
        child: allBookings.isEmpty
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
                  Row(
                    children: [
                      Expanded(
                        child: _BookingMetric(
                          value: '${counts[CustomerBookingBucket.active] ?? 0}',
                          label: 'Active',
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _BookingMetric(
                          value:
                              '${counts[CustomerBookingBucket.history] ?? 0}',
                          label: 'History',
                          color: AppColors.success,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _BookingMetric(
                          value:
                              '${counts[CustomerBookingBucket.cancelled] ?? 0}',
                          label: 'Closed',
                          color: AppColors.coral,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final bucket in CustomerBookingBucket.values) ...[
                          ChoiceChip(
                            selected: _selectedBucket == bucket,
                            avatar: Icon(_bucketIcon(bucket), size: 18),
                            label: Text(
                              '${_bucketLabel(bucket)} (${counts[bucket] ?? 0})',
                            ),
                            onSelected: (_) =>
                                setState(() => _selectedBucket = bucket),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SectionHeader(title: _bucketLabel(_selectedBucket)),
                  const SizedBox(height: 10),
                  if (bookings.isEmpty)
                    EmptyState(
                      icon: _bucketIcon(_selectedBucket),
                      title: _emptyTitle(_selectedBucket),
                      message: _emptyMessage(_selectedBucket),
                    )
                  else
                    for (final booking in bookings) ...[
                      _BookingCard(
                        booking: booking,
                        bucket: _selectedBucket,
                        outcome: appState.customerBookingOutcome(
                          booking,
                          now: now,
                        ),
                        now: now,
                      ),
                      const SizedBox(height: 12),
                    ],
                ],
              ),
      ),
    );
  }

  String _bucketLabel(CustomerBookingBucket bucket) => switch (bucket) {
    CustomerBookingBucket.active => 'Active bookings',
    CustomerBookingBucket.history => 'History',
    CustomerBookingBucket.cancelled => 'Cancelled / rejected',
  };

  IconData _bucketIcon(CustomerBookingBucket bucket) => switch (bucket) {
    CustomerBookingBucket.active => Icons.event_available,
    CustomerBookingBucket.history => Icons.history,
    CustomerBookingBucket.cancelled => Icons.cancel_outlined,
  };

  String _emptyTitle(CustomerBookingBucket bucket) => switch (bucket) {
    CustomerBookingBucket.active => 'No active bookings',
    CustomerBookingBucket.history => 'No booking history yet',
    CustomerBookingBucket.cancelled => 'No cancelled or rejected bookings',
  };

  String _emptyMessage(CustomerBookingBucket bucket) => switch (bucket) {
    CustomerBookingBucket.active =>
      'Upcoming accepted bookings and pending requests appear here.',
    CustomerBookingBucket.history =>
      'Completed, missed, and not-accepted bookings appear here after time passes.',
    CustomerBookingBucket.cancelled =>
      'Bookings cancelled by you or rejected by the salon appear here.',
  };
}

class _BookingMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _BookingMetric({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(32)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  final Booking booking;
  final CustomerBookingBucket bucket;
  final String outcome;
  final DateTime now;

  const _BookingCard({
    required this.booking,
    required this.bucket,
    required this.outcome,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    final canCancel =
        bucket == CustomerBookingBucket.active &&
        now.isBefore(booking.start) &&
        (booking.status == BookingStatus.pending ||
            booking.status == BookingStatus.confirmed);
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusChip(status: booking.status),
                  const SizedBox(height: 6),
                  AppPill(label: outcome, color: _statusColor(booking.status)),
                ],
              ),
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
          const SizedBox(height: 9),
          _DetailRow(
            icon: Icons.timer_outlined,
            label:
                '${booking.durationMinutes} min · ends ${appState.formatTime(end)}',
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
    final pageContext = context;
    final controller = TextEditingController();
    var rating = 5;
    const ratingLabels = ['Poor', 'Fair', 'Good', 'Very good', 'Excellent'];
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            onPressed: () => Navigator.pop(context),
                            style: IconButton.styleFrom(
                              backgroundColor: AppColors.mint,
                              foregroundColor: AppColors.muted,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 20),
                            tooltip: 'Close',
                          ),
                        ),
                        Container(
                          width: 64,
                          height: 64,
                          margin: const EdgeInsets.only(top: 2, bottom: 16),
                          decoration: BoxDecoration(
                            color: AppColors.champagne,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(
                            Icons.reviews_rounded,
                            color: AppColors.goldDeep,
                            size: 31,
                          ),
                        ),
                        const Text(
                          'How was your visit?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.ink,
                            fontSize: 23,
                            height: 1.15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Your feedback helps the salon improve your next experience.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.canvas,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Column(
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (var index = 1; index <= 5; index++)
                                      IconButton(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 48,
                                          minHeight: 48,
                                        ),
                                        onPressed: () => setDialogState(
                                          () => rating = index,
                                        ),
                                        icon: Icon(
                                          index <= rating
                                              ? Icons.star_rounded
                                              : Icons.star_outline_rounded,
                                          color: AppColors.amber,
                                          size: 38,
                                        ),
                                        tooltip: '$index stars',
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 5),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                child: Text(
                                  '${ratingLabels[rating - 1]} · $rating/5',
                                  key: ValueKey(rating),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppColors.goldDeep,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: controller,
                          minLines: 3,
                          maxLines: 5,
                          textAlign: TextAlign.start,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: const InputDecoration(
                            hintText:
                                'Tell us what went well or what could be better…',
                            labelText: 'Add a note (optional)',
                            alignLabelWithHint: true,
                            prefixIcon: Padding(
                              padding: EdgeInsets.only(bottom: 48),
                              child: Icon(Icons.edit_note_rounded),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(pageContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Thanks for the $rating-star feedback.',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.send_rounded, size: 19),
                            label: const Text('Submit feedback'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Maybe later'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(controller.dispose);
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
      case BookingStatus.rejected:
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
