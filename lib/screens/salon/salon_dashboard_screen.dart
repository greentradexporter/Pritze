import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/account_actions.dart';
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
    final revenueEntries =
        serviceRevenue.entries.where((entry) => entry.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final pendingRequests = appState.pendingJoinRequests
        .where((request) => request.salonId == salon.id)
        .toList();

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
        if (pendingRequests.isNotEmpty) ...[
          const SizedBox(height: 18),
          SectionHeader(title: 'Barber requests (${pendingRequests.length})'),
          const SizedBox(height: 10),
          for (final request in pendingRequests) ...[
            _JoinRequestCard(request: request),
            const SizedBox(height: 10),
          ],
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
              color: AppColors.primary,
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

class _OwnerBookings extends StatelessWidget {
  final String salonId;

  const _OwnerBookings({required this.salonId});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final bookings = appState
        .bookingsForSalon(salonId)
        .where((booking) => booking.status != BookingStatus.cancelled)
        .toList();

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
                      service?.name ??
                          (booking.serviceName.isEmpty
                              ? 'Service'
                              : booking.serviceName),
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
              if (booking.status == BookingStatus.pending) ...[
                _StatusButton(
                  label: 'Confirm',
                  status: BookingStatus.confirmed,
                  booking: booking,
                ),
                _StatusButton(
                  label: 'Cancel',
                  status: BookingStatus.cancelled,
                  booking: booking,
                ),
              ],
              if (booking.status == BookingStatus.confirmed) ...[
                _StatusButton(
                  label: 'Start',
                  status: BookingStatus.inProgress,
                  booking: booking,
                ),
                _StatusButton(
                  label: 'Cancel',
                  status: BookingStatus.cancelled,
                  booking: booking,
                ),
              ],
              if (booking.status == BookingStatus.inProgress)
                _StatusButton(
                  label: 'Complete',
                  status: BookingStatus.completed,
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
        return AppColors.goldDeep;
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
                      validator: _phone,
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
                      validator: _required,
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

class _JoinRequestCard extends StatelessWidget {
  final JoinRequest request;

  const _JoinRequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final serviceNames = request.serviceIds
        .map((id) => appState.getService(request.salonId, id)?.name)
        .whereType<String>()
        .toList();
    final serviceSummary = serviceNames.isEmpty
        ? 'General grooming'
        : '${serviceNames.take(3).join(', ')}${serviceNames.length > 3 ? ' +${serviceNames.length - 3} more' : ''}';

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
            '${request.experienceYears} yrs experience · $serviceSummary',
            style: const TextStyle(
              color: AppColors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${request.barberPhone}${request.barberEmail.isEmpty ? '' : ' · ${request.barberEmail}'}',
            style: Theme.of(context).textTheme.bodyMedium,
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
                child: const Text('Accept barber'),
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
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailLinkController = TextEditingController();
  bool _useEmail = true;
  bool _isSubmitting = false;
  bool _linkSent = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _emailLinkController.dispose();
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
                      icon: Icon(Icons.alternate_email),
                      label: Text('Email'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.account_circle_outlined),
                      label: Text('Google'),
                    ),
                  ],
                  selected: {_useEmail},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _useEmail = selection.first;
                      _linkSent = false;
                      _emailLinkController.clear();
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
                if (_useEmail) ...[
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  ),
                  if (_linkSent) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _emailLinkController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Paste email sign-in link',
                        prefixIcon: Icon(Icons.mark_email_read_outlined),
                      ),
                    ),
                  ],
                ] else
                  const _GoogleLoginNotice(
                    title: 'Google shortcut',
                    message:
                        'Use this only if you prefer Google. Email sign in works with Outlook, Yahoo, business email, and Gmail.',
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isSubmitting ? null : _login,
                  icon: Icon(
                    _useEmail
                        ? Icons.mark_email_unread_outlined
                        : Icons.account_circle_outlined,
                  ),
                  label: Text(
                    _useEmail
                        ? (_linkSent
                              ? 'Sign in with email link'
                              : 'Email me a sign-in link')
                        : 'Continue with Google',
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
    final email = _emailController.text.trim();
    if (name.isEmpty || (_useEmail && email.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter owner name and email address')),
      );
      return;
    }
    final appState = AppStateScope.read(context);
    setState(() => _isSubmitting = true);
    try {
      if (_useEmail) {
        if (!_linkSent) {
          await appState.sendEmailSignInLink(email: email);
          if (!mounted) {
            return;
          }
          setState(() => _linkSent = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sign-in email sent. Paste the link to continue.'),
            ),
          );
          return;
        }
        await appState.loginOwnerWithEmail(
          name: name,
          email: email,
          emailLink: _emailLinkController.text,
        );
      } else {
        await appState.loginOwnerWithGmail(name: name, email: email);
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
