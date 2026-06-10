import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
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
            _OwnerOverview(salon: salon),
            _OwnerBookings(salonId: salon.id),
            _OwnerStaff(salon: salon),
          ],
        ),
      ),
    );
  }
}

class _OwnerOverview extends StatelessWidget {
  final Salon salon;

  const _OwnerOverview({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final workCount = appState.barberWorkCount(salon.id);
    final serviceRevenue = appState.serviceRevenue(salon.id);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        AppHeroHeader(
          eyebrow: 'Today at ${salon.name}',
          title: '₹${appState.dailyCollection(salon.id)} collected',
          subtitle:
              '${appState.todayBookingCount(salon.id)} appointments today. Track staff, revenue, and booking status.',
          icon: Icons.insights,
        ),
        if (!appState.isSalonBookable(salon.id)) ...[
          const SizedBox(height: 14),
          _OwnerSetupBanner(salon: salon),
        ],
        const SizedBox(height: 18),
        const SectionHeader(title: 'Chair board'),
        const SizedBox(height: 10),
        _ChairBoard(salonId: salon.id),
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
                  '${appState.countByStatus(salon.id, BookingStatus.pending)}',
              color: AppColors.amber,
            ),
            _MetricCard(
              icon: Icons.play_circle_outline,
              label: 'In progress',
              value:
                  '${appState.countByStatus(salon.id, BookingStatus.inProgress)}',
              color: AppColors.blue,
            ),
            _MetricCard(
              icon: Icons.done_all,
              label: 'Completed',
              value:
                  '${appState.countByStatus(salon.id, BookingStatus.completed)}',
              color: AppColors.success,
            ),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHeader(title: 'Barber workload'),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            children: [
              for (final barber in appState.barbersForSalon(salon.id))
                _ProgressRow(
                  label: barber.name,
                  value: '${workCount[barber.id] ?? 0} jobs',
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const SectionHeader(title: 'Service revenue'),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            children: [
              for (final service in salon.services)
                _ProgressRow(
                  label: service.name,
                  value: '₹${serviceRevenue[service.id] ?? 0}',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OwnerBookings extends StatelessWidget {
  final String salonId;

  const _OwnerBookings({required this.salonId});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final bookings = appState.bookingsForSalon(salonId);

    if (bookings.isEmpty) {
      return const EmptyState(
        icon: Icons.inbox_outlined,
        title: 'No booking requests',
        message: 'Customer bookings will appear here in real time.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      itemBuilder: (context, index) =>
          _OwnerBookingCard(booking: bookings[index]),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemCount: bookings.length,
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

class _OwnerBookingCard extends StatelessWidget {
  final Booking booking;

  const _OwnerBookingCard({required this.booking});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);

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
                      service?.name ?? 'Service',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              StatusChip(status: booking.status),
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
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusButton(
                label: 'Pending',
                status: BookingStatus.pending,
                booking: booking,
              ),
              _StatusButton(
                label: 'Confirm',
                status: BookingStatus.confirmed,
                booking: booking,
              ),
              _StatusButton(
                label: 'Start',
                status: BookingStatus.inProgress,
                booking: booking,
              ),
              _StatusButton(
                label: 'Complete',
                status: BookingStatus.completed,
                booking: booking,
              ),
              _StatusButton(
                label: 'Cancel',
                status: BookingStatus.cancelled,
                booking: booking,
              ),
            ],
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
        return AppColors.blue;
      case BookingStatus.inProgress:
        return AppColors.primary;
      case BookingStatus.completed:
        return AppColors.success;
      case BookingStatus.cancelled:
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
        const SectionHeader(title: 'Team'),
        const SizedBox(height: 10),
        for (final barber in barbers) ...[
          _StaffCard(barber: barber),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  void _showAddBarberDialog(BuildContext context) {
    final appState = AppStateScope.read(context);
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final experienceController = TextEditingController(text: '2');
    final resumeController = TextEditingController();
    final selectedServices = appState.ownerSalon.services
        .map((service) => service.id)
        .toSet();
    var speciality = _barberSpecialities.first;
    var isSaving = false;

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add barber'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: speciality,
                      decoration: const InputDecoration(
                        labelText: 'Speciality',
                      ),
                      items: [
                        for (final item in _barberSpecialities)
                          DropdownMenuItem(value: item, child: Text(item)),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => speciality = value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: experienceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Years of experience',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: resumeController,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Barber resume summary',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final service in appState.ownerSalon.services)
                          FilterChip(
                            label: Text(service.name),
                            selected: selectedServices.contains(service.id),
                            onSelected: (selected) {
                              setDialogState(() {
                                if (selected) {
                                  selectedServices.add(service.id);
                                } else {
                                  selectedServices.remove(service.id);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (nameController.text.trim().isEmpty ||
                              phoneController.text.trim().isEmpty) {
                            return;
                          }
                          if (selectedServices.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Select at least one service.'),
                              ),
                            );
                            return;
                          }
                          setDialogState(() => isSaving = true);
                          try {
                            await appState.addOwnerBarber(
                              name: nameController.text,
                              phone: phoneController.text,
                              speciality: speciality,
                              experienceYears:
                                  int.tryParse(experienceController.text) ?? 1,
                              resumeSummary: resumeController.text,
                              serviceIds: selectedServices.toList(),
                            );
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                          } catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Barber save failed: $error'),
                                ),
                              );
                            }
                          } finally {
                            if (context.mounted) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  child: Text(isSaving ? 'Saving...' : 'Add'),
                ),
              ],
            );
          },
        );
      },
    );
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

class _JoinRequestCard extends StatelessWidget {
  final JoinRequest request;

  const _JoinRequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final services = request.serviceIds
        .map((id) => appState.getService(request.salonId, id)?.name)
        .whereType<String>()
        .join(', ');

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.how_to_reg,
                color: AppColors.coral,
                size: 46,
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
                    const SizedBox(height: 4),
                    Text(
                      request.speciality,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${request.experienceYears} yrs exp - ${services.isEmpty ? 'General grooming' : services}',
            style: const TextStyle(
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            request.resumeSummary,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed: () async {
                  try {
                    await appState.rejectJoinRequest(request.id);
                  } catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Reject failed: $error')),
                    );
                  }
                },
                child: const Text('Reject'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  try {
                    await appState.approveJoinRequest(request.id);
                  } catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Approve failed: $error')),
                    );
                  }
                },
                child: const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
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
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  bool _usePhone = true;
  bool _isSubmitting = false;
  String? _verificationId;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

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
          GlassCard(
            child: Column(
              children: [
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
                  selected: {_usePhone},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _usePhone = selection.first;
                      _verificationId = null;
                      _otpController.clear();
                    });
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Owner name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                if (_usePhone)
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Business phone',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                  )
                else
                  const _GoogleLoginNotice(
                    title: 'Use the Google account on this device',
                    message:
                        'No email typing is needed here. Android will show the Google account picker.',
                  ),
                if (_usePhone &&
                    AppStateScope.watch(context).usesRealPhoneOtp &&
                    _verificationId != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Enter received OTP',
                      prefixIcon: Icon(Icons.password_outlined),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isSubmitting ? null : _login,
                  icon: Icon(_usePhone ? Icons.phone : Icons.mail),
                  label: Text(
                    _usePhone && _verificationId == null
                        ? 'Send OTP'
                        : (_usePhone ? 'Verify owner' : 'Continue with Google'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    final name = _nameController.text.trim();
    final contact = _usePhone
        ? _phoneController.text.trim()
        : _emailController.text.trim();
    if (name.isEmpty || (_usePhone && contact.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter owner name and login detail')),
      );
      return;
    }
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      if (_usePhone) {
        if (appState.usesRealPhoneOtp && _verificationId == null) {
          final verificationId = await appState.startCustomerPhoneVerification(
            phone: contact,
          );
          if (!mounted) {
            return;
          }
          if (verificationId == null) {
            await appState.loginOwnerWithPhone(name: name, phone: contact);
            if (!mounted) {
              return;
            }
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => const SalonProfileSetupScreen(),
              ),
            );
            return;
          }
          setState(() => _verificationId = verificationId);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('OTP sent. Enter it to continue.')),
          );
          return;
        }
        await appState.loginOwnerWithPhone(
          name: name,
          phone: contact,
          verificationId: _verificationId,
          smsCode: _otpController.text,
        );
      } else {
        await appState.loginOwnerWithGmail(name: name, email: contact);
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SalonProfileSetupScreen()),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Login failed: $error')));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}

class _GoogleLoginNotice extends StatelessWidget {
  final String title;
  final String message;

  const _GoogleLoginNotice({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
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
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
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

  const _StatusButton({
    required this.label,
    required this.status,
    required this.booking,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    return OutlinedButton(
      onPressed: booking.status == status
          ? null
          : () async {
              try {
                await appState.updateBookingStatus(booking.id, status);
              } catch (error) {
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Status update failed: $error')),
                );
              }
            },
      child: Text(label),
    );
  }
}
