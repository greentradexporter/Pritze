import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/status_chip.dart';

class BarberDashboardScreen extends StatelessWidget {
  const BarberDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barber = appState.currentBarber;
    final request = appState.currentJoinRequest;

    return Scaffold(
      appBar: AppBar(title: const Text('Barber tools')),
      body: appState.barberAccount == null
          ? const _BarberLoginGate()
          : barber != null
          ? _BarberWorkView(barber: barber)
          : _BarberJoinView(request: request),
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
    final appState = AppStateScope.watch(context);
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
                  labelText: 'Barber name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              if (_usePhone)
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
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
                  appState.usesRealPhoneOtp &&
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
                      : (_usePhone ? 'Verify barber' : 'Continue with Google'),
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
    final contact = _usePhone
        ? _phoneController.text.trim()
        : _emailController.text.trim();
    if (name.isEmpty || (_usePhone && contact.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter barber name and login detail')),
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
            await appState.loginBarberWithPhone(name: name, phone: contact);
            return;
          }
          setState(() => _verificationId = verificationId);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('OTP sent. Enter it to continue.')),
          );
          return;
        }
        await appState.loginBarberWithPhone(
          name: name,
          phone: contact,
          verificationId: _verificationId,
          smsCode: _otpController.text,
        );
      } else {
        await appState.loginBarberWithGmail(name: name, email: contact);
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
  final _experienceController = TextEditingController(text: '2');
  final _resumeController = TextEditingController();
  String? _salonId;
  String _speciality = _barberSpecialities.first;
  final Set<String> _serviceIds = {};

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
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
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
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
                  validator: _required,
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
                      setState(() => _speciality = value);
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
                DropdownButtonFormField<String>(
                  initialValue: selectedSalon == null ? null : _salonId,
                  decoration: const InputDecoration(
                    labelText: 'Salon',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                  items: [
                    for (final salon in appState.salons)
                      DropdownMenuItem(
                        value: salon.id,
                        child: Text(salon.name),
                      ),
                  ],
                  onChanged: (value) {
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
          const SectionHeader(title: 'Services you can handle'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final service in selectedSalon?.services ?? <SalonService>[])
                FilterChip(
                  label: Text(service.name),
                  selected: _serviceIds.contains(service.id),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _serviceIds.add(service.id);
                      } else {
                        _serviceIds.remove(service.id);
                      }
                    });
                  },
                ),
            ],
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
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: selectedSalonHasServices ? () => _submit(context) : null,
            icon: const Icon(Icons.send),
            label: const Text('Send request'),
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
                      service?.name ?? 'Service',
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
