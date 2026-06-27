import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/auth_login_panel.dart';

class BarberDashboardScreen extends StatelessWidget {
  const BarberDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barber = appState.currentBarber;
    final request = appState.currentJoinRequest;
    final body = appState.barberAccount == null
        ? const _BarberLoginGate()
        : barber != null
        ? _BarberWorkView(barber: barber)
        : _BarberJoinView(request: request);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Barber tools'),
          actions: [
            if (appState.barberAccount != null)
              Builder(
                builder: (tabContext) => AccountOverflowMenu(
                  role: UserRole.barber,
                  canLogout: true,
                  onNotificationOpened: (destination) {
                    if (destination == AppNotificationDestination.bookings) {
                      DefaultTabController.of(tabContext).animateTo(0);
                    }
                  },
                  onLoggedOut: () async {
                    if (tabContext.mounted &&
                        Navigator.of(tabContext).canPop()) {
                      Navigator.of(tabContext).pop();
                    }
                  },
                ),
              ),
            const SizedBox(width: 8),
          ],
          bottom: barber == null
              ? null
              : const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.receipt_long), text: 'Appointments'),
                    Tab(icon: Icon(Icons.currency_rupee), text: 'Earnings'),
                  ],
                ),
        ),
        body: appState.barberAccount == null
            ? body
            : barber == null
            ? RefreshIndicator(onRefresh: appState.refresh, child: body)
            : TabBarView(
                children: [
                  RefreshIndicator(onRefresh: appState.refresh, child: body),
                  RefreshIndicator(
                    onRefresh: appState.refresh,
                    child: _BarberEarningsView(barber: barber),
                  ),
                ],
              ),
      ),
    );
  }
}

class _BarberLoginGate extends StatefulWidget {
  const _BarberLoginGate();

  @override
  State<_BarberLoginGate> createState() => _BarberLoginGateState();
}

class _BarberLoginGateState extends State<_BarberLoginGate> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        const AppHeroHeader(
          eyebrow: 'Barber login',
          title: 'Sign in before joining a salon',
          subtitle:
              'Your account is used to connect join requests, approvals, and assigned bookings.',
          icon: Icons.badge,
        ),
        const SizedBox(height: 22),
        const AuthLoginPanel(
          role: UserRole.barber,
          googleTitle: 'Nothing else to fill in',
          googleMessage:
              'Choose your Google account. Your name and Gmail address will be carried into the next step automatically.',
        ),
      ],
    );
  }
}

class _BarberJoinView extends StatefulWidget {
  final JoinRequest? request;

  const _BarberJoinView({required this.request});

  @override
  State<_BarberJoinView> createState() => _BarberJoinViewState();
}

class _BarberJoinViewState extends State<_BarberJoinView> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _experienceController = TextEditingController(text: '2');
  final _resumeController = TextEditingController();
  String? _salonId;
  String _speciality = _barberSpecialities.first;
  final Set<String> _serviceIds = {};
  bool _profileLoaded = false;
  bool _isWithdrawing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_profileLoaded) {
      return;
    }
    final account = AppStateScope.read(context).barberAccount;
    if (account != null) {
      _nameController.text = account.name;
      if (account.contact.contains('@')) {
        _emailController.text = account.contact;
      } else {
        _phoneController.text = account.contact;
      }
    }
    _profileLoaded = true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _experienceController.dispose();
    _resumeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final account = appState.barberAccount;
    final hasAuthenticatedEmail = account?.contact.contains('@') == true;
    final salons = appState.salons;
    if (_salonId == null || salons.every((salon) => salon.id != _salonId)) {
      _salonId = salons.isEmpty ? null : salons.first.id;
    }
    final selectedSalon = _salonId == null
        ? null
        : appState.getSalon(_salonId!);
    if (widget.request != null &&
        widget.request!.status == JoinRequestStatus.pending) {
      final salon = appState.getSalon(widget.request!.salonId);
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
        children: [
          AppHeroHeader(
            eyebrow: 'Request sent',
            title: 'Waiting for approval',
            subtitle:
                '${salon?.name ?? 'Selected salon'} will approve your profile before bookings appear here.',
            icon: Icons.hourglass_top,
          ),
          const SizedBox(height: 18),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppPill(label: 'Pending', color: AppColors.amber),
                const SizedBox(height: 14),
                Text(
                  widget.request!.barberName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 5),
                Text(
                  widget.request!.speciality,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isWithdrawing
                  ? null
                  : () => _withdrawRequest(context, widget.request!),
              icon: const Icon(Icons.undo_rounded),
              label: Text(_isWithdrawing ? 'Withdrawing…' : 'Withdraw request'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.coral),
            ),
          ),
        ],
      );
    }

    if (salons.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
        children: const [
          AppHeroHeader(
            eyebrow: 'Barber onboarding',
            title: 'No shops available yet',
            subtitle:
                'Ask the shop owner to register their salon first. You can send a join request after a shop and service menu exist.',
            icon: Icons.storefront,
          ),
          SizedBox(height: 18),
          EmptyState(
            icon: Icons.store_mall_directory_outlined,
            title: 'No registered shops',
            message: 'There is nowhere to send a barber request right now.',
          ),
        ],
      );
    }

    final selectedSalonHasServices =
        selectedSalon != null && selectedSalon.services.isNotEmpty;

    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
              children: [
                const AppHeroHeader(
                  eyebrow: 'Barber onboarding',
                  title: 'Join your salon and start tracking work',
                  subtitle:
                      'Send your employee profile and resume to the shop owner. Once approved, your schedule appears here.',
                  icon: Icons.badge,
                ),
                if (widget.request?.status == JoinRequestStatus.rejected) ...[
                  const SizedBox(height: 12),
                  const AppPill(
                    label: 'Last request rejected',
                    color: AppColors.coral,
                  ),
                ],
                if (widget.request?.status == JoinRequestStatus.withdrawn) ...[
                  const SizedBox(height: 12),
                  const AppPill(
                    label: 'Previous request withdrawn',
                    color: AppColors.muted,
                  ),
                ],
                const SizedBox(height: 22),
                const SectionHeader(title: 'Profile'),
                const SizedBox(height: 10),
                GlassCard(
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        readOnly: hasAuthenticatedEmail,
                        decoration: InputDecoration(
                          labelText: 'Email address',
                          helperText: hasAuthenticatedEmail
                              ? 'Filled from your signed-in account'
                              : null,
                          prefixIcon: const Icon(Icons.alternate_email),
                        ),
                        validator: _email,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: _phone,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _speciality,
                        decoration: const InputDecoration(
                          labelText: 'Speciality',
                          prefixIcon: Icon(Icons.content_cut),
                        ),
                        items: [
                          for (final speciality in _barberSpecialities)
                            DropdownMenuItem(
                              value: speciality,
                              child: Text(speciality),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _speciality = value;
                              _serviceIds.removeWhere((serviceId) {
                                final service = selectedSalon?.services
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
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _experienceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Years of experience',
                          prefixIcon: Icon(Icons.work_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _resumeController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Resume summary',
                          prefixIcon: Icon(Icons.description_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownMenu<String>(
                        initialSelection: selectedSalon == null
                            ? null
                            : _salonId,
                        enableFilter: true,
                        enableSearch: true,
                        requestFocusOnTap: true,
                        expandedInsets: EdgeInsets.zero,
                        label: const Text('Salon'),
                        leadingIcon: const Icon(Icons.storefront_outlined),
                        dropdownMenuEntries: [
                          for (final salon in appState.salons)
                            DropdownMenuEntry(
                              value: salon.id,
                              label: salon.name,
                            ),
                        ],
                        onSelected: (value) {
                          setState(() {
                            _salonId = value;
                            _serviceIds.clear();
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _ServiceDropdown(
                  services: (selectedSalon?.services ?? const <SalonService>[])
                      .where(
                        (service) => serviceMatchesBarberSpeciality(
                          service,
                          _speciality,
                        ),
                      )
                      .toList(),
                  selectedIds: _serviceIds,
                  onChanged: () => setState(() {}),
                ),
                if (!selectedSalonHasServices) ...[
                  const SizedBox(height: 10),
                  const EmptyState(
                    icon: Icons.spa_outlined,
                    title: 'No services yet',
                    message:
                        'This shop needs to add services before barbers can request to join.',
                  ),
                ],
                const SizedBox(height: 18),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(18, 8, 18, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: selectedSalonHasServices
                    ? () => _submit(context)
                    : null,
                icon: const Icon(Icons.send),
                label: const Text('Send request'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
  }

  Future<void> _withdrawRequest(
    BuildContext context,
    JoinRequest request,
  ) async {
    final appState = AppStateScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: AppColors.coral.withAlpha(22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.undo_rounded,
                      color: AppColors.coral,
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Withdraw request?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 24,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The salon will no longer be able to approve this request. You can submit a new one afterward.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 50,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Keep request'),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.coral,
                    ),
                    icon: const Icon(Icons.undo_rounded, size: 19),
                    label: const Text('Yes, withdraw request'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _isWithdrawing = true);
    try {
      await appState.withdrawJoinRequest(request.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not withdraw request: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isWithdrawing = false);
      }
    }
  }

  String? _phone(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
    final localDigits = digits.length == 12 && digits.startsWith('91')
        ? digits.substring(2)
        : digits;
    return localDigits.length == 10 ? null : 'Enter a 10-digit phone number';
  }

  String? _email(String? value) {
    final email = (value ?? '').trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  Future<void> _submit(BuildContext context) async {
    if (!_formKey.currentState!.validate() || _salonId == null) {
      return;
    }
    final appState = AppStateScope.read(context);
    final services = _serviceIds.toList();
    if (services.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one service.')),
      );
      return;
    }
    try {
      await appState.submitJoinRequest(
        salonId: _salonId!,
        barberName: _nameController.text,
        barberPhone: _phoneController.text,
        barberEmail: _emailController.text,
        speciality: _speciality,
        experienceYears: int.tryParse(_experienceController.text) ?? 1,
        resumeSummary: _resumeController.text,
        serviceIds: services,
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Request failed: $error')));
    }
  }
}

class _ServiceDropdown extends StatefulWidget {
  final List<SalonService> services;
  final Set<String> selectedIds;
  final VoidCallback onChanged;

  const _ServiceDropdown({
    required this.services,
    required this.selectedIds,
    required this.onChanged,
  });

  @override
  State<_ServiceDropdown> createState() => _ServiceDropdownState();
}

class _ServiceDropdownState extends State<_ServiceDropdown> {
  bool _expanded = false;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.selectedIds.length;
    final visibleServices = widget.services.where((service) {
      final query = _query.trim().toLowerCase();
      return query.isEmpty ||
          service.name.toLowerCase().contains(query) ||
          service.category.toLowerCase().contains(query);
    }).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.design_services_outlined),
            title: const Text('Services you can handle'),
            subtitle: Text('$count selected'),
            trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  labelText: 'Search services',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: visibleServices.length,
                itemBuilder: (context, index) {
                  final service = visibleServices[index];
                  return CheckboxListTile(
                    dense: true,
                    value: widget.selectedIds.contains(service.id),
                    title: Text(service.name),
                    subtitle: Text(service.category),
                    onChanged: (selected) {
                      setState(() {
                        if (selected == true) {
                          widget.selectedIds.add(service.id);
                        } else {
                          widget.selectedIds.remove(service.id);
                        }
                      });
                      widget.onChanged();
                    },
                  );
                },
              ),
            ),
          ],
        ],
      ),
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

class _BarberWorkView extends StatefulWidget {
  final Barber barber;

  const _BarberWorkView({required this.barber});

  @override
  State<_BarberWorkView> createState() => _BarberWorkViewState();
}

class _BarberWorkViewState extends State<_BarberWorkView> {
  BarberBookingBucket _selectedBucket = BarberBookingBucket.upcoming;
  Timer? _clock;

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
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final now = DateTime.now();
    final bookings = appState.bookingsForBarber(widget.barber.id);
    final grouped = {
      for (final bucket in BarberBookingBucket.values)
        bucket: bookings.where((booking) {
          return appState.barberBookingBucket(booking, now: now) == bucket;
        }).toList(),
    };
    grouped[BarberBookingBucket.upcoming]!.sort(
      (a, b) => a.start.compareTo(b.start),
    );
    for (final bucket in const [
      BarberBookingBucket.active,
      BarberBookingBucket.history,
      BarberBookingBucket.cancelled,
    ]) {
      grouped[bucket]!.sort((a, b) => b.start.compareTo(a.start));
    }
    final visible = grouped[_selectedBucket]!;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        AppHeroHeader(
          eyebrow: 'Appointment ledger',
          title: widget.barber.name,
          subtitle:
              '${widget.barber.speciality}. Track every upcoming, active, expired, completed, and cancelled appointment.',
          icon: Icons.receipt_long,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _MiniMetric(
                label: 'Upcoming',
                value: '${grouped[BarberBookingBucket.upcoming]!.length}',
                icon: Icons.upcoming,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MiniMetric(
                label: 'Active',
                value: '${grouped[BarberBookingBucket.active]!.length}',
                icon: Icons.content_cut,
                color: AppColors.coral,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MiniMetric(
                label: 'History',
                value: '${grouped[BarberBookingBucket.history]!.length}',
                icon: Icons.history,
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: BarberBookingBucket.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final bucket = BarberBookingBucket.values[index];
              return ChoiceChip(
                selected: _selectedBucket == bucket,
                onSelected: (_) => setState(() => _selectedBucket = bucket),
                avatar: Icon(_bucketIcon(bucket), size: 17),
                label: Text(
                  '${_bucketLabel(bucket)} ${grouped[bucket]!.length}',
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        if (visible.isEmpty)
          EmptyState(
            icon: _bucketIcon(_selectedBucket),
            title: _emptyTitle(_selectedBucket),
            message: _emptyMessage(_selectedBucket),
          )
        else
          for (final booking in visible) ...[
            _BarberBookingCard(
              booking: booking,
              bucket: _selectedBucket,
              outcome: appState.barberBookingOutcome(booking, now: now),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  String _bucketLabel(BarberBookingBucket bucket) => switch (bucket) {
    BarberBookingBucket.upcoming => 'Upcoming',
    BarberBookingBucket.active => 'Active',
    BarberBookingBucket.history => 'History',
    BarberBookingBucket.cancelled => 'Cancelled',
  };

  IconData _bucketIcon(BarberBookingBucket bucket) => switch (bucket) {
    BarberBookingBucket.upcoming => Icons.upcoming,
    BarberBookingBucket.active => Icons.content_cut,
    BarberBookingBucket.history => Icons.history,
    BarberBookingBucket.cancelled => Icons.cancel_outlined,
  };

  String _emptyTitle(BarberBookingBucket bucket) => switch (bucket) {
    BarberBookingBucket.upcoming => 'No upcoming appointments',
    BarberBookingBucket.active => 'No service in progress',
    BarberBookingBucket.history => 'No previous appointments',
    BarberBookingBucket.cancelled => 'No cancelled appointments',
  };

  String _emptyMessage(BarberBookingBucket bucket) => switch (bucket) {
    BarberBookingBucket.upcoming =>
      'Confirmed bookings and requests waiting for salon acceptance appear here.',
    BarberBookingBucket.active =>
      'An appointment moves here as soon as its service is started.',
    BarberBookingBucket.history =>
      'Completed, missed, and requests not accepted before their time appear here.',
    BarberBookingBucket.cancelled =>
      'Bookings cancelled or rejected by the salon or customer appear here.',
  };
}

class _BarberEarningsView extends StatelessWidget {
  final Barber barber;

  const _BarberEarningsView({required this.barber});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final now = DateTime.now();
    final completed =
        appState
            .bookingsForBarber(barber.id)
            .where((booking) => booking.status == BookingStatus.completed)
            .toList()
          ..sort((a, b) => b.start.compareTo(a.start));
    final total = appState.barberTotalEarnings(barber.id);
    final today = appState.barberDailyEarnings(barber.id, now: now);
    final month = appState.barberMonthlyEarnings(barber.id, now: now);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        AppHeroHeader(
          eyebrow: 'Earnings overview',
          title: '₹$total earned in total',
          subtitle:
              'Only completed services assigned to ${barber.name} are included.',
          icon: Icons.account_balance_wallet_outlined,
        ),
        const SizedBox(height: 18),
        _EarningMetricCard(
          label: 'Total earnings',
          value: total,
          detail: '${completed.length} completed services',
          icon: Icons.savings_outlined,
          color: AppColors.primary,
          featured: true,
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _EarningMetricCard(
                  label: 'Today',
                  value: today,
                  detail: _completedCountForDay(completed, now) == 1
                      ? '1 service'
                      : '${_completedCountForDay(completed, now)} services',
                  icon: Icons.today_outlined,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _EarningMetricCard(
                  label: 'This month',
                  value: month,
                  detail:
                      '${_completedCountForMonth(completed, now)} completed',
                  icon: Icons.calendar_month_outlined,
                  color: AppColors.goldDeep,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const SectionHeader(title: 'Completed-service earnings'),
        const SizedBox(height: 10),
        if (completed.isEmpty)
          const EmptyState(
            icon: Icons.currency_rupee,
            title: 'No earnings yet',
            message:
                'Completed appointments will appear here with their captured service value.',
          )
        else
          for (final booking in completed.take(20)) ...[
            GlassCard(
              child: Row(
                children: [
                  const SoftIconBox(
                    icon: Icons.check_rounded,
                    color: AppColors.success,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          booking.serviceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${booking.customerName} · ${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '₹${appState.bookingEarning(booking)}',
                    style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  int _completedCountForDay(List<Booking> bookings, DateTime date) {
    return bookings.where((booking) {
      return booking.start.year == date.year &&
          booking.start.month == date.month &&
          booking.start.day == date.day;
    }).length;
  }

  int _completedCountForMonth(List<Booking> bookings, DateTime date) {
    return bookings.where((booking) {
      return booking.start.year == date.year &&
          booking.start.month == date.month;
    }).length;
  }
}

class _EarningMetricCard extends StatelessWidget {
  final String label;
  final int value;
  final String detail;
  final IconData icon;
  final Color color;
  final bool featured;

  const _EarningMetricCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
    this.featured = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      color: color.withAlpha(featured ? 13 : 7),
      padding: EdgeInsets.all(featured ? 18 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SoftIconBox(icon: icon, color: color, size: featured ? 46 : 40),
          SizedBox(height: featured ? 18 : 13),
          Text(
            '₹$value',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.ink,
              fontSize: featured ? 31 : 23,
              height: 1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _BarberBookingCard extends StatelessWidget {
  final Booking booking;
  final BarberBookingBucket bucket;
  final String outcome;

  const _BarberBookingCard({
    required this.booking,
    required this.bucket,
    required this.outcome,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final service = appState.getService(booking.salonId, booking.serviceId);

    final outcomeColor = _outcomeColor();
    final canStart =
        booking.status == BookingStatus.confirmed &&
        bucket == BarberBookingBucket.upcoming &&
        !DateTime.now().isBefore(
          booking.start.subtract(const Duration(minutes: 15)),
        );
    final canComplete = booking.status == BookingStatus.inProgress;

    return GlassCard(
      color: outcomeColor.withAlpha(7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SoftIconBox(
                icon: Icons.person_outline,
                color: AppColors.primary,
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
              AppPill(label: outcome, color: outcomeColor),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.schedule, size: 17, color: AppColors.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${appState.formatDate(booking.start)}, ${appState.formatTime(booking.start)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (canStart || canComplete) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: canComplete
                  ? FilledButton.icon(
                      onPressed: () =>
                          _updateStatus(context, BookingStatus.completed),
                      icon: const Icon(Icons.done_all),
                      label: const Text('Complete service'),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: () =>
                          _updateStatus(context, BookingStatus.inProgress),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start service'),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Color _outcomeColor() {
    if (outcome == 'Not accepted' || outcome.startsWith('Missed')) {
      return AppColors.coral;
    }
    return switch (booking.status) {
      BookingStatus.pending => AppColors.amber,
      BookingStatus.confirmed => AppColors.goldDeep,
      BookingStatus.inProgress => AppColors.primary,
      BookingStatus.completed => AppColors.success,
      BookingStatus.cancelled => AppColors.coral,
      BookingStatus.rejected => AppColors.coral,
    };
  }

  Future<void> _updateStatus(BuildContext context, BookingStatus status) async {
    try {
      await AppStateScope.read(context).updateBookingStatus(booking.id, status);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Status update failed: $error')));
      }
    }
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _MiniMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
