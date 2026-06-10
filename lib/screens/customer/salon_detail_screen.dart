import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_ui.dart';
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

    final barbers = appState.barbersForSalon(salon.id);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 284,
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
                          UrlLauncherUtils.openGoogleMaps(
                            context,
                            salon.address,
                          );
                        },
                        icon: const Icon(Icons.directions),
                        label: const Text('Directions'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SectionHeader(title: 'Services'),
                const SizedBox(height: 10),
                for (final service in salon.services) ...[
                  _ServiceTile(
                    service: service,
                    availableBarbers: appState
                        .barbersForService(salon.id, service.id)
                        .length,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SalonBookingScreen(
                            salonId: salon.id,
                            serviceId: service.id,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 16),
                const SectionHeader(title: 'Barbers in this shop'),
                const SizedBox(height: 10),
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
          ),
        ],
      ),
    );
  }

  Future<void> _showBarberServiceSheet(
    BuildContext context,
    Salon salon,
    Barber barber,
  ) {
    final services = salon.services
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
                              fontWeight: FontWeight.w900,
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
    final accent = salon.isOpen ? AppColors.primary : AppColors.muted;

    return Container(
      color: AppColors.canvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 72, 18, 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.line),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0F0F172A),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SoftIconBox(
                        icon: Icons.storefront_outlined,
                        color: accent,
                        size: 44,
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(fontSize: 22),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AppPill(
                                  label: salon.isOpen ? 'Open' : 'Closed',
                                  color: accent,
                                  backgroundColor: accent.withAlpha(16),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'Full address will be shown after the listing is verified.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
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
                        icon: Icons.star,
                        label: '${salon.rating} (${salon.reviewCount})',
                        color: AppColors.amber,
                      ),
                      AppPill(
                        icon: Icons.near_me_outlined,
                        label: salon.distanceLabel,
                        color: AppColors.blue,
                      ),
                      AppPill(
                        icon: Icons.schedule,
                        label: '${salon.openTime} - ${salon.closeTime}',
                        color: accent,
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
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          SoftIconBox(icon: _serviceIcon(service.category), color: _color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 5),
                Text(
                  '${service.durationMinutes} min - $availableBarbers barbers available',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹${service.price}',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              const Icon(
                Icons.arrow_forward,
                color: AppColors.primary,
                size: 18,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color get _color {
    switch (service.category.toLowerCase()) {
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
                    style: const TextStyle(fontWeight: FontWeight.w900),
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
