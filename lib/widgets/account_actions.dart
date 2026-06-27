import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';
import 'status_chip.dart';

enum _AccountAction { notifications, logout }

enum AppNotificationDestination { bookings, overview, team }

String _bookingNotificationKey(Booking booking) =>
    'booking:${booking.id}:${booking.status.name}';

String _joinNotificationKey(JoinRequest request) =>
    'join:${request.id}:${request.status.name}';

class AccountOverflowMenu extends StatelessWidget {
  final UserRole role;
  final bool canLogout;
  final Future<void> Function()? onLoggedOut;
  final ValueChanged<AppNotificationDestination>? onNotificationOpened;

  const AccountOverflowMenu({
    super.key,
    required this.role,
    required this.canLogout,
    this.onLoggedOut,
    this.onNotificationOpened,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final count = unreadNotificationCount(appState, role);
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
            appState.markNotificationsSeen(
              role,
              notificationKeys(appState, role),
            );
            await showNotificationCenter(
              context,
              role,
              onNotificationOpened: onNotificationOpened,
            );
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

int unreadNotificationCount(AppState state, UserRole role) {
  return notificationKeys(
    state,
    role,
  ).where((key) => !state.hasSeenNotification(role, key)).length;
}

List<String> notificationKeys(AppState state, UserRole role) {
  final keys = switch (role) {
    UserRole.customer => [
      for (final booking in state.customerBookings)
        _bookingNotificationKey(booking),
    ],
    UserRole.barber => [
      if (state.currentJoinRequest case final request?)
        if (request.status != JoinRequestStatus.withdrawn)
          _joinNotificationKey(request),
      if (state.currentBarber case final barber?)
        for (final booking in state.bookingsForBarber(barber.id))
          _bookingNotificationKey(booking),
    ],
    UserRole.owner => [
      for (final booking in state.bookingsForSalon(state.ownerSalonId))
        _bookingNotificationKey(booking),
      for (final request in state.pendingJoinRequests)
        _joinNotificationKey(request),
    ],
  };
  return keys
      .where((key) => !state.hasDismissedNotification(role, key))
      .toList();
}

Future<void> showNotificationCenter(
  BuildContext context,
  UserRole role, {
  ValueChanged<AppNotificationDestination>? onNotificationOpened,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _NotificationSheet(
      role: role,
      onNotificationOpened: onNotificationOpened,
    ),
  );
}

class _NotificationSheet extends StatelessWidget {
  final UserRole role;
  final ValueChanged<AppNotificationDestination>? onNotificationOpened;

  const _NotificationSheet({required this.role, this.onNotificationOpened});

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
          if (!state.hasDismissedNotification(
            role,
            _bookingNotificationKey(booking),
          ))
            _BookingNotification(
              booking: booking,
              role: role,
              onOpen: () => _open(AppNotificationDestination.bookings),
            ),
      ];
    }
    if (role == UserRole.barber) {
      final barber = state.currentBarber;
      return [
        if (state.currentJoinRequest case final request?)
          if (request.status != JoinRequestStatus.withdrawn &&
              !state.hasDismissedNotification(
                role,
                _joinNotificationKey(request),
              ))
            _JoinNotification(
              request: request,
              role: role,
              onOpen: () => _open(AppNotificationDestination.team),
            ),
        if (barber != null)
          for (final booking in state.bookingsForBarber(barber.id).take(20))
            if (!state.hasDismissedNotification(
              role,
              _bookingNotificationKey(booking),
            ))
              _BookingNotification(
                booking: booking,
                role: role,
                onOpen: () => _open(AppNotificationDestination.bookings),
              ),
      ];
    }
    return [
      for (final booking in state.bookingsForSalon(state.ownerSalonId).take(20))
        if (!state.hasDismissedNotification(
          role,
          _bookingNotificationKey(booking),
        ))
          _BookingNotification(
            booking: booking,
            role: role,
            onOpen: () => _open(AppNotificationDestination.bookings),
          ),
      for (final request in state.pendingJoinRequests.take(20))
        if (!state.hasDismissedNotification(
          role,
          _joinNotificationKey(request),
        ))
          _JoinNotification(
            request: request,
            role: role,
            onOpen: () => _open(AppNotificationDestination.overview),
          ),
    ];
  }

  void _open(AppNotificationDestination destination) {
    onNotificationOpened?.call(destination);
  }
}

class _BookingNotification extends StatelessWidget {
  final Booking booking;
  final UserRole role;
  final VoidCallback onOpen;

  const _BookingNotification({
    required this.booking,
    required this.role,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final salon = state.getSalon(booking.salonId);
    final service = state.getService(booking.salonId, booking.serviceId);
    final notificationKey = _bookingNotificationKey(booking);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.pop(context);
        WidgetsBinding.instance.addPostFrameCallback((_) => onOpen());
      },
      child: GlassCard(
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
                    _bookingTitle(booking.status, role),
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
            IconButton(
              onPressed: () => state.dismissNotification(role, notificationKey),
              icon: const Icon(Icons.delete_outline_rounded),
              color: AppColors.muted,
              tooltip: 'Delete notification',
            ),
          ],
        ),
      ),
    );
  }

  String _bookingTitle(BookingStatus status, UserRole role) => switch (status) {
    BookingStatus.pending =>
      role == UserRole.owner ? 'New booking request' : 'Booking request sent',
    BookingStatus.confirmed => 'Booking confirmed',
    BookingStatus.inProgress => 'Service started',
    BookingStatus.completed => 'Visit completed',
    BookingStatus.cancelled => 'Booking cancelled',
    BookingStatus.rejected => 'Booking rejected',
  };
}

class _JoinNotification extends StatelessWidget {
  final JoinRequest request;
  final UserRole role;
  final VoidCallback onOpen;

  const _JoinNotification({
    required this.request,
    required this.role,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final salon = state.getSalon(request.salonId);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.pop(context);
        WidgetsBinding.instance.addPostFrameCallback((_) => onOpen());
      },
      child: GlassCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const SoftIconBox(
            icon: Icons.how_to_reg,
            color: AppColors.goldDeep,
            size: 42,
          ),
          title: Text('Join request ${request.status.label.toLowerCase()}'),
          subtitle: Text('${request.barberName} · ${salon?.name ?? 'Salon'}'),
          trailing: IconButton(
            onPressed: () =>
                state.dismissNotification(role, _joinNotificationKey(request)),
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Delete notification',
          ),
        ),
      ),
    );
  }
}
