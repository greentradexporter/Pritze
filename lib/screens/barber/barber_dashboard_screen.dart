import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/status_chip.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Barber tools'),
        actions: [
          if (appState.barberAccount != null)
            AccountOverflowMenu(
              role: UserRole.barber,
              canLogout: true,
              onLoggedOut: () async {
                if (context.mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: appState.barberAccount == null
          ? body
          : RefreshIndicator(onRefresh: appState.refresh, child: body),
    );
  }
}

class _BarberLoginGate extends StatefulWidget {
  const _BarberLoginGate();

  @override
  State<_BarberLoginGate> createState() => _BarberLoginGateState();
}

class _BarberLoginGateState extends State<_BarberLoginGate> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailLinkController = TextEditingController();
  bool _useEmail = true;
  bool _isSubmitting = false;
  bool _linkSent = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _emailLinkController.dispose();
    super.dispose();
  }

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
                  labelText: 'Barber name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone number for shop records',
                  prefixIcon: Icon(Icons.phone_outlined),
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
    );
  }

  Future<void> _login() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    final phoneDigits = phone.replaceAll(RegExp(r'\D'), '');
    final localPhone = phoneDigits.length == 12 && phoneDigits.startsWith('91')
        ? phoneDigits.substring(2)
        : phoneDigits;
    final hasValidPhone = localPhone.length == 10;
    final hasValidEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
    if (name.isEmpty || !hasValidPhone || (_useEmail && !hasValidEmail)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a name, 10-digit phone number, and valid email address',
          ),
        ),
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
        await appState.loginBarberWithEmail(
          name: name,
          email: email,
          phone: phone,
          emailLink: _emailLinkController.text,
        );
      } else {
        await appState.loginBarberWithGmail(
          name: name,
          email: email,
          phone: phone,
        );
      }
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
            color: AppColors.coral,
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
                        validator: _phone,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.alternate_email),
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
                        validator: _required,
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

class _BarberWorkView extends StatelessWidget {
  final Barber barber;

  const _BarberWorkView({required this.barber});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final bookings = appState.bookingsForBarber(barber.id);
    final activeBookings = bookings
        .where((booking) => booking.status != BookingStatus.cancelled)
        .toList();
    final completed = bookings
        .where((booking) => booking.status == BookingStatus.completed)
        .length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        AppHeroHeader(
          eyebrow: 'Your chair',
          title: barber.name,
          subtitle:
              '${barber.speciality}. ${activeBookings.length} active jobs assigned today.',
          icon: Icons.content_cut,
        ),
        const SizedBox(height: 12),
        GlassCard(
          color: AppColors.mint,
          child: Row(
            children: [
              const SoftIconBox(
                icon: Icons.description_outlined,
                color: AppColors.primary,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${barber.experienceYears} yrs exp - ${barber.resumeSummary}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _MiniMetric(
                label: 'Assigned',
                value: '${activeBookings.length}',
                icon: Icons.event_note,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MiniMetric(
                label: 'Completed',
                value: '$completed',
                icon: Icons.done_all,
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHeader(title: 'Schedule'),
        const SizedBox(height: 10),
        if (bookings.isEmpty)
          const EmptyState(
            icon: Icons.event_note,
            title: 'No assigned bookings',
            message: 'When customers book your services, they appear here.',
          )
        else
          for (final booking in bookings) ...[
            _BarberBookingCard(booking: booking),
            const SizedBox(height: 10),
          ],
      ],
    );
  }
}

class _BarberBookingCard extends StatelessWidget {
  final Booking booking;

  const _BarberBookingCard({required this.booking});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final service = appState.getService(booking.salonId, booking.serviceId);

    return GlassCard(
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
              StatusChip(status: booking.status),
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
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: booking.status == BookingStatus.inProgress
                      ? null
                      : () async {
                          try {
                            await appState.updateBookingStatus(
                              booking.id,
                              BookingStatus.inProgress,
                            );
                          } catch (error) {
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Status update failed: $error'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: booking.status == BookingStatus.completed
                      ? null
                      : () async {
                          try {
                            await appState.updateBookingStatus(
                              booking.id,
                              BookingStatus.completed,
                            );
                          } catch (error) {
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Status update failed: $error'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.done),
                  label: const Text('Done'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          SoftIconBox(icon: icon, color: color, size: 40),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ],
      ),
    );
  }
}
