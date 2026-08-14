import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import '../utils/url_launcher_utils.dart';
import 'app_ui.dart';
import 'status_chip.dart';

enum _AccountAction { notifications, support, logout }

typedef NotificationOpenCallback =
    void Function(AppNotificationDestination destination, {String? bookingId});

String _joinNotificationKey(JoinRequest request) =>
    'join:${request.id}:${request.status.name}';

enum _BookingNotificationKind {
  created,
  accepted,
  arrivalReminder,
  completed,
  cancelled,
  rejected,
}

class _BookingNotificationEvent {
  final Booking booking;
  final _BookingNotificationKind kind;
  final DateTime occurredAt;

  const _BookingNotificationEvent({
    required this.booking,
    required this.kind,
    required this.occurredAt,
  });

  String get key {
    final legacyStatusKey = switch (kind) {
      _BookingNotificationKind.created =>
        booking.isInstant
            ? BookingStatus.pending.name
            : BookingStatus.confirmed.name,
      _BookingNotificationKind.accepted => BookingStatus.confirmed.name,
      _BookingNotificationKind.completed => BookingStatus.completed.name,
      _BookingNotificationKind.cancelled => BookingStatus.cancelled.name,
      _BookingNotificationKind.rejected => BookingStatus.rejected.name,
      _BookingNotificationKind.arrivalReminder => 'arrivalReminder',
    };
    return 'booking:${booking.id}:$legacyStatusKey';
  }

  BookingStatus get displayStatus => switch (kind) {
    _BookingNotificationKind.created =>
      booking.isInstant ? BookingStatus.pending : BookingStatus.confirmed,
    _BookingNotificationKind.accepted ||
    _BookingNotificationKind.arrivalReminder => BookingStatus.confirmed,
    _BookingNotificationKind.completed => BookingStatus.completed,
    _BookingNotificationKind.cancelled => BookingStatus.cancelled,
    _BookingNotificationKind.rejected => BookingStatus.rejected,
  };
}

class AccountOverflowMenu extends StatelessWidget {
  final UserRole role;
  final bool canLogout;
  final Future<void> Function()? onLoggedOut;
  final NotificationOpenCallback? onNotificationOpened;

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
    final account = switch (role) {
      UserRole.customer => appState.customerAccount,
      UserRole.owner => appState.ownerAccount,
      UserRole.barber => appState.barberAccount,
    };
    final fallbackName = switch (role) {
      UserRole.customer => 'Customer',
      UserRole.owner => appState.ownerSalonOrNull?.ownerName ?? 'Salon owner',
      UserRole.barber => appState.currentBarber?.name ?? 'Barber',
    };
    final accountName =
        account?.name.trim().isNotEmpty == true &&
            account?.name.trim() != 'Phone user'
        ? account!.name.trim()
        : fallbackName;
    final accountContact = account?.contact.trim() ?? '';
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
          case _AccountAction.support:
            await showSupportSheet(context);
          case _AccountAction.logout:
            final didLogout = await confirmAndLogout(context);
            if (didLogout && onLoggedOut != null) {
              await onLoggedOut!();
            }
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<_AccountAction>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(
              child: Icon(Icons.person_outline, size: 20),
            ),
            title: Text(
              accountName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: accountContact.isEmpty
                ? null
                : Text(
                    accountContact,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _AccountAction.notifications,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.notifications_outlined),
            title: Text('Notifications'),
          ),
        ),
        const PopupMenuItem(
          value: _AccountAction.support,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.support_agent_outlined),
            title: Text('Support'),
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

class CustomerNotificationButton extends StatelessWidget {
  final NotificationOpenCallback? onNotificationOpened;

  const CustomerNotificationButton({super.key, this.onNotificationOpened});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final count = unreadNotificationCount(appState, UserRole.customer);
    return IconButton(
      key: const ValueKey('customer-notification-button'),
      tooltip: 'Customer notifications',
      onPressed: () => openCustomerNotifications(
        context,
        onNotificationOpened: onNotificationOpened,
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 9 ? '9+' : '$count'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

Future<void> openCustomerNotifications(
  BuildContext context, {
  NotificationOpenCallback? onNotificationOpened,
}) async {
  final appState = AppStateScope.read(context);
  appState.markNotificationsSeen(
    UserRole.customer,
    notificationKeys(appState, UserRole.customer),
  );
  await showNotificationCenter(
    context,
    UserRole.customer,
    onNotificationOpened: onNotificationOpened,
  );
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

Future<void> showSupportSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      final state = AppStateScope.watch(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Support', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            GlassCard(
              child: Row(
                children: [
                  const SoftIconBox(
                    icon: Icons.support_agent_outlined,
                    color: AppColors.primary,
                    size: 46,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pritze support',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.supportPhone,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () {
                      UrlLauncherUtils.makePhoneCall(
                        context,
                        state.supportPhone,
                      );
                    },
                    icon: const Icon(Icons.call),
                    tooltip: 'Call support',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

int unreadNotificationCount(AppState state, UserRole role) {
  if (!state.notificationPreferencesReady(role)) {
    return 0;
  }
  return notificationKeys(
    state,
    role,
  ).where((key) => !state.hasSeenNotification(role, key)).length;
}

List<String> notificationKeys(AppState state, UserRole role) {
  final keys = switch (role) {
    UserRole.customer => [
      for (final event in _bookingNotificationEvents(state, role)) event.key,
    ],
    UserRole.barber => [
      if (state.currentJoinRequest case final request?)
        if (request.status != JoinRequestStatus.withdrawn)
          _joinNotificationKey(request),
      if (state.currentBarber != null)
        for (final event in _bookingNotificationEvents(state, role)) event.key,
    ],
    UserRole.owner => [
      for (final event in _bookingNotificationEvents(state, role)) event.key,
      for (final request in state.pendingJoinRequests)
        _joinNotificationKey(request),
    ],
  };
  return keys
      .where((key) => !state.hasDismissedNotification(role, key))
      .toSet()
      .toList();
}

List<_BookingNotificationEvent> _bookingNotificationEvents(
  AppState state,
  UserRole role,
) {
  final bookings = switch (role) {
    UserRole.customer => state.customerBookings,
    UserRole.owner => state.bookingsForSalon(state.ownerSalonId),
    UserRole.barber =>
      state.currentBarber == null
          ? const <Booking>[]
          : state.bookingsForBarber(state.currentBarber!.id),
  };
  final events = <_BookingNotificationEvent>[];
  for (final booking in bookings) {
    events.add(
      _BookingNotificationEvent(
        booking: booking,
        kind: _BookingNotificationKind.created,
        occurredAt: booking.createdAt,
      ),
    );
    if (booking.acceptedAt case final acceptedAt?) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.accepted,
          occurredAt: acceptedAt,
        ),
      );
    }
    final reminderAt = role == UserRole.owner
        ? booking.ownerArrivalReminderSentAt
        : booking.customerArrivalReminderSentAt;
    if (reminderAt != null) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.arrivalReminder,
          occurredAt: reminderAt,
        ),
      );
    }
    if (booking.completedAt case final completedAt?) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.completed,
          occurredAt: completedAt,
        ),
      );
    } else if (booking.status == BookingStatus.completed) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.completed,
          occurredAt: booking.start.add(
            Duration(minutes: booking.durationMinutes),
          ),
        ),
      );
    }
    if (booking.cancelledAt case final cancelledAt?) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.cancelled,
          occurredAt: cancelledAt,
        ),
      );
    } else if (booking.status == BookingStatus.cancelled) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.cancelled,
          occurredAt: booking.createdAt,
        ),
      );
    }
    if (booking.rejectedAt case final rejectedAt?) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.rejected,
          occurredAt: rejectedAt,
        ),
      );
    } else if (booking.status == BookingStatus.rejected) {
      events.add(
        _BookingNotificationEvent(
          booking: booking,
          kind: _BookingNotificationKind.rejected,
          occurredAt: booking.createdAt,
        ),
      );
    }
  }
  events.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  return events;
}

Future<void> showNotificationCenter(
  BuildContext context,
  UserRole role, {
  NotificationOpenCallback? onNotificationOpened,
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
  final NotificationOpenCallback? onNotificationOpened;

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
        for (final event in _bookingNotificationEvents(state, role).take(30))
          if (!state.hasDismissedNotification(role, event.key))
            _BookingNotification(
              event: event,
              role: role,
              onOpen: () => _open(
                AppNotificationDestination.bookings,
                bookingId: event.booking.id,
              ),
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
          for (final event in _bookingNotificationEvents(state, role).take(30))
            if (!state.hasDismissedNotification(role, event.key))
              _BookingNotification(
                event: event,
                role: role,
                onOpen: () => _open(
                  AppNotificationDestination.bookings,
                  bookingId: event.booking.id,
                ),
              ),
      ];
    }
    return [
      for (final event in _bookingNotificationEvents(state, role).take(30))
        if (!state.hasDismissedNotification(role, event.key))
          _BookingNotification(
            event: event,
            role: role,
            onOpen: () => _open(
              AppNotificationDestination.bookings,
              bookingId: event.booking.id,
            ),
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

  void _open(AppNotificationDestination destination, {String? bookingId}) {
    onNotificationOpened?.call(destination, bookingId: bookingId);
  }
}

class _BookingNotification extends StatelessWidget {
  final _BookingNotificationEvent event;
  final UserRole role;
  final VoidCallback onOpen;

  const _BookingNotification({
    required this.event,
    required this.role,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final booking = event.booking;
    final salon = state.getSalon(booking.salonId);
    final service = state.getService(booking.salonId, booking.serviceId);
    final notificationKey = event.key;
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
                  Text(_title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    _body(
                      salonName: salon?.name ?? 'your salon',
                      serviceName: booking.resolvedServiceName(service),
                      appointment:
                          '${state.formatDate(booking.start)}, ${state.formatTime(booking.start)}',
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  StatusChip(status: event.displayStatus),
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

  Booking get booking => event.booking;

  String get _title => switch (event.kind) {
    _BookingNotificationKind.created =>
      booking.isInstant
          ? role == UserRole.owner
                ? 'New instant booking request'
                : 'Instant booking request sent'
          : role == UserRole.owner
          ? 'New scheduled booking'
          : 'Booking confirmed',
    _BookingNotificationKind.accepted => 'Instant booking accepted',
    _BookingNotificationKind.arrivalReminder =>
      role == UserRole.owner
          ? 'Customer arriving within 5 minutes'
          : booking.isInstant
          ? 'Your appointment starts in 5 minutes'
          : 'Your appointment starts soon',
    _BookingNotificationKind.completed =>
      role == UserRole.customer ? 'Visit completed' : 'Booking completed',
    _BookingNotificationKind.cancelled =>
      booking.cancelledBy == 'customer'
          ? role == UserRole.customer
                ? 'You cancelled the booking'
                : 'Customer cancelled booking'
          : role == UserRole.customer
          ? 'Salon cancelled booking'
          : 'Booking cancelled by salon',
    _BookingNotificationKind.rejected =>
      role == UserRole.customer
          ? 'Booking rejected by salon'
          : 'Booking rejected',
  };

  String _body({
    required String salonName,
    required String serviceName,
    required String appointment,
  }) {
    final reason = booking.cancellationReason.trim();
    return switch (event.kind) {
      _BookingNotificationKind.created =>
        role == UserRole.owner
            ? '${booking.customerName} requested $serviceName for $appointment.'
            : '$serviceName at $salonName · $appointment.',
      _BookingNotificationKind.accepted =>
        role == UserRole.owner
            ? '${booking.customerName}\'s $serviceName request was accepted.'
            : '$salonName accepted $serviceName. Please arrive by ${stateTime(booking.start)}.',
      _BookingNotificationKind.arrivalReminder =>
        role == UserRole.owner
            ? '${booking.customerName} is expected within 5 minutes for $serviceName.'
            : booking.isInstant
            ? '$serviceName at $salonName is scheduled to start in about 5 minutes.'
            : '$serviceName at $salonName starts in about 30 minutes.',
      _BookingNotificationKind.completed =>
        '$serviceName for ${booking.customerName} has been completed.',
      _BookingNotificationKind.cancelled =>
        '${booking.cancelledBy == 'customer' ? booking.customerName : salonName} cancelled $serviceName.${reason.isEmpty ? '' : ' Reason: $reason'}',
      _BookingNotificationKind.rejected =>
        '$salonName rejected $serviceName.${reason.isEmpty ? '' : ' Reason: $reason'}',
    };
  }

  String stateTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
  }
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
