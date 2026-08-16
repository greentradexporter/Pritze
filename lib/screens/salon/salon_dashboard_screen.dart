import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/auth_login_panel.dart';
import '../../widgets/booking_status_timeline.dart';
import '../../widgets/status_chip.dart';
import '../customer/customer_home_screen.dart';
import 'salon_profile_setup_screen.dart';

class SalonDashboardScreen extends StatefulWidget {
  const SalonDashboardScreen({super.key});

  @override
  State<SalonDashboardScreen> createState() => _SalonDashboardScreenState();
}

class _SalonDashboardScreenState extends State<SalonDashboardScreen> {
  final GlobalKey<_OwnerBookingsState> _bookingsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.ownerSalon;

    if (appState.ownerAccount == null) {
      return const _OwnerLoginGate();
    }
    if (appState.ownerSalonOrNull == null) {
      return const SalonProfileSetupScreen();
    }
    final activeInstantBooking = _activeInstantBooking(
      appState.bookingsForSalon(salon.id),
    );

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (dashboardContext) {
          final pendingNavigation = appState
              .takePendingNotificationNavigation();
          if (pendingNavigation != null) {
            _openNotificationDestination(
              dashboardContext,
              pendingNavigation.destination,
              bookingId: pendingNavigation.bookingId,
            );
          }
          return Scaffold(
            appBar: AppBar(
              title: Text(
                salon.name.trim().isEmpty ? 'Salon dashboard' : salon.name,
              ),
              actions: [
                IconButton(
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
                  onNotificationOpened: (destination, {bookingId}) =>
                      _openNotificationDestination(
                        dashboardContext,
                        destination,
                        bookingId: bookingId,
                      ),
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
            bottomNavigationBar: activeInstantBooking == null
                ? null
                : BookingArrivalBottomPanel(
                    booking: activeInstantBooking,
                    audience: BookingTimerAudience.salon,
                    onTap: () => _openNotificationDestination(
                      dashboardContext,
                      AppNotificationDestination.bookings,
                      bookingId: activeInstantBooking.id,
                    ),
                  ),
            body: TabBarView(
              children: [
                _OwnerRefresh(child: _OwnerOverview(salon: salon)),
                _OwnerRefresh(
                  child: _OwnerBookings(key: _bookingsKey, salonId: salon.id),
                ),
                _OwnerRefresh(child: _OwnerStaff(salon: salon)),
              ],
            ),
          );
        },
      ),
    );
  }

  int _dashboardTabFor(AppNotificationDestination destination) {
    return switch (destination) {
      AppNotificationDestination.overview => 0,
      AppNotificationDestination.bookings => 1,
      AppNotificationDestination.team => 2,
    };
  }

  void _openNotificationDestination(
    BuildContext dashboardContext,
    AppNotificationDestination destination, {
    String? bookingId,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!dashboardContext.mounted) {
        return;
      }
      DefaultTabController.of(
        dashboardContext,
      ).animateTo(_dashboardTabFor(destination));
      if (destination != AppNotificationDestination.bookings) {
        return;
      }
      _revealBookingWhenReady(bookingId?.trim() ?? '');
    });
  }

  void _revealBookingWhenReady(String bookingId, [int attempt = 0]) {
    final bookingsState = _bookingsKey.currentState;
    if (bookingsState != null) {
      bookingsState.showBooking(bookingId);
      return;
    }
    if (attempt >= 5 || !mounted) {
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (mounted) {
        _revealBookingWhenReady(bookingId, attempt + 1);
      }
    });
  }

  Booking? _activeInstantBooking(List<Booking> bookings) {
    final now = DateTime.now();
    final active =
        bookings
            .where(
              (booking) =>
                  booking.isInstant &&
                  (booking.status == BookingStatus.pending ||
                      (booking.status == BookingStatus.confirmed &&
                          now.isBefore(booking.salonArrivalDeadline))),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    return active.firstOrNull;
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
          eyebrow: 'Revenue at ${salon.displayName}',
          title: '₹${appState.totalCollection(salon.id)} total revenue',
          subtitle:
              '${appState.todayBookingCount(salon.id)} appointments today. Track staff, revenue, and booking status.',
          icon: Icons.insights,
        ),
        if (!appState.isSalonSetupComplete(salon.id)) ...[
          const SizedBox(height: 14),
          _OwnerSetupBanner(salon: salon),
        ],
        const SizedBox(height: 14),
        _InstantBookingControl(salon: salon),
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

  const _OwnerBookings({super.key, required this.salonId});

  @override
  State<_OwnerBookings> createState() => _OwnerBookingsState();
}

class _OwnerBookingsState extends State<_OwnerBookings> {
  SalonBookingBucket _selectedBucket = SalonBookingBucket.upcoming;
  String? _requestedBookingId;
  late final Timer _clock;

  void showBooking(String? bookingId) {
    final normalizedBookingId = bookingId?.trim() ?? '';
    if (normalizedBookingId.isEmpty) {
      return;
    }
    _requestedBookingId = normalizedBookingId;
    _revealRequestedBooking();
  }

  void _revealRequestedBooking() {
    final bookingId = _requestedBookingId;
    if (bookingId == null || !mounted) {
      return;
    }
    final appState = AppStateScope.read(context);
    final booking = appState
        .bookingsForSalon(widget.salonId)
        .where((item) => item.id == bookingId)
        .firstOrNull;
    if (booking == null) {
      return;
    }
    _requestedBookingId = null;
    final bucket = appState.salonBookingBucket(booking);
    if (_selectedBucket != bucket) {
      setState(() => _selectedBucket = bucket);
    }
  }

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
    if (_requestedBookingId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealRequestedBooking();
      });
    }
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
    final oldestInstantRequest =
        allBookings
            .where(
              (booking) =>
                  booking.isInstant && booking.status == BookingStatus.pending,
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        const Text(
          'Booking desk',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Scheduled appointments register in Upcoming. Instant requests stay urgent until you accept or reject them.',
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
                value: '${counts[SalonBookingBucket.upcoming] ?? 0}',
                label: 'Upcoming',
                color: AppColors.goldDeep,
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
          ],
        ),
        if (oldestInstantRequest.isNotEmpty &&
            _selectedBucket != SalonBookingBucket.requests) ...[
          const SizedBox(height: 14),
          GlassCard(
            color: AppColors.coral.withAlpha(12),
            child: Row(
              children: [
                const SoftIconBox(
                  icon: Icons.notifications_active_outlined,
                  color: AppColors.coral,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${oldestInstantRequest.first.customerName} is waiting for an instant booking response.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _selectedBucket = SalonBookingBucket.requests,
                  ),
                  child: const Text('Respond'),
                ),
              ],
            ),
          ),
        ],
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
              onBookingChanged: () => showBooking(booking.id),
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
      'Only instant requests appear here and remain until you accept or reject them.',
    SalonBookingBucket.upcoming =>
      'Registered scheduled bookings and accepted instant bookings appear here.',
    SalonBookingBucket.active =>
      'Services in progress and accepted bookings inside their appointment window appear here.',
    SalonBookingBucket.history =>
      'Completed, missed, and not-accepted expired bookings appear here.',
    SalonBookingBucket.cancelled =>
      'Bookings cancelled by customer/owner or rejected by salon appear here.',
  };
}

class _InstantBookingControl extends StatelessWidget {
  final Salon salon;

  const _InstantBookingControl({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final enabled = appState.isInstantBookingEnabled(salon.id);
    final isOpen = appState.isSalonCurrentlyOpen(salon.id);
    final color = enabled ? AppColors.primary : AppColors.muted;
    final status = enabled
        ? (isOpen ? 'On now' : 'On for opening')
        : 'Paused today';

    return GlassCard(
      color: enabled ? AppColors.champagne.withAlpha(92) : Colors.white,
      child: Row(
        children: [
          SoftIconBox(icon: Icons.bolt_outlined, color: color, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Instant bookings',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppPill(label: status, color: color),
                    AppPill(
                      label: isOpen ? 'Open' : 'Closed',
                      color: isOpen ? AppColors.primary : AppColors.muted,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: AppColors.primary,
            onChanged: appState.isSaving
                ? null
                : (value) async {
                    try {
                      await appState.setOwnerInstantBookingEnabled(value);
                    } catch (error) {
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Update failed: $error')),
                      );
                    }
                  },
          ),
        ],
      ),
    );
  }
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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(32)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
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
                  style: const TextStyle(fontWeight: FontWeight.w600),
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
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.coral.withAlpha(45)),
              ),
              child: Text(
                'Now serving ${current.customerName} · '
                '${currentService?.name ?? current.serviceName}',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(30)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
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
  final VoidCallback onBookingChanged;

  const _OwnerBookingCard({
    required this.booking,
    required this.bucket,
    required this.outcome,
    required this.now,
    required this.onBookingChanged,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    final timeLabel = booking.isInstant
        ? booking.status == BookingStatus.pending
              ? 'Instant request · ${booking.customerArrivalMinutes} min customer ETA · ${booking.salonArrivalMinutes} min salon window'
              : 'Arrive by ${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}'
        : '${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}';
    final isPastEnd = !now.isBefore(end);
    final canRespond =
        booking.isInstant &&
        booking.status == BookingStatus.pending &&
        bucket == SalonBookingBucket.requests;
    final canAccept = canRespond;
    final canStart =
        booking.status == BookingStatus.confirmed &&
        (bucket == SalonBookingBucket.upcoming ||
            bucket == SalonBookingBucket.active) &&
        (booking.isInstant || _isSameDay(now, booking.start)) &&
        !isPastEnd;
    final canCancel =
        booking.status == BookingStatus.confirmed &&
        !isPastEnd &&
        bucket != SalonBookingBucket.history;
    final canComplete = booking.status == BookingStatus.inProgress;
    final canRateCustomer = booking.status == BookingStatus.completed;

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
                      'Ordered service: ${booking.resolvedServiceName(service)}',
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
                  if (booking.isInstant) ...[
                    const SizedBox(height: 6),
                    const AppPill(
                      icon: Icons.bolt_outlined,
                      label: 'Instant',
                      color: AppColors.coral,
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SmallDetail(
            icon: Icons.badge,
            label:
                barber?.name ??
                (booking.isInstant ? 'Any available barber' : 'Barber'),
          ),
          _SmallDetail(icon: Icons.schedule, label: timeLabel),
          if (booking.isInstant && booking.status == BookingStatus.confirmed)
            _SmallDetail(
              icon: Icons.hourglass_bottom_outlined,
              label:
                  'Expect customer by ${appState.formatTime(booking.salonArrivalDeadline)}',
            ),
          if (booking.customerPhone.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Customer contact',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => UrlLauncherUtils.makePhoneCall(
                      context,
                      booking.customerPhone,
                    ),
                    icon: const Icon(Icons.call_outlined),
                    tooltip: 'Call customer',
                  ),
                ],
              ),
            ),
          if (booking.cancellationReason.isNotEmpty)
            _SmallDetail(
              icon: Icons.info_outline,
              label: 'Cancellation reason: ${booking.cancellationReason}',
            ),
          _SmallDetail(
            icon: Icons.timer_outlined,
            label:
                '${booking.durationMinutes} min · ends ${appState.formatTime(end)}',
          ),
          _SmallDetail(
            icon: Icons.payments_outlined,
            label:
                'Service ₹${booking.resolvedServicePrice(service)} · booking fee ₹${booking.bookingFee}',
          ),
          const SizedBox(height: 14),
          if (canRespond ||
              canStart ||
              canCancel ||
              canComplete ||
              canRateCustomer)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canRespond) ...[
                  _StatusButton(
                    key: ValueKey('${booking.id}-confirmed'),
                    label: 'Accept booking',
                    status: BookingStatus.confirmed,
                    booking: booking,
                    icon: Icons.check_circle_outline,
                    isPrimary: true,
                    enabled: canAccept,
                    onBookingChanged: onBookingChanged,
                  ),
                  _StatusButton(
                    key: ValueKey('${booking.id}-rejected'),
                    label: 'Reject',
                    status: BookingStatus.rejected,
                    booking: booking,
                    icon: Icons.close,
                    onBookingChanged: onBookingChanged,
                  ),
                ],
                if (canStart)
                  _StatusButton(
                    key: ValueKey('${booking.id}-inProgress'),
                    label: 'Start service',
                    status: BookingStatus.inProgress,
                    booking: booking,
                    icon: Icons.content_cut,
                    isPrimary: true,
                    onBookingChanged: onBookingChanged,
                  ),
                if (canCancel)
                  _StatusButton(
                    key: ValueKey('${booking.id}-cancelled'),
                    label: 'Cancel',
                    status: BookingStatus.cancelled,
                    booking: booking,
                    icon: Icons.cancel_outlined,
                    onBookingChanged: onBookingChanged,
                  ),
                if (canComplete)
                  _StatusButton(
                    key: ValueKey('${booking.id}-completed'),
                    label: 'Complete service',
                    status: BookingStatus.completed,
                    booking: booking,
                    icon: Icons.check_circle_outline,
                    isPrimary: true,
                    onBookingChanged: onBookingChanged,
                  ),
                if (canRateCustomer)
                  OutlinedButton.icon(
                    key: ValueKey('rate-customer-${booking.id}'),
                    onPressed: () => _showCustomerRatingDialog(context),
                    icon: const Icon(Icons.star_outline_rounded),
                    label: const Text('Rate customer'),
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
                fontWeight: FontWeight.w500,
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

  bool _isSameDay(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  Future<void> _showCustomerRatingDialog(BuildContext pageContext) async {
    var rating = 5;
    var submitting = false;
    final noteController = TextEditingController();
    await showDialog<void>(
      context: pageContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Rate ${booking.customerName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This rating is connected to the completed visit and will appear on the customer profile.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 1; index <= 5; index++)
                    IconButton(
                      onPressed: submitting
                          ? null
                          : () => setDialogState(() => rating = index),
                      icon: Icon(
                        index <= rating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: AppColors.amber,
                      ),
                      tooltip: '$index stars',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteController,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Private visit note (optional)',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      setDialogState(() => submitting = true);
                      try {
                        await AppStateScope.read(
                          pageContext,
                        ).submitCustomerRating(
                          bookingId: booking.id,
                          rating: rating,
                          note: noteController.text,
                        );
                        if (!dialogContext.mounted || !pageContext.mounted) {
                          return;
                        }
                        Navigator.pop(dialogContext);
                        ScaffoldMessenger.of(pageContext).showSnackBar(
                          const SnackBar(
                            content: Text('Customer rating saved.'),
                          ),
                        );
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() => submitting = false);
                        ScaffoldMessenger.of(pageContext).showSnackBar(
                          SnackBar(content: Text('Rating failed: $error')),
                        );
                      }
                    },
              child: Text(submitting ? 'Saving...' : 'Save rating'),
            ),
          ],
        ),
      ),
    );
    noteController.dispose();
  }
}

class _OwnerStaff extends StatelessWidget {
  final Salon salon;

  const _OwnerStaff({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barbers = appState.barbersForSalon(salon.id);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _showAddBarberDialog(context),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add barber'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SalonProfileSetupScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit salon'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
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
  final Barber? barber;

  const _AddBarberSheet({this.barber});

  @override
  State<_AddBarberSheet> createState() => _AddBarberSheetState();
}

class _AddBarberSheetState extends State<_AddBarberSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _experienceController;
  late final TextEditingController _resumeController;
  final _serviceSearchController = TextEditingController();
  final Set<String> _selectedServices = {};
  late String _speciality;
  String _serviceQuery = '';
  bool _servicesExpanded = false;
  bool _isSaving = false;

  bool get _isEditing => widget.barber != null;

  @override
  void initState() {
    super.initState();
    final barber = widget.barber;
    _nameController = TextEditingController(text: barber?.name ?? '');
    _phoneController = TextEditingController(text: barber?.phone ?? '');
    _experienceController = TextEditingController(
      text: '${barber?.experienceYears ?? 2}',
    );
    _resumeController = TextEditingController(
      text: barber?.resumeSummary ?? '',
    );
    _speciality = barber?.speciality.trim().isNotEmpty == true
        ? barber!.speciality.trim()
        : _barberSpecialities.first;
    _selectedServices.addAll(barber?.serviceIds ?? const <String>[]);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
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
                      _isEditing ? 'Edit barber' : 'Add barber',
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
                      key: const ValueKey('barber-name-field'),
                      controller: _nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: const ValueKey('barber-phone-field'),
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number (optional)',
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
                        for (final item in {
                          _speciality,
                          ..._barberSpecialities,
                        })
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
                      key: const ValueKey('barber-experience-field'),
                      controller: _experienceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Years of experience',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: const ValueKey('barber-resume-field'),
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
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          ListTile(
                            title: const Text('Assigned services'),
                            subtitle: Text(
                              _selectedServices.isEmpty
                                  ? 'All services by default'
                                  : '${_selectedServices.length} selected',
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
                  key: ValueKey(
                    _isEditing ? 'save-barber-changes' : 'add-barber-submit',
                  ),
                  onPressed: _isSaving ? null : () => _save(appState),
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _isEditing
                              ? Icons.save_outlined
                              : Icons.person_add_alt,
                        ),
                  label: Text(
                    _isSaving
                        ? _isEditing
                              ? 'Saving...'
                              : 'Adding...'
                        : _isEditing
                        ? 'Save changes'
                        : 'Add barber',
                  ),
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
    if (digits.isEmpty) {
      return null;
    }
    final localDigits = digits.length == 12 && digits.startsWith('91')
        ? digits.substring(2)
        : digits;
    return localDigits.length == 10 ? null : 'Enter a 10-digit phone number';
  }

  Future<void> _save(AppState appState) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final barber = widget.barber;
      if (barber == null) {
        await appState.addOwnerBarber(
          name: _nameController.text,
          phone: _phoneController.text,
          speciality: _speciality,
          experienceYears: int.tryParse(_experienceController.text) ?? 1,
          resumeSummary: _resumeController.text,
          serviceIds: _selectedServices.toList(),
        );
      } else {
        await appState.updateOwnerBarber(
          barberId: barber.id,
          name: _nameController.text,
          phone: _phoneController.text,
          speciality: _speciality,
          experienceYears: int.tryParse(_experienceController.text) ?? 1,
          resumeSummary: _resumeController.text,
          serviceIds: _selectedServices.toList(),
        );
      }
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
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
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
              borderRadius: BorderRadius.circular(8),
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
              style: const TextStyle(fontWeight: FontWeight.w600),
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
                  barber.phone.isEmpty
                      ? 'Staff profile'
                      : 'Staff profile · ${barber.phone}',
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('edit-barber-${barber.id}'),
            onPressed: () => _showEditBarberDialog(context),
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit barber',
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

  void _showEditBarberDialog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _AddBarberSheet(barber: barber),
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
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
        children: [
          Text('Sign in', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            'Manage your salon, services, staff, timings, and bookings.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('exit-salon-login'),
            onPressed: () => Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const CustomerHomeScreen()),
              (_) => false,
            ),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Back to customer home'),
          ),
          const SizedBox(height: 16),
          AuthLoginPanel(
            role: UserRole.owner,
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
    final missingItems = appState.missingSalonSetupItems(salon.id);

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
                  'Complete the remaining salon setup',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SalonProfileSetupScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.arrow_forward),
                tooltip: 'Complete salon setup',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Your salon remains visible to customers. Complete these items so the profile and booking experience are fully ready.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.primaryDark),
          ),
          const SizedBox(height: 12),
          for (final item in missingItems)
            _SetupCheckRow(done: false, label: item),
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
                fontWeight: FontWeight.w500,
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
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
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
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
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

class _StatusButton extends StatefulWidget {
  final String label;
  final BookingStatus status;
  final Booking booking;
  final IconData? icon;
  final bool isPrimary;
  final bool enabled;
  final VoidCallback? onBookingChanged;

  const _StatusButton({
    super.key,
    required this.label,
    required this.status,
    required this.booking,
    this.icon,
    this.isPrimary = false,
    this.enabled = true,
    this.onBookingChanged,
  });

  @override
  State<_StatusButton> createState() => _StatusButtonState();
}

class _StatusButtonState extends State<_StatusButton> {
  bool _submitted = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final onPressed =
        !widget.enabled ||
            _submitted ||
            widget.booking.status == widget.status ||
            appState.isBookingStatusUpdatePending(widget.booking.id)
        ? null
        : () {
            setState(() => _submitted = true);
            final isInstantDecision =
                widget.booking.isInstant &&
                widget.booking.status == BookingStatus.pending &&
                (widget.status == BookingStatus.confirmed ||
                    widget.status == BookingStatus.rejected);
            if (isInstantDecision) {
              appState.silenceOwnerBookingAlert(widget.booking.id);
            }
            final update = appState.updateBookingStatus(
              widget.booking.id,
              widget.status,
              cancelledBy: widget.status == BookingStatus.cancelled
                  ? 'salon'
                  : null,
            );
            widget.onBookingChanged?.call();
            unawaited(
              update
                  .then((_) {
                    widget.onBookingChanged?.call();
                    if (!context.mounted) {
                      return;
                    }
                    if (widget.status != BookingStatus.completed) {
                      return;
                    }
                    final service = appState.getService(
                      widget.booking.salonId,
                      widget.booking.serviceId,
                    );
                    final price = widget.booking.servicePrice > 0
                        ? widget.booking.servicePrice
                        : service?.price ?? 0;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Service completed. ₹$price added to revenue.',
                        ),
                      ),
                    );
                  })
                  .catchError((Object error) {
                    widget.onBookingChanged?.call();
                    if (!context.mounted) {
                      return;
                    }
                    setState(() => _submitted = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Status update failed: $error')),
                    );
                  }),
            );
          };
    final actionLabel = _submitted
        ? _pendingLabel(widget.status)
        : widget.label;
    final actionIcon = _submitted
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(widget.icon ?? Icons.arrow_forward);
    if (widget.isPrimary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: actionIcon,
        label: Text(actionLabel),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: actionIcon,
      label: Text(actionLabel),
    );
  }

  String _pendingLabel(BookingStatus status) => switch (status) {
    BookingStatus.confirmed => 'Accepting...',
    BookingStatus.rejected => 'Rejecting...',
    BookingStatus.cancelled => 'Cancelling...',
    BookingStatus.inProgress => 'Starting...',
    BookingStatus.completed => 'Completing...',
    BookingStatus.pending => 'Updating...',
  };
}
