import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/app_models.dart';
import '../../state/app_state.dart';
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
  bool _isInstantBooking = false;
  int _instantArrivalMinutes = 15;

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

    if (salon == null || service == null || !service.isAvailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('Book')),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Service unavailable',
          message: 'The salon has temporarily hidden this service.',
        ),
      );
    }

    final eligibleBarbers = appState.barbersForService(
      widget.salonId,
      widget.serviceId,
    );
    final canRequestInstant =
        appState.isInstantBookingAvailable(
          salon.id,
          serviceId: widget.serviceId,
          arrivalMinutes: _instantArrivalMinutes,
        ) &&
        eligibleBarbers.isNotEmpty;
    final activeCustomerBooking = appState.activeCustomerBooking;
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
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
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
          onPressed:
              selectedSlot == null ||
                  _isBooking ||
                  activeCustomerBooking != null
              ? null
              : () => _startBookingLogin(context, selectedSlot),
          icon: _isBooking
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle),
          label: Text(
            _isBooking
                ? 'Booking...'
                : activeCustomerBooking != null
                ? 'Cancel current booking first'
                : isAndroid
                ? 'Book for ₹0'
                : 'Book this slot',
          ),
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
            showBookingFee: !isAndroid,
          ),
          const SizedBox(height: 14),
          _InstantBookingCard(
            enabled: canRequestInstant,
            isLoading: _isInstantBooking,
            selectedArrivalMinutes: _instantArrivalMinutes,
            activeBooking: activeCustomerBooking,
            onArrivalMinutesChanged: (minutes) {
              setState(() => _instantArrivalMinutes = minutes);
            },
            onRequest: () => _startInstantBookingLogin(context),
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
                    'No booking fee today. The salon receives your name with the request.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w500,
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
          serviceName: booking.resolvedServiceName(service),
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

  Future<void> _startInstantBookingLogin(BuildContext context) async {
    if (_isInstantBooking) {
      return;
    }
    final appState = AppStateScope.read(context);
    if (appState.hasActiveCustomerSession) {
      await _completeInstantBooking(context);
      return;
    }

    final didLogin = await _showCustomerLoginSheet(context);
    if (didLogin == true && context.mounted) {
      await _completeInstantBooking(context);
    }
  }

  Future<void> _completeInstantBooking(BuildContext context) async {
    if (_isInstantBooking) {
      return;
    }
    setState(() => _isInstantBooking = true);
    final appState = AppStateScope.read(context);
    late final Booking booking;
    try {
      booking = await appState.createInstantBooking(
        salonId: widget.salonId,
        serviceId: widget.serviceId,
        arrivalMinutes: _instantArrivalMinutes,
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Instant request failed: ${_bookingErrorText(error)}'),
        ),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _isInstantBooking = false);
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
          title: 'Instant request sent',
          message:
              'The salon has your request. Your ${booking.customerArrivalMinutes}-minute arrival timer is already running.',
          salonName: salon?.name ?? 'Salon',
          serviceName: booking.resolvedServiceName(service),
          appointmentTime: 'Arrive by ${appState.formatTime(booking.start)}',
          barberName: barber?.name ?? 'Any available barber',
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
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isAndroid ? Colors.transparent : null,
      barrierColor: isAndroid ? Colors.black.withAlpha(118) : null,
      builder: (sheetContext) {
        void finishLogin() {
          if (sheetContext.mounted) {
            Navigator.pop(sheetContext, true);
          }
        }

        if (isAndroid) {
          return _AndroidBookingLoginSheet(onLoggedIn: finishLogin);
        }
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
                  'Sign in',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Use your mobile number and OTP to finish booking.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                AuthLoginPanel(
                  role: UserRole.customer,
                  onLoggedIn: finishLogin,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AndroidBookingLoginSheet extends StatelessWidget {
  final VoidCallback onLoggedIn;

  const _AndroidBookingLoginSheet({required this.onLoggedIn});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      key: const ValueKey('android-booking-login-sheet'),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 32,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, bottomInset + 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 52,
                    width: 52,
                    decoration: BoxDecoration(
                      color: AppColors.champagne,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.lock_person_outlined,
                      color: AppColors.primaryDark,
                      size: 27,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Complete your booking',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Sign in securely to send your appointment request.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8EA),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF0D6A5)),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      color: AppColors.primaryDark,
                      size: 24,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '₹0 booking fee',
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'No payment is taken now. Pay only the service price at the salon.',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AuthLoginPanel(
                role: UserRole.customer,
                embedded: true,
                phoneHelperText: 'We will send a secure one-time code.',
                onLoggedIn: onLoggedIn,
              ),
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_outlined, size: 17, color: AppColors.muted),
                  SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'Your details are used only to manage your booking',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingSuccessDialog extends StatelessWidget {
  final String title;
  final String message;
  final String salonName;
  final String serviceName;
  final String appointmentTime;
  final String barberName;
  final VoidCallback onDone;
  final VoidCallback onMyBookings;

  const _BookingSuccessDialog({
    this.title = 'Booking request sent',
    this.message = 'The salon will confirm your appointment soon.',
    required this.salonName,
    required this.serviceName,
    required this.appointmentTime,
    required this.barberName,
    required this.onDone,
    required this.onMyBookings,
  });

  Widget _buildAndroidDialog(BuildContext context) {
    final waitingTitle = title == 'Instant request sent'
        ? 'Waiting for the salon to accept'
        : 'Awaiting salon confirmation';
    return Dialog(
      key: const ValueKey('android-booking-success-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Material(
            color: AppColors.surface,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFFFF4DC), Color(0xFFFFFCF7)],
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 5),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.success.withAlpha(52),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(height: 1.4),
                        ),
                        const SizedBox(height: 14),
                        const AppPill(
                          icon: Icons.currency_rupee,
                          label: '0 booking fee',
                          color: AppColors.primaryDark,
                          backgroundColor: Colors.white,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'BOOKING DETAILS',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFBFAF7),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Column(
                            children: [
                              _AndroidSuccessDetailRow(
                                icon: Icons.storefront_outlined,
                                label: 'Salon',
                                value: salonName,
                              ),
                              const Divider(indent: 58),
                              _AndroidSuccessDetailRow(
                                icon: Icons.spa_outlined,
                                label: 'Service',
                                value: serviceName,
                              ),
                              const Divider(indent: 58),
                              _AndroidSuccessDetailRow(
                                icon: Icons.schedule_outlined,
                                label: 'Date & time',
                                value: appointmentTime,
                              ),
                              const Divider(indent: 58),
                              _AndroidSuccessDetailRow(
                                icon: Icons.badge_outlined,
                                label: 'Professional',
                                value: barberName,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.champagne.withAlpha(116),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.hourglass_top_rounded,
                                  color: AppColors.primaryDark,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      waitingTitle,
                                      style: const TextStyle(
                                        color: AppColors.ink,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    const Text(
                                      'Track updates anytime in My bookings.',
                                      style: TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: onDone,
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Done'),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: onMyBookings,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text('View my bookings'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _buildAndroidDialog(context);
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
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
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
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
                borderRadius: BorderRadius.circular(8),
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
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
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
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

class _AndroidSuccessDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _AndroidSuccessDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.champagne.withAlpha(148),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.primaryDark, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
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
                fontWeight: isStrong ? FontWeight.w600 : FontWeight.w500,
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
  final bool showBookingFee;

  const _BookingSummary({
    required this.salon,
    required this.service,
    required this.barberCount,
    required this.accent,
    required this.showBookingFee,
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
                top: Radius.circular(8),
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
                                ?.copyWith(fontWeight: FontWeight.w600),
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
                      label:
                          '$barberCount ${barberCount == 1 ? 'barber' : 'barbers'}',
                      color: AppColors.primary,
                    ),
                    if (showBookingFee)
                      AppPill(
                        icon: Icons.currency_rupee,
                        label: '0 booking fee',
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

class _InstantBookingCard extends StatelessWidget {
  final bool enabled;
  final bool isLoading;
  final int selectedArrivalMinutes;
  final Booking? activeBooking;
  final ValueChanged<int> onArrivalMinutesChanged;
  final VoidCallback onRequest;

  const _InstantBookingCard({
    required this.enabled,
    required this.isLoading,
    required this.selectedArrivalMinutes,
    required this.activeBooking,
    required this.onArrivalMinutesChanged,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    if (activeBooking != null) {
      return Container(
        key: const ValueKey('active-instant-booking-block'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.champagne.withAlpha(94),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.gold),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.timer_outlined,
              color: AppColors.primary,
              size: 20,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Cancel or complete your current booking before making another.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      );
    }

    return GlassCard(
      color: AppColors.champagne.withAlpha(112),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SoftIconBox(
            icon: Icons.bolt_outlined,
            color: AppColors.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Instant booking',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose when you can reach the salon. The timer starts as soon as the request is sent.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.ink),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    key: const ValueKey('instant-arrival-selector'),
                    showSelectedIcon: false,
                    segments: [
                      for (final minutes in instantArrivalMinuteOptions)
                        ButtonSegment<int>(
                          value: minutes,
                          label: Text('$minutes min'),
                        ),
                    ],
                    selected: {selectedArrivalMinutes},
                    onSelectionChanged: isLoading
                        ? null
                        : (selection) =>
                              onArrivalMinutesChanged(selection.first),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The salon and barber receive a ${selectedArrivalMinutes + 5}-minute preparation window.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!enabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Instant booking is unavailable for this service right now.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.coral,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: enabled && !isLoading ? onRequest : null,
                    icon: isLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.flash_on_outlined),
                    label: Text(
                      isLoading ? 'Sending...' : 'Request instant booking',
                    ),
                  ),
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

    final cardHeight = MediaQuery.textScalerOf(
      context,
    ).scale(118).clamp(118.0, 148.0);

    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: barbers.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BarberChoiceCard(
              title: 'Any available',
              subtitle:
                  '${barbers.length} ${barbers.length == 1 ? 'barber' : 'barbers'}',
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
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 164,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(8),
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
                    style: const TextStyle(fontWeight: FontWeight.w600),
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
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                fontWeight: FontWeight.w500,
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
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(8),
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
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    barber?.name ?? 'Any barber',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
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
