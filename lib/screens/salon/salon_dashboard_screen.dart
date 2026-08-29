import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_error_dialog.dart';
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

  Future<void> _showPromotionalCredits(BuildContext context, String salonId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          18 + MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: _SalonPromotionalCreditsSheet(salonId: salonId),
        ),
      ),
    );
  }

  Future<void> _openRevenueDetails(BuildContext context, String salonId) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SalonRevenueDetailsScreen(salonId: salonId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.ownerSalon;

    if (!appState.hasActiveOwnerSession) {
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
                  onRevenueDetailsOpened: () =>
                      _openRevenueDetails(dashboardContext, salon.id),
                  onPromotionalCreditsOpened: () =>
                      _showPromotionalCredits(dashboardContext, salon.id),
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

class SalonRevenueDetailsScreen extends StatefulWidget {
  final String salonId;

  const SalonRevenueDetailsScreen({super.key, required this.salonId});

  @override
  State<SalonRevenueDetailsScreen> createState() =>
      _SalonRevenueDetailsScreenState();
}

class _SalonRevenueDetailsScreenState extends State<SalonRevenueDetailsScreen> {
  _RevenueRangePreset _preset = _RevenueRangePreset.thisMonth;
  DateTimeRange? _customRange;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.salonId);
    final completedBookings = appState
        .bookingsForSalon(widget.salonId)
        .where((booking) => booking.status == BookingStatus.completed)
        .toList(growable: false);
    final range = _selectedRange();
    final rangeBookings = completedBookings
        .where((booking) => range.contains(_bookingRevenueDate(booking)))
        .toList(growable: false);
    final totals = _RevenueTotals.fromBookings(rangeBookings);
    final weekly = _recentWeeklyRanges()
        .map(
          (item) => _RevenuePeriodSummary(
            label: item.label,
            totals: _RevenueTotals.fromBookings(
              completedBookings
                  .where(
                    (booking) => item.contains(_bookingRevenueDate(booking)),
                  )
                  .toList(growable: false),
            ),
          ),
        )
        .toList(growable: false);
    final monthly = _recentMonthlyRanges()
        .map(
          (item) => _RevenuePeriodSummary(
            label: item.label,
            totals: _RevenueTotals.fromBookings(
              completedBookings
                  .where(
                    (booking) => item.contains(_bookingRevenueDate(booking)),
                  )
                  .toList(growable: false),
            ),
          ),
        )
        .toList(growable: false);
    final serviceRows = _serviceRevenueRows(appState, rangeBookings);
    final barberRows = _barberRevenueRows(appState, rangeBookings);

    return Scaffold(
      appBar: AppBar(title: const Text('Revenue details')),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
        children: [
          AppHeroHeader(
            eyebrow: salon == null
                ? 'Salon revenue'
                : 'Revenue at ${salon.displayName}',
            title: _money(totals.totalEarning),
            subtitle:
                '${totals.completedBookings} completed appointments · ${range.label}',
            icon: Icons.query_stats_outlined,
          ),
          const SizedBox(height: 14),
          _RevenueRangePicker(
            selected: _preset,
            rangeLabel: range.label,
            onSelected: (preset) async {
              if (preset == _RevenueRangePreset.custom) {
                await _pickCustomRange();
                return;
              }
              setState(() => _preset = preset);
            },
          ),
          const SizedBox(height: 14),
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.45,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _MetricCard(
                icon: Icons.payments_outlined,
                label: 'Salon earning',
                value: _money(totals.totalEarning),
                color: AppColors.success,
              ),
              _MetricCard(
                icon: Icons.receipt_long_outlined,
                label: 'Bookings',
                value: '${totals.completedBookings}',
                color: AppColors.primary,
              ),
              _MetricCard(
                icon: Icons.point_of_sale_outlined,
                label: 'Counter collection',
                value: _money(totals.customerCollection),
                color: AppColors.goldDeep,
              ),
              _MetricCard(
                icon: Icons.timeline_outlined,
                label: 'Avg order',
                value: _money(totals.averageOrderValue),
                color: AppColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SalonEarningBreakdown(
            serviceValue: totals.serviceValue,
            customerCollection: totals.customerCollection,
            pritzeEarning: totals.pritzeContribution,
            discountSupport: totals.discountSupport,
            proinReimbursement: totals.proinReimbursement,
            totalEarning: totals.totalEarning,
          ),
          const SizedBox(height: 18),
          const SectionHeader(title: 'Week by week'),
          const SizedBox(height: 10),
          _RevenuePeriodCard(periods: weekly),
          const SizedBox(height: 18),
          const SectionHeader(title: 'Month by month'),
          const SizedBox(height: 10),
          _RevenuePeriodCard(periods: monthly),
          const SizedBox(height: 18),
          const SectionHeader(title: 'Revenue by service'),
          const SizedBox(height: 10),
          _RevenueRankedCard(
            emptyText: 'Completed service revenue will appear here.',
            rows: serviceRows,
          ),
          const SizedBox(height: 18),
          const SectionHeader(title: 'Revenue by barber'),
          const SizedBox(height: 10),
          _RevenueRankedCard(
            emptyText: 'Completed barber revenue will appear here.',
            rows: barberRows,
          ),
          const SizedBox(height: 18),
          const SectionHeader(title: 'Discount and Proin impact'),
          const SizedBox(height: 10),
          GlassCard(
            child: Column(
              children: [
                _EarningLine(
                  label: 'Customer discounts',
                  amount: totals.customerDiscount,
                  color: AppColors.coral,
                ),
                const SizedBox(height: 9),
                _EarningLine(
                  label: 'Pritze discount support',
                  amount: totals.discountSupport,
                  color: AppColors.success,
                ),
                const SizedBox(height: 9),
                _EarningLine(
                  label: 'Reward reimbursement',
                  amount: totals.proinReimbursement,
                  color: AppColors.success,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
                _EarningLine(
                  label: 'Total Pritze contribution',
                  amount: totals.pritzeContribution,
                  emphasized: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final initial =
        _customRange ??
        DateTimeRange(
          start: _startOfDay(now.subtract(const Duration(days: 6))),
          end: _startOfDay(now).add(const Duration(days: 1)),
        );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(
        start: _startOfDay(initial.start),
        end: _startOfDay(initial.end),
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _preset = _RevenueRangePreset.custom;
      _customRange = DateTimeRange(
        start: _startOfDay(picked.start),
        end: _startOfDay(picked.end).add(const Duration(days: 1)),
      );
    });
  }

  _RevenueDateRange _selectedRange() {
    final now = DateTime.now();
    final today = _startOfDay(now);
    return switch (_preset) {
      _RevenueRangePreset.today => _RevenueDateRange(
        label: 'Today',
        start: today,
        end: today.add(const Duration(days: 1)),
      ),
      _RevenueRangePreset.thisWeek => _RevenueDateRange(
        label: 'This week',
        start: _startOfWeek(now),
        end: _startOfWeek(now).add(const Duration(days: 7)),
      ),
      _RevenueRangePreset.thisMonth => _RevenueDateRange(
        label: 'This month',
        start: DateTime(now.year, now.month),
        end: DateTime(now.year, now.month + 1),
      ),
      _RevenueRangePreset.lastMonth => _RevenueDateRange(
        label: 'Last month',
        start: DateTime(now.year, now.month - 1),
        end: DateTime(now.year, now.month),
      ),
      _RevenueRangePreset.custom => _customRevenueRange(now),
    };
  }

  _RevenueDateRange _customRevenueRange(DateTime now) {
    final range =
        _customRange ??
        DateTimeRange(
          start: _startOfDay(now.subtract(const Duration(days: 6))),
          end: _startOfDay(now).add(const Duration(days: 1)),
        );
    return _RevenueDateRange(
      label:
          '${_shortDate(range.start)} – ${_shortDate(range.end.subtract(const Duration(days: 1)))}',
      start: range.start,
      end: range.end,
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
          title: '₹${appState.totalCollection(salon.id)} total earning',
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
                        SnackBar(
                          content: Text(
                            friendlyErrorMessage(
                              error,
                              fallback:
                                  'Instant booking availability could not be updated. Try again.',
                            ),
                          ),
                        ),
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
            label: [
              'Service ₹${booking.resolvedServicePrice(service)}',
              'customer pays ₹${booking.customerPayableAmount}',
              if (booking.hasDiscount) 'discount ₹${booking.discountAmount}',
              if (booking.pritzePayoutAmount > 0)
                'discount support ₹${booking.pritzePayoutAmount}',
              if (booking.hasProin)
                'Proin reimbursement ₹${booking.proinAppliedAmount}',
              if (booking.hasDiscount || booking.hasProin)
                'Pritze contribution ₹${booking.totalPritzeContribution}',
              if (booking.hasDiscount || booking.hasProin)
                'total ₹${booking.salonTotalEarning}',
            ].join(' · '),
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
                          SnackBar(
                            content: Text(
                              friendlyErrorMessage(
                                error,
                                fallback:
                                    'The customer rating could not be saved. Try again.',
                              ),
                            ),
                          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              friendlyErrorMessage(
                error,
                fallback: 'The barber details could not be saved. Try again.',
              ),
            ),
          ),
        );
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
            content: Text(
              friendlyErrorMessage(
                error,
                fallback: accept
                    ? 'The join request could not be accepted. Try again.'
                    : 'The join request could not be rejected. Try again.',
              ),
            ),
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
                    SnackBar(
                      content: Text(
                        friendlyErrorMessage(
                          error,
                          fallback:
                              'The barber could not be removed. Try again.',
                        ),
                      ),
                    ),
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
                MaterialPageRoute(builder: (_) => const SalonDashboardScreen()),
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
    final opensTeam = _setupActionOpensTeam(missingItems);

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
                key: const ValueKey('complete-salon-setup-action'),
                onPressed: () => _openRemainingSetup(context, missingItems),
                icon: const Icon(Icons.arrow_forward),
                tooltip: opensTeam
                    ? 'Complete team setup'
                    : 'Complete salon setup',
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

  bool _setupActionOpensTeam(List<String> missingItems) {
    final normalized = missingItems
        .map((item) => item.trim().toLowerCase())
        .toList(growable: false);
    final hasTeamWork = normalized.any(
      (item) => item.contains('barber') || item.contains('team'),
    );
    final hasProfileWork = normalized.any(
      (item) =>
          item.contains('salon name') ||
          item.contains('owner name') ||
          item.contains('salon address') ||
          item.contains('owner phone') ||
          item.contains('owner email') ||
          item.contains('opening') ||
          item.contains('closing') ||
          item == 'add at least one available service' ||
          item.contains('save the salon profile'),
    );
    return hasTeamWork && !hasProfileWork;
  }

  void _openRemainingSetup(BuildContext context, List<String> missingItems) {
    if (_setupActionOpensTeam(missingItems)) {
      final tabController = DefaultTabController.maybeOf(context);
      if (tabController != null) {
        tabController.animateTo(2);
        return;
      }
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SalonProfileSetupScreen()));
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

class _SalonPromotionCreditCard extends StatefulWidget {
  final String salonId;

  const _SalonPromotionCreditCard({required this.salonId});

  @override
  State<_SalonPromotionCreditCard> createState() =>
      _SalonPromotionCreditCardState();
}

class _SalonPromotionCreditCardState extends State<_SalonPromotionCreditCard> {
  final _couponController = TextEditingController();
  final _couponFocusNode = FocusNode();
  bool _loading = false;
  bool _couponSubmitting = false;
  String _error = '';
  String _couponMessage = '';
  bool _couponSuccess = false;

  @override
  void dispose() {
    _couponController.dispose();
    _couponFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await AppStateScope.read(context).refreshSalonProinWallet(widget.salonId);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'Promotional credits could not be refreshed. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _claimCoupon() async {
    if (_couponSubmitting) return;
    final code = _couponController.text.trim();
    if (code.isEmpty) {
      _couponFocusNode.requestFocus();
      setState(() {
        _couponSuccess = false;
        _couponMessage = 'Enter a salon coupon code.';
      });
      return;
    }
    setState(() {
      _couponSubmitting = true;
      _couponMessage = '';
    });
    try {
      final result = await AppStateScope.read(
        context,
      ).claimSalonProinCoupon(salonId: widget.salonId, code: code);
      if (!mounted) return;
      _couponController.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      final expiresAt = result.expiresAt;
      final expiryText = expiresAt == null
          ? ''
          : ' Valid until ${_salonProinDate(expiresAt)}.';
      setState(() {
        _couponSuccess = true;
        _couponMessage = result.alreadyClaimed
            ? 'This coupon was already added to this salon.'
            : '${result.amountProin} credits added to this salon.$expiryText';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _couponSuccess = false;
        _couponMessage = friendlyErrorMessage(
          error,
          fallback: 'This salon coupon could not be applied. Try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _couponSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = AppStateScope.watch(
      context,
    ).salonProinWallet(widget.salonId);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.toll_outlined,
                color: AppColors.amber,
                size: 42,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Promotional credits',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Credits for eligible salon campaigns',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _loading ? null : _refresh,
                tooltip: 'Refresh promotional credits',
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _SalonProinMetric(
                  label: 'Balance',
                  value: '${wallet.availableProin} credits',
                  valueColor: wallet.availableProin < 0
                      ? AppColors.coral
                      : null,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _SalonProinMetric(
                  label: 'Can spend',
                  value: '${wallet.effectiveSpendableProin} credits',
                  valueColor: AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: _SalonProinMetric(
                  label: 'Credit line',
                  value: '${wallet.creditLimitProin} credits',
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _SalonProinMetric(
                  label: 'Reserved',
                  value: '${wallet.reservedProin} credits',
                ),
              ),
            ],
          ),
          if (wallet.isUsingCreditLine) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: AppColors.coral.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.coral.withValues(alpha: 0.22),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: AppColors.coral,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Using ${wallet.creditLineUsedProin} credits from the salon credit line.',
                      style: const TextStyle(
                        color: AppColors.coral,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.confirmation_number_outlined,
                  size: 20,
                  color: AppColors.goldDeep,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('salon-proin-coupon-field'),
                    controller: _couponController,
                    focusNode: _couponFocusNode,
                    enabled: !_couponSubmitting,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    maxLength: 20,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        return newValue.copyWith(
                          text: newValue.text.toUpperCase(),
                          selection: TextSelection.collapsed(
                            offset: newValue.text.length,
                          ),
                        );
                      }),
                    ],
                    decoration: const InputDecoration(
                      hintText: 'Enter salon coupon code',
                      border: InputBorder.none,
                      counterText: '',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _claimCoupon(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('salon-proin-coupon-apply'),
                  tooltip: 'Avail salon coupon',
                  onPressed: _couponSubmitting ? null : _claimCoupon,
                  icon: _couponSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                ),
              ],
            ),
          ),
          if (_couponMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _couponMessage,
              style: TextStyle(
                color: _couponSuccess ? AppColors.success : AppColors.coral,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (wallet.expiringLots.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              'Upcoming expiries',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            for (final lot in wallet.expiringLots.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    const Icon(
                      Icons.schedule_outlined,
                      size: 16,
                      color: AppColors.amber,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${lot.amountProin} credits · ${_salonProinSourceLabel(lot.sourceType)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      _salonProinDate(lot.expiresAt),
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _error,
              style: const TextStyle(color: AppColors.coral, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'Promotional credits fund eligible salon campaigns. If the balance is negative, the salon is using the approved credit line; new spending stops once the limit is reached.',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _SalonPromotionalCreditsSheet extends StatelessWidget {
  final String salonId;

  const _SalonPromotionalCreditsSheet({required this.salonId});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SalonPromotionCreditCard(salonId: salonId),
        const SizedBox(height: 14),
        _SalonEarningBreakdown(
          serviceValue: appState.totalOriginalServiceValue(salonId),
          customerCollection: appState.totalCustomerCounterCollection(salonId),
          pritzeEarning: appState.totalPritzeEarnings(salonId),
          discountSupport: appState.totalDiscountPritzeEarnings(salonId),
          proinReimbursement: appState.totalProinReimbursements(salonId),
          totalEarning: appState.totalCollection(salonId),
        ),
      ],
    );
  }
}

class _SalonProinMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _SalonProinMetric({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String _salonProinDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/'
    '${date.month.toString().padLeft(2, '0')}/${date.year}';

String _salonProinSourceLabel(String value) => switch (value.trim()) {
  'coupon' => 'Coupon',
  'referral_salon' => 'Salon referral',
  'promotion' => 'Promotion',
  'manual' => 'Support credit',
  _ => 'Reward',
};

class _SalonEarningBreakdown extends StatelessWidget {
  final int serviceValue;
  final int customerCollection;
  final int pritzeEarning;
  final int discountSupport;
  final int proinReimbursement;
  final int totalEarning;

  const _SalonEarningBreakdown({
    required this.serviceValue,
    required this.customerCollection,
    required this.pritzeEarning,
    required this.discountSupport,
    required this.proinReimbursement,
    required this.totalEarning,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SoftIconBox(
                icon: Icons.account_balance_wallet_outlined,
                color: AppColors.primary,
                size: 42,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Earning breakdown',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _EarningLine(label: 'Service value', amount: serviceValue),
          const SizedBox(height: 9),
          _EarningLine(
            label: 'Collected from customers',
            amount: customerCollection,
          ),
          const SizedBox(height: 9),
          _EarningLine(
            label: 'Pritze earning',
            amount: pritzeEarning,
            color: AppColors.success,
          ),
          if (pritzeEarning > 0) ...[
            const SizedBox(height: 7),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                children: [
                  _EarningLine(
                    label: 'Discount support',
                    amount: discountSupport,
                    color: AppColors.success,
                  ),
                  const SizedBox(height: 7),
                  _EarningLine(
                    label: 'Reward reimbursement',
                    amount: proinReimbursement,
                    color: AppColors.success,
                  ),
                ],
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          _EarningLine(
            label: 'Total salon earning',
            amount: totalEarning,
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

class _EarningLine extends StatelessWidget {
  final String label;
  final int amount;
  final Color? color;
  final bool emphasized;

  const _EarningLine({
    required this.label,
    required this.amount,
    this.color,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color ?? AppColors.ink,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          '₹$amount',
          style: TextStyle(
            color: color ?? AppColors.ink,
            fontSize: emphasized ? 19 : 14,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

enum _RevenueRangePreset { today, thisWeek, thisMonth, lastMonth, custom }

class _RevenueRangePicker extends StatelessWidget {
  final _RevenueRangePreset selected;
  final String rangeLabel;
  final ValueChanged<_RevenueRangePreset> onSelected;

  const _RevenueRangePicker({
    required this.selected,
    required this.rangeLabel,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            rangeLabel,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final preset in _RevenueRangePreset.values) ...[
                  ChoiceChip(
                    selected: selected == preset,
                    label: Text(_revenuePresetLabel(preset)),
                    onSelected: (_) => onSelected(preset),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RevenueDateRange {
  final String label;
  final DateTime start;
  final DateTime end;

  const _RevenueDateRange({
    required this.label,
    required this.start,
    required this.end,
  });

  bool contains(DateTime value) =>
      !value.isBefore(start) && value.isBefore(end);
}

class _RevenueTotals {
  final int completedBookings;
  final int serviceValue;
  final int customerCollection;
  final int customerDiscount;
  final int discountSupport;
  final int proinReimbursement;
  final int pritzeContribution;
  final int totalEarning;

  const _RevenueTotals({
    required this.completedBookings,
    required this.serviceValue,
    required this.customerCollection,
    required this.customerDiscount,
    required this.discountSupport,
    required this.proinReimbursement,
    required this.pritzeContribution,
    required this.totalEarning,
  });

  factory _RevenueTotals.fromBookings(List<Booking> bookings) {
    return _RevenueTotals(
      completedBookings: bookings.length,
      serviceValue: bookings.fold(
        0,
        (total, booking) => total + _bookingOriginalValue(booking),
      ),
      customerCollection: bookings.fold(
        0,
        (total, booking) => total + booking.customerPayableAmount,
      ),
      customerDiscount: bookings.fold(
        0,
        (total, booking) => total + booking.discountAmount,
      ),
      discountSupport: bookings.fold(
        0,
        (total, booking) => total + booking.pritzePayoutAmount,
      ),
      proinReimbursement: bookings.fold(
        0,
        (total, booking) => total + booking.proinRedeemedAmount,
      ),
      pritzeContribution: bookings.fold(
        0,
        (total, booking) => total + booking.totalPritzeContribution,
      ),
      totalEarning: bookings.fold(
        0,
        (total, booking) => total + booking.salonTotalEarning,
      ),
    );
  }

  int get averageOrderValue =>
      completedBookings == 0 ? 0 : (totalEarning / completedBookings).round();
}

class _RevenuePeriodSummary {
  final String label;
  final _RevenueTotals totals;

  const _RevenuePeriodSummary({required this.label, required this.totals});
}

class _RevenuePeriodCard extends StatelessWidget {
  final List<_RevenuePeriodSummary> periods;

  const _RevenuePeriodCard({required this.periods});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        children: [
          for (var index = 0; index < periods.length; index++) ...[
            _RevenuePeriodRow(summary: periods[index]),
            if (index != periods.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
          ],
        ],
      ),
    );
  }
}

class _RevenuePeriodRow extends StatelessWidget {
  final _RevenuePeriodSummary summary;

  const _RevenuePeriodRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                summary.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                '${summary.totals.completedBookings} completed · ${_money(summary.totals.customerCollection)} counter',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(
          _money(summary.totals.totalEarning),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _RevenueRankedRow {
  final String label;
  final int amount;
  final int count;

  const _RevenueRankedRow({
    required this.label,
    required this.amount,
    required this.count,
  });
}

class _RevenueRankedCard extends StatelessWidget {
  final String emptyText;
  final List<_RevenueRankedRow> rows;

  const _RevenueRankedCard({required this.emptyText, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return GlassCard(child: Text(emptyText));
    }
    final maxAmount = rows
        .map((row) => row.amount)
        .fold<int>(0, (max, amount) => amount > max ? amount : max);
    return GlassCard(
      child: Column(
        children: [
          for (var index = 0; index < rows.take(10).length; index++) ...[
            _RevenueRankedTile(row: rows[index], maxAmount: maxAmount),
            if (index != rows.take(10).length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
          ],
        ],
      ),
    );
  }
}

class _RevenueRankedTile extends StatelessWidget {
  final _RevenueRankedRow row;
  final int maxAmount;

  const _RevenueRankedTile({required this.row, required this.maxAmount});

  @override
  Widget build(BuildContext context) {
    final fraction = maxAmount <= 0 ? 0.0 : row.amount / maxAmount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                row.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              _money(row.amount),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 5),
        LinearProgressIndicator(
          value: fraction.clamp(0.0, 1.0),
          minHeight: 6,
          borderRadius: BorderRadius.circular(99),
          backgroundColor: AppColors.canvas,
          color: AppColors.primary,
        ),
        const SizedBox(height: 5),
        Text(
          '${row.count} completed',
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

DateTime _bookingRevenueDate(Booking booking) =>
    booking.completedAt ?? booking.start;

int _bookingOriginalValue(Booking booking) {
  final breakdownTotal = booking.servicePriceBreakdown.values.fold<int>(
    0,
    (total, price) => total + price,
  );
  return breakdownTotal > 0 ? breakdownTotal : booking.servicePrice;
}

List<_RevenueRankedRow> _serviceRevenueRows(
  AppState appState,
  List<Booking> bookings,
) {
  final amounts = <String, int>{};
  final counts = <String, int>{};
  for (final booking in bookings) {
    final breakdown = booking.servicePriceBreakdown.isNotEmpty
        ? booking.servicePriceBreakdown
        : <String, int>{booking.serviceId: booking.servicePrice};
    final originalTotal = breakdown.values.fold<int>(
      0,
      (total, price) => total + price,
    );
    if (originalTotal <= 0 || booking.salonTotalEarning <= 0) {
      continue;
    }
    var assigned = 0;
    final entries = breakdown.entries.toList(growable: false);
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final amount = index == entries.length - 1
          ? booking.salonTotalEarning - assigned
          : (booking.salonTotalEarning * entry.value / originalTotal).floor();
      assigned += amount;
      final serviceName =
          appState.getService(booking.salonId, entry.key)?.name ??
          (entries.length == 1
              ? booking.resolvedServiceName()
              : 'Booked service');
      amounts[serviceName] = (amounts[serviceName] ?? 0) + amount;
      counts[serviceName] = (counts[serviceName] ?? 0) + 1;
    }
  }
  return amounts.entries
      .map(
        (entry) => _RevenueRankedRow(
          label: entry.key,
          amount: entry.value,
          count: counts[entry.key] ?? 0,
        ),
      )
      .toList(growable: false)
    ..sort((left, right) => right.amount.compareTo(left.amount));
}

List<_RevenueRankedRow> _barberRevenueRows(
  AppState appState,
  List<Booking> bookings,
) {
  final amounts = <String, int>{};
  final counts = <String, int>{};
  for (final booking in bookings) {
    if (booking.salonTotalEarning <= 0) {
      continue;
    }
    final barberName = booking.barberId.trim().isEmpty
        ? 'Any available barber'
        : appState.getBarber(booking.barberId)?.name ?? 'Former team member';
    amounts[barberName] =
        (amounts[barberName] ?? 0) + booking.salonTotalEarning;
    counts[barberName] = (counts[barberName] ?? 0) + 1;
  }
  return amounts.entries
      .map(
        (entry) => _RevenueRankedRow(
          label: entry.key,
          amount: entry.value,
          count: counts[entry.key] ?? 0,
        ),
      )
      .toList(growable: false)
    ..sort((left, right) => right.amount.compareTo(left.amount));
}

List<_RevenueDateRange> _recentWeeklyRanges() {
  final currentWeekStart = _startOfWeek(DateTime.now());
  return List.generate(8, (index) {
    final start = currentWeekStart.subtract(Duration(days: index * 7));
    final end = start.add(const Duration(days: 7));
    return _RevenueDateRange(
      label: index == 0
          ? 'This week'
          : '${_shortDate(start)} – ${_shortDate(end.subtract(const Duration(days: 1)))}',
      start: start,
      end: end,
    );
  });
}

List<_RevenueDateRange> _recentMonthlyRanges() {
  final now = DateTime.now();
  return List.generate(6, (index) {
    final start = DateTime(now.year, now.month - index);
    final end = DateTime(now.year, now.month - index + 1);
    return _RevenueDateRange(
      label: index == 0 ? 'This month' : _monthYear(start),
      start: start,
      end: end,
    );
  });
}

DateTime _startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _startOfWeek(DateTime value) {
  final day = _startOfDay(value);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

String _revenuePresetLabel(_RevenueRangePreset preset) => switch (preset) {
  _RevenueRangePreset.today => 'Today',
  _RevenueRangePreset.thisWeek => 'This week',
  _RevenueRangePreset.thisMonth => 'This month',
  _RevenueRangePreset.lastMonth => 'Last month',
  _RevenueRangePreset.custom => 'Custom',
};

String _money(int amount) => '₹$amount';

String _shortDate(DateTime date) => '${date.day} ${_monthName(date.month)}';

String _monthYear(DateTime date) => '${_monthName(date.month)} ${date.year}';

String _monthName(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month.clamp(1, 12) - 1];

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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Service completed. ₹${widget.booking.salonTotalEarning} total earning added, including ₹${widget.booking.totalPritzeContribution} from Pritze.',
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
                      SnackBar(
                        content: Text(
                          friendlyErrorMessage(
                            error,
                            fallback:
                                'The booking status could not be updated. Try again.',
                          ),
                        ),
                      ),
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
