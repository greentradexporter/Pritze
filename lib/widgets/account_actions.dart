import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';
import 'status_chip.dart';

enum _AccountAction { notifications, logout }

class AccountOverflowMenu extends StatelessWidget {
  final UserRole role;
  final bool canLogout;
  final Future<void> Function()? onLoggedOut;

  const AccountOverflowMenu({
    super.key,
    required this.role,
    required this.canLogout,
    this.onLoggedOut,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final count = notificationCount(appState, role);
    return PopupMenuButton<_AccountAction>(
      tooltip: 'Account menu',
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 9 ? '9+' : '$count'),
        child: const Icon(Icons.more_vert),
      ),
      onSelected: (action) async {
        switch (action) {
          case _AccountAction.notifications:
            await showNotificationCenter(context, role);
          case _AccountAction.logout:
            final didLogout = await confirmAndLogout(context);
            if (didLogout && onLoggedOut != null) {
              await onLoggedOut!();
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _AccountAction.notifications,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.notifications_outlined),
            title: Text('Notifications'),
          ),
        ),
        if (canLogout)
          const PopupMenuItem(
            value: _AccountAction.logout,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('Log out'),
            ),
          ),
      ],
    );
  }
}

Future<bool> confirmAndLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.logout, color: AppColors.coral),
      title: const Text('Log out?'),
      content: const Text(
        'Are you sure you want to log out of this account?',
        textAlign: TextAlign.center,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Stay logged in'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Log out'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return false;
  }
  await AppStateScope.read(context).signOutActiveUser();
  return true;
}

int notificationCount(AppState state, UserRole role) {
  return switch (role) {
    UserRole.customer => state.customerBookings.length,
    UserRole.barber =>
      (state.currentJoinRequest == null ? 0 : 1) +
          (state.currentBarber == null
              ? 0
              : state.bookingsForBarber(state.currentBarber!.id).length),
    UserRole.owner => state.pendingJoinRequests.length,
  };
}

Future<void> showNotificationCenter(BuildContext context, UserRole role) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _NotificationSheet(role: role),
  );
}

class _NotificationSheet extends StatelessWidget {
  final UserRole role;

  const _NotificationSheet({required this.role});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final items = _items(state);
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Notifications',
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
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? const EmptyState(
                    icon: Icons.notifications_none,
                    title: 'No notifications yet',
                    message: 'Booking and approval updates will appear here.',
                  )
                : RefreshIndicator(
                    onRefresh: state.refresh,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(18),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => items[index],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _items(AppState state) {
    if (role == UserRole.customer) {
      return [
        for (final booking in state.customerBookings.take(20))
          _BookingNotification(booking: booking),
      ];
    }
    if (role == UserRole.barber) {
      final barber = state.currentBarber;
      return [
        if (state.currentJoinRequest case final request?)
          _JoinNotification(request: request),
        if (barber != null)
          for (final booking in state.bookingsForBarber(barber.id).take(20))
            _BookingNotification(booking: booking),
      ];
    }
    return [
      for (final request in state.pendingJoinRequests.take(20))
        _JoinNotification(request: request),
    ];
  }
}

class _BookingNotification extends StatelessWidget {
  final Booking booking;

  const _BookingNotification({required this.booking});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final salon = state.getSalon(booking.salonId);
    final service = state.getService(booking.salonId, booking.serviceId);
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SoftIconBox(
            icon: Icons.event_available,
            color: AppColors.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _bookingTitle(booking.status),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${service?.name ?? booking.serviceName} at ${salon?.name ?? 'your salon'} · '
                  '${state.formatDate(booking.start)}, ${state.formatTime(booking.start)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                StatusChip(status: booking.status),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _bookingTitle(BookingStatus status) => switch (status) {
    BookingStatus.pending => 'Booking request sent',
    BookingStatus.confirmed => 'Booking confirmed',
    BookingStatus.inProgress => 'Service started',
    BookingStatus.completed => 'Visit completed',
    BookingStatus.cancelled => 'Booking cancelled',
  };
}

class _JoinNotification extends StatelessWidget {
  final JoinRequest request;

  const _JoinNotification({required this.request});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final salon = state.getSalon(request.salonId);
    return GlassCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const SoftIconBox(
          icon: Icons.how_to_reg,
          color: AppColors.goldDeep,
          size: 42,
        ),
        title: Text('Join request ${request.status.label.toLowerCase()}'),
        subtitle: Text('${request.barberName} · ${salon?.name ?? 'Salon'}'),
      ),
    );
  }
}
