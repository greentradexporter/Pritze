import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/salon_logo.dart';
import 'salon_booking_screen.dart';

class SalonDetailScreen extends StatelessWidget {
  final String salonId;

  const SalonDetailScreen({super.key, required this.salonId});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(salonId);

    if (salon == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Salon')),
        body: const EmptyState(
          icon: Icons.storefront,
          title: 'Salon not found',
          message: 'This listing is not available in the prototype data.',
        ),
      );
    }

    final services = salon.availableServices;
    final availableServiceIds = services.map((service) => service.id).toSet();
    final barbers = appState
        .barbersForSalon(salon.id)
        .where((barber) => barber.serviceIds.any(availableServiceIds.contains))
        .toList();
    final instantServices = services
        .where(
          (service) => appState.isInstantBookingAvailable(
            salon.id,
            serviceId: service.id,
          ),
        )
        .toList();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 236,
            pinned: true,
            backgroundColor: AppColors.canvas,
            surfaceTintColor: Colors.transparent,
            title: Text(salon.name),
            flexibleSpace: FlexibleSpaceBar(
              background: _DetailHero(salon: salon),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          UrlLauncherUtils.makePhoneCall(context, salon.phone);
                        },
                        icon: const Icon(Icons.call),
                        label: const Text('Call'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          UrlLauncherUtils.openDirectionsLink(
                            context,
                            salon.directionsUrl,
                          );
                        },
                        icon: const Icon(Icons.directions),
                        label: const Text('Directions'),
                      ),
                    ),
                  ],
                ),
                if (instantServices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _showServicePickerSheet(
                        context,
                        salon,
                        instantOnly: true,
                      ),
                      icon: const Icon(Icons.bolt_outlined),
                      label: const Text('Book instantly'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (salon.photoUrls.isNotEmpty) ...[
                  _SalonPhotoGallery(photoUrls: salon.photoUrls),
                  const SizedBox(height: 20),
                ],
                Text(
                  'How would you like to book?',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _BookingPathCard(
                        icon: Icons.design_services_outlined,
                        title: 'Pick service',
                        subtitle: '${services.length} available',
                        color: AppColors.primary,
                        onTap: () => _showServicePickerSheet(context, salon),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _BookingPathCard(
                        icon: Icons.badge_outlined,
                        title: 'Pick barber',
                        subtitle: '${barbers.length} available',
                        color: AppColors.coral,
                        onTap: () =>
                            _showBarberPickerSheet(context, salon, barbers),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _CollapsibleSection(
                  title: 'Services',
                  subtitle: '${services.length} services',
                  icon: Icons.design_services_outlined,
                  initiallyExpanded: true,
                  children: [
                    for (final service in services) ...[
                      _ServiceTile(
                        service: service,
                        availableBarbers: appState
                            .barbersForService(salon.id, service.id)
                            .length,
                        onTap: () => _openService(context, salon, service),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                _CollapsibleSection(
                  title: 'Barbers',
                  subtitle: '${barbers.length} team members',
                  icon: Icons.badge_outlined,
                  children: [
                    if (barbers.isEmpty)
                      const EmptyState(
                        icon: Icons.badge,
                        title: 'No barbers yet',
                        message: 'Owner can add staff from partner tools.',
                      )
                    else
                      SizedBox(
                        height: 158,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: barbers.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final barber = barbers[index];
                            return _BarberCard(
                              barber: barber,
                              onTap: () {
                                _showBarberServiceSheet(context, salon, barber);
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
        ],
      ),
    );
  }

  void _openService(BuildContext context, Salon salon, SalonService service) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SalonBookingScreen(salonId: salon.id, serviceId: service.id),
      ),
    );
  }

  Future<void> _showServicePickerSheet(
    BuildContext context,
    Salon salon, {
    bool instantOnly = false,
  }) {
    final appState = AppStateScope.read(context);
    final services = instantOnly
        ? salon.availableServices
              .where(
                (service) => appState.isInstantBookingAvailable(
                  salon.id,
                  serviceId: service.id,
                ),
              )
              .toList()
        : salon.availableServices;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    instantOnly
                        ? 'Choose an instant service'
                        : 'Choose a service',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    instantOnly
                        ? 'These services can be requested right now.'
                        : 'Pick a service first, then choose an available barber.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(18),
                itemCount: services.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final service = services[index];
                  return _ServiceTile(
                    service: service,
                    availableBarbers: appState
                        .barbersForService(salon.id, service.id)
                        .length,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _openService(context, salon, service);
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBarberPickerSheet(
    BuildContext context,
    Salon salon,
    List<Barber> barbers,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose your barber',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Select a barber to see the services they handle.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: barbers.isEmpty
                  ? const EmptyState(
                      icon: Icons.badge_outlined,
                      title: 'No barbers available',
                      message: 'Please choose a service instead.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(18),
                      itemCount: barbers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final barber = barbers[index];
                        return GlassCard(
                          onTap: () {
                            Navigator.pop(sheetContext);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _showBarberServiceSheet(context, salon, barber);
                            });
                          },
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: AppColors.mint,
                                foregroundColor: AppColors.primary,
                                child: Text(
                                  barber.name.characters.first,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      barber.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${barber.experienceYears} yrs · ${barber.speciality}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios_rounded,
                                color: AppColors.primary,
                                size: 17,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBarberServiceSheet(
    BuildContext context,
    Salon salon,
    Barber barber,
  ) {
    final services = salon.availableServices
        .where((service) => barber.serviceIds.contains(service.id))
        .toList();

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: AppColors.mint,
                      foregroundColor: AppColors.primary,
                      child: Text(
                        barber.name.characters.first,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            barber.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            '${barber.experienceYears} yrs · ${barber.speciality}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Choose a service',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                if (services.isEmpty)
                  const EmptyState(
                    icon: Icons.content_cut,
                    title: 'No services assigned',
                    message: 'This barber is not assigned to a service yet.',
                  )
                else
                  for (final service in services) ...[
                    GlassCard(
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SalonBookingScreen(
                              salonId: salon.id,
                              serviceId: service.id,
                              initialBarberId: barber.id,
                            ),
                          ),
                        );
                      },
                      child: Row(
                        children: [
                          const SoftIconBox(
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
                                  service.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${service.durationMinutes} min with ${barber.name}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '₹${service.price}',
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DetailHero extends StatelessWidget {
  final Salon salon;

  const _DetailHero({required this.salon});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final isCurrentlyOpen = appState.isSalonCurrentlyOpen(salon.id);
    final accent = isCurrentlyOpen ? AppColors.primary : AppColors.muted;
    final barberCount = appState.barbersForSalon(salon.id).length;

    return Container(
      color: AppColors.canvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 66, 16, 10),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SalonLogo(
                        logoUrl: salon.coverImageUrl,
                        color: accent,
                        size: 50,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    salon.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineMedium,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.star_rounded,
                                      color: AppColors.amber,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '${salon.rating}',
                                      style: const TextStyle(
                                        color: AppColors.ink,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              salon.address.trim().isEmpty
                                  ? 'Nearby salon'
                                  : salon.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      _DetailFact(
                        icon: Icons.schedule_outlined,
                        label: _compactTimeRange(salon),
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 14),
                      _DetailFact(
                        icon: Icons.content_cut,
                        label: '$barberCount barbers',
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _DetailFact(
                          icon: Icons.near_me_outlined,
                          label: salon.distanceLabel,
                          color: AppColors.muted,
                          expanded: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailFact extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool expanded;

  const _DetailFact({
    required this.icon,
    required this.label,
    required this.color,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppColors.ink, fontSize: 14),
    );
    return Row(
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 5),
        if (expanded) Expanded(child: labelText) else labelText,
      ],
    );
  }
}

class _SalonPhotoGallery extends StatelessWidget {
  final List<String> photoUrls;

  const _SalonPhotoGallery({required this.photoUrls});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Salon photos', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        SizedBox(
          height: 154,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photoUrls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final url = photoUrls[index];
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    SizedBox(
                      width: 220,
                      height: 154,
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: AppColors.line,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                    if (index == 0)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: AppPill(
                          label: 'Cover',
                          color: AppColors.primary,
                          backgroundColor: Colors.white.withAlpha(232),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BookingPathCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _BookingPathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 126,
      child: Material(
        color: color.withAlpha(9),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: color.withAlpha(42)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SoftIconBox(icon: icon, color: color, size: 40),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_forward_rounded, color: color, size: 18),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsibleSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool initiallyExpanded;
  final List<Widget> children;

  const _CollapsibleSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(icon, color: AppColors.primary, size: 22),
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text(subtitle),
          children: children,
        ),
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  final SalonService service;
  final int availableBarbers;
  final VoidCallback onTap;

  const _ServiceTile({
    required this.service,
    required this.availableBarbers,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${service.durationMinutes} min · $availableBarbers barbers available',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '₹${service.price}',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _compactTimeRange(Salon salon) {
  String compact(String value) =>
      value.replaceAll(':00', '').replaceAll(' ', '');
  return '${compact(salon.openTime)}-${compact(salon.closeTime)}';
}

class _BarberCard extends StatelessWidget {
  final Barber barber;
  final VoidCallback onTap;

  const _BarberCard({required this.barber, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 172,
      child: GlassCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.mint,
                  foregroundColor: AppColors.primary,
                  child: Text(
                    barber.name.characters.first,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                const Icon(
                  Icons.arrow_forward,
                  color: AppColors.primary,
                  size: 18,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              barber.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 5),
            Text(
              barber.speciality,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
