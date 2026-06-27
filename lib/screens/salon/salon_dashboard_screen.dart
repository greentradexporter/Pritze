import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/auth_login_panel.dart';
import '../../widgets/status_chip.dart';
import 'salon_profile_setup_screen.dart';

class SalonDashboardScreen extends StatelessWidget {
  const SalonDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.ownerSalon;

    if (appState.ownerAccount == null) {
      return const _OwnerLoginGate();
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Owner tools'),
          actions: [
            IconButton.filledTonal(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Salon listing',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SalonProfileSetupScreen(),
                  ),
                );
              },
            ),
            AccountOverflowMenu(
              role: UserRole.owner,
              canLogout: true,
              onNotificationOpened: (destination) {
                final controller = DefaultTabController.of(context);
                controller.animateTo(
                  destination == AppNotificationDestination.team ? 2 : 0,
                );
              },
              onLoggedOut: () async {
                if (context.mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            ),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Bookings'),
              Tab(text: 'Team'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _OwnerRefresh(child: _OwnerOverview(salon: salon)),
            _OwnerRefresh(child: _OwnerBookings(salonId: salon.id)),
            _OwnerRefresh(child: _OwnerStaff(salon: salon)),
          ],
        ),
      ),
    );
  }
}

class _OwnerRefresh extends StatelessWidget {
  final Widget child;

  const _OwnerRefresh({required this.child});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => AppStateScope.read(context).refresh(),
      child: child,
    );
  }
}

class _OwnerOverview extends StatelessWidget {
  final Salon salon;

  const _OwnerOverview({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final serviceRevenue = appState.serviceRevenue(salon.id);
    final revenueEntries =
        serviceRevenue.entries.where((entry) => entry.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final pendingRequests = appState.pendingJoinRequests
        .where((request) => request.salonId == salon.id)
        .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        AppHeroHeader(
          eyebrow: 'Revenue at ${salon.name}',
          title: '₹${appState.totalCollection(salon.id)} total revenue',
          subtitle:
              '${appState.todayBookingCount(salon.id)} appointments today. Track staff, revenue, and booking status.',
          icon: Icons.insights,
        ),
        if (!appState.isSalonBookable(salon.id)) ...[
          const SizedBox(height: 14),
          _OwnerSetupBanner(salon: salon),
        ],
        if (pendingRequests.isNotEmpty) ...[
          const SizedBox(height: 18),
          SectionHeader(title: 'Barber requests (${pendingRequests.length})'),
          const SizedBox(height: 10),
          for (final request in pendingRequests) ...[
            _JoinRequestCard(request: request),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 22),
        GridView.count(
          shrinkWrap: true,
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.34,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _MetricCard(
              icon: Icons.event_available,
              label: 'Today bookings',
              value: '${appState.todayBookingCount(salon.id)}',
              color: AppColors.primary,
            ),
            _MetricCard(
              icon: Icons.pending_actions,
              label: 'Pending',
              value:
                  '${appState.todayCountByStatus(salon.id, BookingStatus.pending)}',
              color: AppColors.amber,
            ),
            _MetricCard(
              icon: Icons.play_circle_outline,
              label: 'In progress',
              value:
                  '${appState.todayCountByStatus(salon.id, BookingStatus.inProgress)}',
              color: AppColors.primary,
            ),
            _MetricCard(
              icon: Icons.done_all,
              label: 'Completed',
              value:
                  '${appState.todayCountByStatus(salon.id, BookingStatus.completed)}',
              color: AppColors.success,
            ),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHeader(title: 'Chair board'),
        const SizedBox(height: 10),
        _ChairBoard(salonId: salon.id),
        const SizedBox(height: 18),
        const SectionHeader(title: 'Service revenue'),
        const SizedBox(height: 10),
        if (revenueEntries.isEmpty)
          const GlassCard(child: Text('Completed bookings will appear here.'))
        else
          GlassCard(
            child: Column(
              children: [
                for (final entry in revenueEntries.take(8))
                  _ProgressRow(
                    label:
                        appState.getService(salon.id, entry.key)?.name ??
                        'Booked service',
                    value: '₹${entry.value}',
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OwnerBookings extends StatefulWidget {
  final String salonId;

  const _OwnerBookings({required this.salonId});

  @override
  State<_OwnerBookings> createState() => _OwnerBookingsState();
}

class _OwnerBookingsState extends State<_OwnerBookings> {
  SalonBookingBucket _selectedBucket = SalonBookingBucket.requests;
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
    final allBookings = appState.bookingsForSalon(widget.salonId);
    final counts = {
      for (final bucket in SalonBookingBucket.values)
        bucket: allBookings
            .where(
              (booking) =>
                  appState.salonBookingBucket(booking, now: now) == bucket,
            )
            .length,
    };
    final bookings =
        allBookings.where((booking) {
          return appState.salonBookingBucket(booking, now: now) ==
              _selectedBucket;
        }).toList()..sort((a, b) {
          if (_selectedBucket == SalonBookingBucket.history ||
              _selectedBucket == SalonBookingBucket.cancelled) {
            return b.start.compareTo(a.start);
          }
          return a.start.compareTo(b.start);
        });

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        const Text(
          'Booking desk',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        Text(
          'Accept requests, start services, complete revenue, and keep missed appointments in history.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _OwnerBookingMetric(
                value: '${counts[SalonBookingBucket.requests] ?? 0}',
                label: 'Requests',
                color: AppColors.amber,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _OwnerBookingMetric(
                value: '${counts[SalonBookingBucket.active] ?? 0}',
                label: 'Active',
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _OwnerBookingMetric(
                value: '${counts[SalonBookingBucket.history] ?? 0}',
                label: 'History',
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final bucket in SalonBookingBucket.values) ...[
                ChoiceChip(
                  selected: _selectedBucket == bucket,
                  avatar: Icon(_bucketIcon(bucket), size: 18),
                  label: Text(
                    '${_bucketLabel(bucket)} (${counts[bucket] ?? 0})',
                  ),
                  onSelected: (_) => setState(() => _selectedBucket = bucket),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (bookings.isEmpty)
          EmptyState(
            icon: _bucketIcon(_selectedBucket),
            title: _emptyTitle(_selectedBucket),
            message: _emptyMessage(_selectedBucket),
          )
        else
          for (final booking in bookings) ...[
            _OwnerBookingCard(
              booking: booking,
              bucket: _selectedBucket,
              outcome: appState.salonBookingOutcome(booking, now: now),
              now: now,
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  String _bucketLabel(SalonBookingBucket bucket) => switch (bucket) {
    SalonBookingBucket.requests => 'Requests',
    SalonBookingBucket.upcoming => 'Upcoming',
    SalonBookingBucket.active => 'Active',
    SalonBookingBucket.history => 'History',
    SalonBookingBucket.cancelled => 'Cancelled',
  };

  IconData _bucketIcon(SalonBookingBucket bucket) => switch (bucket) {
    SalonBookingBucket.requests => Icons.pending_actions,
    SalonBookingBucket.upcoming => Icons.upcoming,
    SalonBookingBucket.active => Icons.content_cut,
    SalonBookingBucket.history => Icons.history,
    SalonBookingBucket.cancelled => Icons.cancel_outlined,
  };

  String _emptyTitle(SalonBookingBucket bucket) => switch (bucket) {
    SalonBookingBucket.requests => 'No booking requests',
    SalonBookingBucket.upcoming => 'No accepted upcoming bookings',
    SalonBookingBucket.active => 'No active services',
    SalonBookingBucket.history => 'No previous bookings',
    SalonBookingBucket.cancelled => 'No cancelled or rejected bookings',
  };

  String _emptyMessage(SalonBookingBucket bucket) => switch (bucket) {
    SalonBookingBucket.requests =>
      'New customer requests appear here until their appointment time passes.',
    SalonBookingBucket.upcoming =>
      'Accepted future bookings appear here before they are ready to start.',
    SalonBookingBucket.active =>
      'Services in progress and accepted bookings inside their appointment window appear here.',
    SalonBookingBucket.history =>
      'Completed, missed, and not-accepted expired bookings appear here.',
    SalonBookingBucket.cancelled =>
      'Bookings cancelled by customer/owner or rejected by salon appear here.',
  };
}

class _OwnerBookingMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _OwnerBookingMetric({
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

class _ChairBoard extends StatelessWidget {
  final String salonId;

  const _ChairBoard({required this.salonId});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barbers = appState.barbersForSalon(salonId);

    if (barbers.isEmpty) {
      return const GlassCard(
        child: Text('Add barbers to see chair occupancy.'),
      );
    }

    return Column(
      children: [
        for (final barber in barbers) ...[
          _ChairCard(barber: barber),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _ChairCard extends StatelessWidget {
  final Barber barber;

  const _ChairCard({required this.barber});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final current = appState.currentBookingForBarber(barber.id);
    final next = appState.nextBookingForBarber(barber.id);
    final displayBooking = current ?? next;
    final service = displayBooking == null
        ? null
        : appState.getService(displayBooking.salonId, displayBooking.serviceId);
    final occupied = current != null;
    final color = occupied ? AppColors.coral : AppColors.primary;

    return GlassCard(
      color: occupied ? AppColors.coral.withAlpha(10) : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 23,
                backgroundColor: color.withAlpha(20),
                foregroundColor: color,
                child: Text(
                  barber.name.characters.first,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      barber.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      barber.speciality,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              AppPill(label: occupied ? 'Occupied' : 'Free', color: color),
            ],
          ),
          const SizedBox(height: 14),
          if (displayBooking == null)
            Row(
              children: [
                const Icon(
                  Icons.event_available,
                  color: AppColors.primary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No upcoming booking. Available for new customers.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.primaryDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else ...[
            _SmallDetail(
              icon: occupied ? Icons.content_cut : Icons.upcoming,
              label:
                  '${occupied ? 'Doing' : 'Next'}: ${service?.name ?? 'Service'}',
            ),
            _SmallDetail(
              icon: Icons.person_outline,
              label: displayBooking.customerName,
            ),
            _SmallDetail(
              icon: Icons.schedule,
              label:
                  '${appState.formatDate(displayBooking.start)}, ${appState.formatTime(displayBooking.start)}',
            ),
            const SizedBox(height: 10),
            StatusChip(status: displayBooking.status),
          ],
        ],
      ),
    );
  }
}

class _BarberWorkloadCard extends StatelessWidget {
  final Barber barber;

  const _BarberWorkloadCard({required this.barber});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final now = DateTime.now();
    final todayBookings = appState.bookingsForBarber(barber.id).where((
      booking,
    ) {
      return booking.status != BookingStatus.cancelled &&
          booking.start.year == now.year &&
          booking.start.month == now.month &&
          booking.start.day == now.day;
    }).toList();
    final current = appState.currentBookingForBarber(barber.id);
    final occupied = current != null;
    final upcoming = todayBookings.where((booking) {
      return booking.status == BookingStatus.pending ||
          booking.status == BookingStatus.confirmed;
    }).length;
    final completed = todayBookings
        .where((booking) => booking.status == BookingStatus.completed)
        .length;
    final currentService = current == null
        ? null
        : appState.getService(current.salonId, current.serviceId);
    final statusColor = occupied ? AppColors.coral : AppColors.success;

    return GlassCard(
      color: occupied ? AppColors.coral.withAlpha(9) : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: statusColor.withAlpha(18),
                foregroundColor: statusColor,
                child: Text(
                  barber.name.characters.first.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      barber.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      barber.speciality,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              AppPill(
                icon: occupied ? Icons.content_cut : Icons.event_available,
                label: occupied ? 'Occupied' : 'Available',
                color: statusColor,
              ),
            ],
          ),
          if (current != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.coral.withAlpha(10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.coral.withAlpha(45)),
              ),
              child: Text(
                'Now serving ${current.customerName} · '
                '${currentService?.name ?? current.serviceName}',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _WorkloadMetric(
                  value: '${todayBookings.length}',
                  label: 'Today',
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _WorkloadMetric(
                  value: '$upcoming',
                  label: 'Upcoming',
                  color: AppColors.amber,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _WorkloadMetric(
                  value: '$completed',
                  label: 'Completed',
                  color: AppColors.success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkloadMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _WorkloadMetric({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(30)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 20,
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
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _OwnerBookingCard extends StatelessWidget {
  final Booking booking;
  final SalonBookingBucket bucket;
  final String outcome;
  final DateTime now;

  const _OwnerBookingCard({
    required this.booking,
    required this.bucket,
    required this.outcome,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    final isPastStart = !now.isBefore(booking.start);
    final isPastEnd = !now.isBefore(end);
    final canAcceptOrReject =
        booking.status == BookingStatus.pending &&
        bucket == SalonBookingBucket.requests;
    final canStart =
        booking.status == BookingStatus.confirmed &&
        bucket == SalonBookingBucket.active &&
        isPastStart &&
        !isPastEnd;
    final canCancel =
        booking.status == BookingStatus.confirmed &&
        !isPastEnd &&
        bucket != SalonBookingBucket.history;
    final canComplete = booking.status == BookingStatus.inProgress;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SoftIconBox(
                icon: Icons.person,
                color: _statusColor(booking.status),
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      booking.customerName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
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
          const SizedBox(height: 14),
          _SmallDetail(icon: Icons.badge, label: barber?.name ?? 'Barber'),
          _SmallDetail(
            icon: Icons.schedule,
            label:
                '${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}',
          ),
          _SmallDetail(icon: Icons.phone, label: booking.customerPhone),
          _SmallDetail(
            icon: Icons.timer_outlined,
            label:
                '${booking.durationMinutes} min · ends ${appState.formatTime(end)}',
          ),
          const SizedBox(height: 14),
          if (canAcceptOrReject || canStart || canCancel || canComplete)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canAcceptOrReject) ...[
                  _StatusButton(
                    label: 'Accept booking',
                    status: BookingStatus.confirmed,
                    booking: booking,
                    icon: Icons.check_circle_outline,
                    isPrimary: true,
                  ),
                  _StatusButton(
                    label: 'Reject',
                    status: BookingStatus.rejected,
                    booking: booking,
                    icon: Icons.close,
                  ),
                ],
                if (canStart)
                  _StatusButton(
                    label: 'Start service',
                    status: BookingStatus.inProgress,
                    booking: booking,
                    icon: Icons.content_cut,
                    isPrimary: true,
                  ),
                if (canCancel)
                  _StatusButton(
                    label: 'Cancel',
                    status: BookingStatus.cancelled,
                    booking: booking,
                    icon: Icons.cancel_outlined,
                  ),
                if (canComplete)
                  _StatusButton(
                    label: 'Complete & add revenue',
                    status: BookingStatus.completed,
                    booking: booking,
                    icon: Icons.check_circle_outline,
                    isPrimary: true,
                  ),
              ],
            )
          else
            Text(
              bucket == SalonBookingBucket.history
                  ? 'This booking is locked in history.'
                  : 'No action needed right now.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
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
      case BookingStatus.rejected:
        return AppColors.coral;
    }
  }
}

class _OwnerStaff extends StatelessWidget {
  final Salon salon;

  const _OwnerStaff({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final requests = appState.pendingJoinRequests
        .where((request) => request.salonId == salon.id)
        .toList();
    final barbers = appState.barbersForSalon(salon.id);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SalonProfileSetupScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.edit),
                label: const Text('Edit salon'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showAddBarberDialog(context),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add barber'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHeader(title: 'Join requests'),
        const SizedBox(height: 10),
        if (requests.isEmpty)
          const GlassCard(child: Text('No pending requests right now.'))
        else
          for (final request in requests) ...[
            _JoinRequestCard(request: request),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 18),
        const SectionHeader(title: 'Barber workload'),
        const SizedBox(height: 10),
        if (barbers.isEmpty)
          const GlassCard(child: Text('No barbers have joined the team yet.'))
        else
          for (final barber in barbers) ...[
            _BarberWorkloadCard(barber: barber),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 18),
        const SectionHeader(title: 'Team members'),
        const SizedBox(height: 10),
        if (barbers.isEmpty)
          const GlassCard(
            child: Text('Add your first barber to build the salon team.'),
          )
        else
          for (final barber in barbers) ...[
            _StaffCard(barber: barber),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  void _showAddBarberDialog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _AddBarberSheet(),
    );
  }
}

class _AddBarberSheet extends StatefulWidget {
  const _AddBarberSheet();

  @override
  State<_AddBarberSheet> createState() => _AddBarberSheetState();
}

class _AddBarberSheetState extends State<_AddBarberSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _experienceController = TextEditingController(text: '2');
  final _resumeController = TextEditingController();
  final _serviceSearchController = TextEditingController();
  final Set<String> _selectedServices = {};
  String _speciality = _barberSpecialities.first;
  String _serviceQuery = '';
  bool _servicesExpanded = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _experienceController.dispose();
    _resumeController.dispose();
    _serviceSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final services = appState.ownerSalon.services;
    final specialityServices = services
        .where(
          (service) => serviceMatchesBarberSpeciality(service, _speciality),
        )
        .toList();
    final visibleServices = specialityServices.where((service) {
      final query = _serviceQuery.trim().toLowerCase();
      return query.isEmpty ||
          service.name.toLowerCase().contains(query) ||
          service.category.toLowerCase().contains(query);
    }).toList();

    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Add barber',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                      ),
                      validator: _email,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                      ),
                      validator: _phone,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _speciality,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Speciality',
                      ),
                      items: [
                        for (final item in _barberSpecialities)
                          DropdownMenuItem(value: item, child: Text(item)),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _speciality = value;
                            _selectedServices.removeWhere((serviceId) {
                              final service = services
                                  .where((item) => item.id == serviceId)
                                  .firstOrNull;
                              return service == null ||
                                  !serviceMatchesBarberSpeciality(
                                    service,
                                    value,
                                  );
                            });
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _experienceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Years of experience',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _resumeController,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Barber resume summary',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.line),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          ListTile(
                            title: const Text('Assigned services'),
                            subtitle: Text(
                              '${_selectedServices.length} selected',
                            ),
                            trailing: Icon(
                              _servicesExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                            onTap: () => setState(
                              () => _servicesExpanded = !_servicesExpanded,
                            ),
                          ),
                          if (_servicesExpanded)
                            Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    12,
                                    4,
                                  ),
                                  child: TextField(
                                    controller: _serviceSearchController,
                                    onChanged: (value) =>
                                        setState(() => _serviceQuery = value),
                                    decoration: const InputDecoration(
                                      labelText: 'Search services',
                                      prefixIcon: Icon(Icons.search),
                                    ),
                                  ),
                                ),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 220,
                                  ),
                                  child: ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: visibleServices.length,
                                    itemBuilder: (context, index) {
                                      final service = visibleServices[index];
                                      return CheckboxListTile(
                                        dense: true,
                                        value: _selectedServices.contains(
                                          service.id,
                                        ),
                                        title: Text(service.name),
                                        subtitle: Text(service.category),
                                        onChanged: (selected) {
                                          setState(() {
                                            if (selected == true) {
                                              _selectedServices.add(service.id);
                                            } else {
                                              _selectedServices.remove(
                                                service.id,
                                              );
                                            }
                                          });
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSaving ? null : () => _save(appState),
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add_alt),
                  label: Text(_isSaving ? 'Adding...' : 'Add barber'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? 'Required' : null;
  }

  String? _phone(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
    final localDigits = digits.length == 12 && digits.startsWith('91')
        ? digits.substring(2)
        : digits;
    return localDigits.length == 10 ? null : 'Enter a 10-digit phone number';
  }

  String? _email(String? value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((value ?? '').trim())
        ? null
        : 'Enter a valid email address';
  }

  Future<void> _save(AppState appState) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_selectedServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one service.')),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      await appState.addOwnerBarber(
        name: _nameController.text,
        phone: _phoneController.text,
        email: _emailController.text,
        speciality: _speciality,
        experienceYears: int.tryParse(_experienceController.text) ?? 1,
        resumeSummary: _resumeController.text,
        serviceIds: _selectedServices.toList(),
      );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Barber save failed: $error')));
        setState(() => _isSaving = false);
      }
    }
  }
}

const _barberSpecialities = [
  'Haircut specialist',
  'Fade specialist',
  'Beard and shave expert',
  'Hair styling expert',
  'Hair color specialist',
  'Hair spa specialist',
  'Skin and cleanup expert',
  'Kids haircut specialist',
  'All-round grooming expert',
];

class _JoinRequestCard extends StatefulWidget {
  final JoinRequest request;

  const _JoinRequestCard({required this.request});

  @override
  State<_JoinRequestCard> createState() => _JoinRequestCardState();
}

class _JoinRequestCardState extends State<_JoinRequestCard> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final request = widget.request;
    final serviceNames = request.serviceIds
        .map((id) => appState.getService(request.salonId, id)?.name)
        .whereType<String>()
        .toList();
    final serviceSummary = serviceNames.isEmpty
        ? 'General grooming'
        : '${serviceNames.take(3).join(', ')}${serviceNames.length > 3 ? ' +${serviceNames.length - 3} more' : ''}';

    return GlassCard(
      color: AppColors.champagne.withAlpha(55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: AppColors.goldDeep.withAlpha(20),
                foregroundColor: AppColors.goldDeep,
                child: Text(
                  request.barberName.characters.first.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.barberName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      request.speciality,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const AppPill(
                icon: Icons.schedule,
                label: 'Pending',
                color: AppColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(210),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              children: [
                _SmallDetail(
                  icon: Icons.workspace_premium_outlined,
                  label: '${request.experienceYears} years experience',
                ),
                _SmallDetail(icon: Icons.content_cut, label: serviceSummary),
                _SmallDetail(
                  icon: Icons.phone_outlined,
                  label: request.barberPhone,
                ),
                if (request.barberEmail.isNotEmpty)
                  _SmallDetail(
                    icon: Icons.alternate_email,
                    label: request.barberEmail,
                  ),
              ],
            ),
          ),
          if (request.resumeSummary.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              request.resumeSummary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isProcessing
                      ? null
                      : () => _updateRequest(appState, accept: false),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _isProcessing
                      ? null
                      : () => _updateRequest(appState, accept: true),
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add_alt_1),
                  label: Text(_isProcessing ? 'Saving...' : 'Accept barber'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _updateRequest(AppState appState, {required bool accept}) async {
    setState(() => _isProcessing = true);
    try {
      if (accept) {
        await appState.approveJoinRequest(widget.request.id);
      } else {
        await appState.rejectJoinRequest(widget.request.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              accept
                  ? 'Barber accepted and added to the team.'
                  : 'Request rejected.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${accept ? 'Accept' : 'Reject'} failed: $error'),
          ),
        );
        setState(() => _isProcessing = false);
      }
    }
  }
}

class _StaffCard extends StatelessWidget {
  final Barber barber;

  const _StaffCard({required this.barber});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final serviceNames = barber.serviceIds
        .map((id) => appState.getService(barber.salonId, id)?.name)
        .whereType<String>()
        .join(', ');

    return GlassCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.mint,
            foregroundColor: AppColors.primary,
            child: Text(
              barber.name.characters.first,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  barber.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${barber.experienceYears} yrs exp - ${serviceNames.isEmpty ? barber.speciality : serviceNames}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  barber.uid == null
                      ? 'Login verification pending${barber.email.isEmpty ? '' : ' · ${barber.email}'}'
                      : 'Account verified',
                  style: TextStyle(
                    color: barber.uid == null
                        ? AppColors.amber
                        : AppColors.success,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _confirmRemove(context, barber),
            icon: const Icon(Icons.person_remove_outlined),
            tooltip: 'Remove barber',
          ),
        ],
      ),
    );
  }

  void _confirmRemove(BuildContext context, Barber barber) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Remove ${barber.name}?'),
          content: Text(
            'This removes the barber from active staff and future slot availability.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await AppStateScope.read(context).removeBarber(barber.id);
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                } catch (error) {
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Remove failed: $error')),
                  );
                }
              },
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
  }
}

class _OwnerLoginGate extends StatefulWidget {
  const _OwnerLoginGate();

  @override
  State<_OwnerLoginGate> createState() => _OwnerLoginGateState();
}

class _OwnerLoginGateState extends State<_OwnerLoginGate> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Owner sign in')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
        children: [
          const AppHeroHeader(
            eyebrow: 'Separate owner account',
            title: 'Sign in to register or manage your shop',
            subtitle:
                'After login, you can add shop name, address, timings, services, staff, and booking controls.',
            icon: Icons.admin_panel_settings,
          ),
          const SizedBox(height: 22),
          AuthLoginPanel(
            role: UserRole.owner,
            googleTitle: 'Gmail shortcut',
            googleMessage:
                'Choose your Google account. Your name and Gmail address will be carried into owner tools automatically.',
            onLoggedIn: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => const SalonProfileSetupScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OwnerSetupBanner extends StatelessWidget {
  final Salon salon;

  const _OwnerSetupBanner({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final hasDetails = appState.hasSalonDetails(salon.id);
    final hasServices = salon.services.isNotEmpty;
    final hasBarber = appState.barbersForSalon(salon.id).isNotEmpty;
    final hasAssignedBarber = appState.isSalonBookable(salon.id);

    return GlassCard(
      color: AppColors.mint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.assignment_outlined,
                color: AppColors.primary,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Complete setup before customer bookings go live',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SalonProfileSetupScreen(),
                    ),
                  );
                },
                child: const Text('Register'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SetupCheckRow(done: hasDetails, label: 'Shop details saved'),
          _SetupCheckRow(done: hasServices, label: 'At least one service'),
          _SetupCheckRow(done: hasBarber, label: 'At least one barber'),
          _SetupCheckRow(
            done: hasAssignedBarber,
            label: 'Barber assigned to a service',
          ),
        ],
      ),
    );
  }
}

class _SetupCheckRow extends StatelessWidget {
  final bool done;
  final String label;

  const _SetupCheckRow({required this.done, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? AppColors.success : AppColors.muted,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.primaryDark,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SoftIconBox(icon: icon, color: color, size: 40),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final String label;
  final String value;

  const _ProgressRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallDetail extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SmallDetail({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        children: [
          Icon(icon, size: 17, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  final String label;
  final BookingStatus status;
  final Booking booking;
  final IconData? icon;
  final bool isPrimary;

  const _StatusButton({
    required this.label,
    required this.status,
    required this.booking,
    this.icon,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final onPressed = booking.status == status
        ? null
        : () async {
            try {
              await appState.updateBookingStatus(booking.id, status);
              if (context.mounted && status == BookingStatus.completed) {
                final service = appState.getService(
                  booking.salonId,
                  booking.serviceId,
                );
                final price = booking.servicePrice > 0
                    ? booking.servicePrice
                    : service?.price ?? 0;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Service completed. ₹$price added to revenue.',
                    ),
                  ),
                );
              }
            } catch (error) {
              if (!context.mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Status update failed: $error')),
              );
            }
          };
    if (isPrimary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon ?? Icons.arrow_forward),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon ?? Icons.arrow_forward),
      label: Text(label),
    );
  }
}
