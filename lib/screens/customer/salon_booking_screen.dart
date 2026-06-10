import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
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
    final accent = _serviceColor(service.category);

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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
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
                    'No account needed yet. You will login with phone or Google only after tapping book.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: selectedSlot == null
                ? null
                : () => _startBookingLogin(context, selectedSlot),
            icon: const Icon(Icons.check_circle),
            label: const Text('Book this slot'),
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startBookingLogin(BuildContext context, TimeSlot slot) async {
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
    final appState = AppStateScope.read(context);
    late final Booking booking;
    try {
      booking = await appState.createBooking(slot: slot);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Booking failed: $error')));
      return;
    }
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.check_circle, color: AppColors.primary),
          title: const Text('Booking request sent'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                salon?.name ?? 'Salon',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(service?.name ?? 'Service'),
              const SizedBox(height: 8),
              Text(
                '${appState.formatDate(booking.start)}, '
                '${appState.formatTime(booking.start)}',
              ),
              const SizedBox(height: 8),
              Text(barber?.name ?? 'Assigned barber'),
              const SizedBox(height: 14),
              const StatusChip(status: BookingStatus.pending),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                );
              },
              child: const Text('My bookings'),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showCustomerLoginSheet(BuildContext context) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final emailController = TextEditingController();
    final otpController = TextEditingController();
    var usePhone = true;
    var isSubmitting = false;
    String? verificationId;

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(context).viewInsets.bottom + 18,
              ),
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
                    'You have already selected salon, barber, and time. This final step creates your customer booking.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.phone_outlined),
                        label: Text('Phone'),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.mail_outline),
                        label: Text('Google'),
                      ),
                    ],
                    selected: {usePhone},
                    onSelectionChanged: (selection) {
                      setSheetState(() {
                        usePhone = selection.first;
                        verificationId = null;
                        otpController.clear();
                      });
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (usePhone)
                    TextField(
                      controller: phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.canvas,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.line),
                      ),
                      child: Row(
                        children: [
                          const SoftIconBox(
                            icon: Icons.account_circle_outlined,
                            color: AppColors.primary,
                            size: 42,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Use the Google account on this device',
                                  style: TextStyle(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'No email typing is needed here. Android will show the Google account picker.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (usePhone && verificationId != null) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: otpController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'OTP code',
                        prefixIcon: Icon(Icons.pin_outlined),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            final name = nameController.text.trim();
                            final contact = usePhone
                                ? phoneController.text.trim()
                                : emailController.text.trim();
                            if (name.isEmpty || (usePhone && contact.isEmpty)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Enter name and login detail'),
                                ),
                              );
                              return;
                            }
                            final appState = AppStateScope.read(context);
                            setSheetState(() => isSubmitting = true);
                            try {
                              if (usePhone) {
                                if (appState.usesRealPhoneOtp &&
                                    verificationId == null) {
                                  final id = await appState
                                      .startCustomerPhoneVerification(
                                        phone: contact,
                                      );
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (id == null) {
                                    await appState.loginCustomerWithPhone(
                                      name: name,
                                      phone: contact,
                                    );
                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext, true);
                                    }
                                    return;
                                  }
                                  setSheetState(() => verificationId = id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'OTP sent. Enter the code to finish booking.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                await appState.loginCustomerWithPhone(
                                  name: name,
                                  phone: contact,
                                  verificationId: verificationId,
                                  smsCode: otpController.text,
                                );
                              } else {
                                await appState.loginCustomerWithGmail(
                                  name: name,
                                  email: contact,
                                );
                              }
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext, true);
                              }
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Login failed: $error'),
                                  ),
                                );
                              }
                            } finally {
                              if (context.mounted) {
                                setSheetState(() => isSubmitting = false);
                              }
                            }
                          },
                    icon: isSubmitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(usePhone ? Icons.phone : Icons.mail),
                    label: Text(
                      usePhone
                          ? verificationId == null &&
                                    AppStateScope.read(context).usesRealPhoneOtp
                                ? 'Send OTP'
                                : 'Continue with phone'
                          : 'Continue with Google',
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
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
                    SoftIconBox(
                      icon: _serviceIcon(service.category),
                      color: accent,
                      size: 48,
                    ),
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
                      color: AppColors.blue,
                    ),
                    AppPill(
                      icon: Icons.login,
                      label: 'Login at checkout',
                      color: AppColors.plum,
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

Color _serviceColor(String category) {
  switch (category.toLowerCase()) {
    case 'beard':
      return AppColors.coral;
    case 'treatment':
    case 'skin':
      return AppColors.plum;
    case 'color':
      return AppColors.blue;
    default:
      return AppColors.primary;
  }
}

IconData _serviceIcon(String category) {
  switch (category.toLowerCase()) {
    case 'beard':
      return Icons.face_retouching_natural;
    case 'treatment':
    case 'skin':
      return Icons.spa;
    case 'color':
      return Icons.palette_outlined;
    default:
      return Icons.content_cut;
  }
}
