import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/auth_login_panel.dart';
import '../../widgets/salon_logo.dart';
import '../../widgets/status_chip.dart';
import 'my_bookings_screen.dart';

class SalonBookingScreen extends StatefulWidget {
  final String salonId;
  final String serviceId;
  final String? initialBarberId;

  const SalonBookingScreen({
    super.key,
    required this.salonId,
    required this.serviceId,
    this.initialBarberId,
  });

  @override
  State<SalonBookingScreen> createState() => _SalonBookingScreenState();
}

class _SalonBookingScreenState extends State<SalonBookingScreen> {
  String? _selectedSlotKey;
  String? _selectedBarberId;
  bool _isBooking = false;

  @override
  void initState() {
    super.initState();
    _selectedBarberId = widget.initialBarberId;
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.salonId);
    final service = appState.getService(widget.salonId, widget.serviceId);

    if (salon == null || service == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Book')),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Service not found',
          message: 'This service is not available in the prototype data.',
        ),
      );
    }

    final eligibleBarbers = appState.barbersForService(
      widget.salonId,
      widget.serviceId,
    );
    final selectedBarberId =
        eligibleBarbers.any((barber) => barber.id == _selectedBarberId)
        ? _selectedBarberId
        : null;
    final slots = appState.slotsForService(
      widget.salonId,
      widget.serviceId,
      barberId: selectedBarberId,
    );
    final selectedSlot = slots
        .where((slot) => slot.key == _selectedSlotKey)
        .firstOrNull;
    const accent = AppColors.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Book slot'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: AppPill(
              icon: Icons.currency_rupee,
              label: '${service.price}',
              color: accent,
              backgroundColor: accent.withAlpha(16),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 8, 18, 14),
        child: FilledButton.icon(
          onPressed: selectedSlot == null || _isBooking
              ? null
              : () => _startBookingLogin(context, selectedSlot),
          icon: _isBooking
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle),
          label: Text(_isBooking ? 'Booking...' : 'Book this slot'),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        children: [
          _BookingSummary(
            salon: salon,
            service: service,
            barberCount: eligibleBarbers.length,
            accent: accent,
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Choose barber'),
          const SizedBox(height: 10),
          _BarberChoiceList(
            barbers: eligibleBarbers,
            selectedBarberId: selectedBarberId,
            accent: accent,
            onSelected: (barberId) {
              setState(() {
                _selectedBarberId = barberId;
                _selectedSlotKey = null;
              });
            },
          ),
          const SizedBox(height: 22),
          const SectionHeader(title: 'Available slots'),
          const SizedBox(height: 10),
          if (slots.isEmpty)
            EmptyState(
              icon: Icons.event_busy,
              title: 'No slots open',
              message: selectedBarberId == null
                  ? 'Try another service or check back later.'
                  : 'Try Any available or pick another barber.',
            )
          else
            _SlotGrid(
              slots: slots,
              selectedSlotKey: _selectedSlotKey,
              accent: accent,
              onSelected: (slot) {
                setState(() {
                  _selectedSlotKey = slot.key;
                });
              },
            ),
          const SizedBox(height: 12),
          GlassCard(
            color: accent.withAlpha(12),
            child: Row(
              children: [
                SoftIconBox(icon: Icons.lock_outline, color: accent, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No account needed yet. You will sign in with email or Google only after tapping book.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 74),
        ],
      ),
    );
  }

  Future<void> _startBookingLogin(BuildContext context, TimeSlot slot) async {
    if (_isBooking) {
      return;
    }
    final appState = AppStateScope.read(context);
    if (appState.hasActiveCustomerSession) {
      await _completeBooking(context, slot);
      return;
    }

    final didLogin = await _showCustomerLoginSheet(context);
    if (didLogin == true && context.mounted) {
      await _completeBooking(context, slot);
    }
  }

  Future<void> _completeBooking(BuildContext context, TimeSlot slot) async {
    if (_isBooking) {
      return;
    }
    setState(() => _isBooking = true);
    final appState = AppStateScope.read(context);
    late final Booking booking;
    try {
      booking = await appState.createBooking(slot: slot);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Booking failed: ${_bookingErrorText(error)}')),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _isBooking = false);
      }
    }
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _BookingSuccessDialog(
          salonName: salon?.name ?? 'Salon',
          serviceName: service?.name ?? 'Service',
          appointmentTime:
              '${appState.formatDate(booking.start)}, '
              '${appState.formatTime(booking.start)}',
          barberName: barber?.name ?? 'Assigned barber',
          onDone: () => Navigator.pop(dialogContext),
          onMyBookings: () {
            Navigator.pop(dialogContext);
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
            );
          },
        );
      },
    );
  }

  String _bookingErrorText(Object error) {
    if (error is FirebaseException && error.code == 'permission-denied') {
      return 'Please sign in again, then book this slot.';
    }
    final message = error.toString();
    if (message.contains('sign in again')) {
      return 'Please sign in again, then book this slot.';
    }
    if (message.contains('just booked')) {
      return 'This slot was just booked. Please choose another time.';
    }
    return message;
  }

  Future<bool?> _showCustomerLoginSheet(BuildContext context) async {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 18,
            bottom: MediaQuery.of(context).viewInsets.bottom + 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Text(
                  'Login to finish booking',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Use phone OTP, email verification, or Gmail. This final step creates your customer booking.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                AuthLoginPanel(
                  role: UserRole.customer,
                  googleTitle: 'Gmail shortcut',
                  googleMessage:
                      'Choose your Google account. Your Gmail identity will be used for this booking automatically.',
                  onLoggedIn: () {
                    if (sheetContext.mounted) {
                      Navigator.pop(sheetContext, true);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BookingSuccessDialog extends StatelessWidget {
  final String salonName;
  final String serviceName;
  final String appointmentTime;
  final String barberName;
  final VoidCallback onDone;
  final VoidCallback onMyBookings;

  const _BookingSuccessDialog({
    required this.salonName,
    required this.serviceName,
    required this.appointmentTime,
    required this.barberName,
    required this.onDone,
    required this.onMyBookings,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(24),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(14),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.success.withAlpha(38)),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppColors.success,
                  size: 38,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Booking request sent',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'The salon will confirm your appointment soon.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.champagne.withAlpha(58),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                children: [
                  _SuccessDetailRow(
                    icon: Icons.storefront_outlined,
                    label: salonName,
                    isStrong: true,
                  ),
                  _SuccessDetailRow(
                    icon: Icons.spa_outlined,
                    label: serviceName,
                  ),
                  _SuccessDetailRow(
                    icon: Icons.schedule,
                    label: appointmentTime,
                  ),
                  _SuccessDetailRow(
                    icon: Icons.badge_outlined,
                    label: barberName,
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: StatusChip(status: BookingStatus.pending),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                child: const Text('Done'),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: onMyBookings,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryDark,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                    decorationThickness: 2,
                  ),
                ),
                child: const Text('My bookings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isStrong;

  const _SuccessDetailRow({
    required this.icon,
    required this.label,
    this.isStrong = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.ink,
                fontWeight: isStrong ? FontWeight.w900 : FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookingSummary extends StatelessWidget {
  final Salon salon;
  final SalonService service;
  final int barberCount;
  final Color accent;

  const _BookingSummary({
    required this.salon,
    required this.service,
    required this.barberCount,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 5,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(18),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SalonLogo(logoUrl: salon.logoUrl, color: accent, size: 52),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            salon.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            service.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppPill(
                      icon: Icons.schedule,
                      label: '${service.durationMinutes} min',
                      color: accent,
                    ),
                    AppPill(
                      icon: Icons.badge_outlined,
                      label: '$barberCount barbers',
                      color: AppColors.primary,
                    ),
                    AppPill(
                      icon: Icons.login,
                      label: 'Login at checkout',
                      color: AppColors.goldDeep,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarberChoiceList extends StatelessWidget {
  final List<Barber> barbers;
  final String? selectedBarberId;
  final Color accent;
  final ValueChanged<String?> onSelected;

  const _BarberChoiceList({
    required this.barbers,
    required this.selectedBarberId,
    required this.accent,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (barbers.isEmpty) {
      return const EmptyState(
        icon: Icons.badge,
        title: 'No barbers available',
        message: 'This service does not have an assigned barber yet.',
      );
    }

    return SizedBox(
      height: 106,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: barbers.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BarberChoiceCard(
              title: 'Any available',
              subtitle: '${barbers.length} barbers',
              initial: 'A',
              selected: selectedBarberId == null,
              accent: accent,
              onTap: () => onSelected(null),
            );
          }

          final barber = barbers[index - 1];
          return _BarberChoiceCard(
            title: barber.name,
            subtitle: barber.speciality,
            initial: barber.name.characters.first,
            selected: selectedBarberId == barber.id,
            accent: accent,
            onTap: () => onSelected(barber.id),
          );
        },
      ),
    );
  }
}

class _BarberChoiceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String initial;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _BarberChoiceCard({
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: 156,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? accent : AppColors.line,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F0F172A),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: selected ? accent : accent.withAlpha(16),
                  foregroundColor: selected ? Colors.white : accent,
                  child: Text(
                    initial,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const Spacer(),
                Icon(
                  selected ? Icons.check_circle : Icons.add_circle_outline,
                  color: accent,
                  size: 19,
                ),
              ],
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  final List<TimeSlot> slots;
  final String? selectedSlotKey;
  final Color accent;
  final ValueChanged<TimeSlot> onSelected;

  const _SlotGrid({
    required this.slots,
    required this.selectedSlotKey,
    required this.accent,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final grouped = <String, List<TimeSlot>>{};
    for (final slot in slots) {
      grouped.putIfAbsent(appState.formatDate(slot.start), () => []).add(slot);
    }

    return Column(
      children: [
        for (final entry in grouped.entries) ...[
          Row(
            children: [
              Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Expanded(child: Divider(color: Colors.grey.shade300)),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: entry.value.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.45,
            ),
            itemBuilder: (context, index) {
              final slot = entry.value[index];
              return _SlotCard(
                slot: slot,
                selected: slot.key == selectedSlotKey,
                accent: accent,
                onTap: () => onSelected(slot),
              );
            },
          ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class _SlotCard extends StatelessWidget {
  final TimeSlot slot;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _SlotCard({
    required this.slot,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barber = appState.getBarber(slot.barberId);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? accent : AppColors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.schedule,
              color: accent,
              size: 22,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    appState.formatTime(slot.start),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    barber?.name ?? 'Any barber',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
