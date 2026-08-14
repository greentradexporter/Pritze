import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/salon_logo.dart';
import 'salon_detail_screen.dart';
import 'my_bookings_screen.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final Set<_ServiceCategory> _selectedCategories = {};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final pendingNavigation = appState.activeRole == UserRole.customer
        ? appState.takePendingNotificationNavigation()
        : null;
    if (pendingNavigation?.destination == AppNotificationDestination.bookings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen()));
        }
      });
    }
    final visibleSalons = _rankedSalons(appState);
    final accent = _selectedCategories.firstOrNull?.color ?? AppColors.primary;
    return Scaffold(
      bottomNavigationBar: const AppBottomNav(selectedIndex: 0),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: appState.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              const _LocationHeader(),
              const SizedBox(height: 12),
              _HeroSearch(
                accent: accent,
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                onClear: _searchQuery.isEmpty
                    ? null
                    : () => setState(() {
                        _searchController.clear();
                        _searchQuery = '';
                      }),
              ),
              const SizedBox(height: 18),
              SectionHeader(
                title: 'Services',
                actionLabel: _selectedCategories.isEmpty ? null : 'Clear',
                onAction: _selectedCategories.isEmpty
                    ? null
                    : () => setState(_selectedCategories.clear),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 82,
                child: ListView.separated(
                  key: const Key('service-category-list'),
                  scrollDirection: Axis.horizontal,
                  itemCount: _popularCategories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final category = _popularCategories[index];
                    return _CategoryCard(
                      category: category,
                      selected: _selectedCategories.contains(category),
                      onTap: () => _toggleCategory(category),
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              _ResultsHeader(
                title: _searchQuery.isNotEmpty
                    ? 'Search results'
                    : (_selectedCategories.isEmpty
                          ? 'Recommended'
                          : _selectedCategories.length == 1
                          ? '${_selectedCategories.first.label} matches'
                          : '${_selectedCategories.length} services selected'),
                subtitle: _selectedCategories.isEmpty
                    ? 'All salon listings near you'
                    : 'Salons offering all selected services',
              ),
              const SizedBox(height: 8),
              if (visibleSalons.isEmpty)
                const EmptyState(
                  icon: Icons.search_off,
                  title: 'No salons found',
                  message: 'Try another service or change your search.',
                )
              else
                for (final salon in visibleSalons) ...[
                  _SalonCard(
                    salon: salon,
                    selectedCategories: _selectedCategories,
                  ),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleCategory(_ServiceCategory category) {
    setState(() {
      if (!_selectedCategories.add(category)) {
        _selectedCategories.remove(category);
      }
    });
  }

  List<Salon> _rankedSalons(AppState appState) {
    final query = _searchQuery.trim().toLowerCase();
    final salons = appState.discoverableSalons
        .where(
          (salon) =>
              _selectedCategories.every(
                (category) => salon.availableServices.any(category.matches),
              ) &&
              (query.isEmpty || _matchesSearch(salon, query)),
        )
        .toList();

    salons.sort((a, b) {
      final aPriority = _salonSortPriority(appState, a);
      final bPriority = _salonSortPriority(appState, b);
      if (aPriority != bPriority) {
        return aPriority.compareTo(bPriority);
      }
      return b.rating.compareTo(a.rating);
    });

    return salons;
  }

  int _salonSortPriority(AppState appState, Salon salon) {
    if (appState.isSalonBookable(salon.id) &&
        appState.isSalonCurrentlyOpen(salon.id)) {
      return 0;
    }
    if (appState.isSalonBookable(salon.id)) {
      return 1;
    }
    return 2;
  }

  bool _matchesSearch(Salon salon, String query) {
    return salon.name.toLowerCase().contains(query) ||
        salon.address.toLowerCase().contains(query) ||
        salon.ownerName.toLowerCase().contains(query) ||
        salon.availableServices.any(
          (service) =>
              service.name.toLowerCase().contains(query) ||
              service.category.toLowerCase().contains(query),
        );
  }
}

class _LocationHeader extends StatelessWidget {
  const _LocationHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.location_on_outlined,
          color: AppColors.primary,
          size: 24,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current location',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                'Chembur',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        CustomerNotificationButton(
          onNotificationOpened: (destination, {bookingId}) {
            if (destination == AppNotificationDestination.bookings) {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
              );
            }
          },
        ),
      ],
    );
  }
}

class _HeroSearch extends StatelessWidget {
  final Color accent;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;

  const _HeroSearch({
    required this.accent,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search salon, service, area',
        prefixIcon: Icon(Icons.search, color: accent, size: 21),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: onClear,
                icon: Icon(Icons.close, color: accent),
                tooltip: 'Clear search',
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ResultsHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final _ServiceCategory category;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      child: Material(
        color: selected ? category.color.withAlpha(18) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? category.color
                    : Theme.of(context).colorScheme.outline,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(category.icon, color: category.color, size: 21),
                const SizedBox(height: 3),
                Text(
                  category.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? category.color : AppColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SalonCard extends StatelessWidget {
  final Salon salon;
  final Set<_ServiceCategory> selectedCategories;

  const _SalonCard({required this.salon, required this.selectedCategories});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final matchedServices = selectedCategories.isEmpty
        ? salon.availableServices
        : salon.availableServices
              .where(
                (service) => selectedCategories.any(
                  (category) => category.matches(service),
                ),
              )
              .toList();
    final previewServices = matchedServices
        .take(3)
        .map((s) => s.name)
        .join(', ');
    final barbers = appState.barbersForSalon(salon.id);
    final isBookable = appState.isSalonBookable(salon.id);
    final isCurrentlyOpen = appState.isSalonCurrentlyOpen(salon.id);
    final availabilityLabel = !isBookable
        ? 'Listing visible · booking setup in progress'
        : isCurrentlyOpen
        ? 'Open now'
        : 'Closed now';
    final availabilityColor = isBookable && isCurrentlyOpen
        ? AppColors.success
        : AppColors.muted;
    final instantAvailable = appState.isInstantBookingAvailableForServices(
      salon.id,
      matchedServices.map((service) => service.id),
    );

    void openSalon([SalonDetailEntryAction? entryAction]) {
      if (entryAction == SalonDetailEntryAction.instant) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => InstantServiceSelectionScreen(salonId: salon.id),
          ),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SalonDetailScreen(
            salonId: salon.id,
            entryAction: entryAction,
            directScheduleEntry: entryAction == SalonDetailEntryAction.service,
          ),
        ),
      );
    }

    void scheduleSlot() {
      openSalon(SalonDetailEntryAction.service);
    }

    void showSalonPreview() {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (sheetContext) => _SalonPreviewSheet(
          salon: salon,
          barberCount: barbers.length,
          isCurrentlyOpen: isCurrentlyOpen,
          instantAvailable: instantAvailable,
          onScheduleSlot: () {
            Navigator.pop(sheetContext);
            scheduleSlot();
          },
          onInstant: () {
            Navigator.pop(sheetContext);
            openSalon(SalonDetailEntryAction.instant);
          },
          onCall: salon.phone.trim().isEmpty
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  UrlLauncherUtils.makePhoneCall(context, salon.phone);
                },
          onDirections: () {
            Navigator.pop(sheetContext);
            UrlLauncherUtils.openDirectionsLink(context, salon.directionsUrl);
          },
        ),
      );
    }

    return GlassCard(
      key: ValueKey('salon-card-${salon.id}'),
      onTap: showSalonPreview,
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SalonLogo(
                      key: ValueKey('salon-card-image-${salon.id}'),
                      logoUrl: salon.coverImageUrl,
                      color: AppColors.primary,
                      size: 42,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            salon.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            salon.address.trim().isEmpty
                                ? 'Address not added'
                                : salon.address.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.ink),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            previewServices.isEmpty
                                ? 'Services will be added soon'
                                : previewServices,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            availabilityLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: availabilityColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SalonRating(
                      rating: salon.rating,
                      reviewCount: salon.reviewCount,
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                const Divider(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _SalonFact(
                        icon: Icons.schedule_outlined,
                        label: _compactTimeRange(salon),
                        color: AppColors.primary,
                      ),
                    ),
                    Expanded(
                      child: _SalonFact(
                        icon: Icons.content_cut,
                        label: '${barbers.length} barbers',
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                Row(
                  children: [
                    if (instantAvailable) ...[
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              openSalon(SalonDetailEntryAction.instant),
                          icon: const Icon(Icons.bolt_outlined, size: 19),
                          label: const Text('Book instantly'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        key: ValueKey('salon-card-schedule-${salon.id}'),
                        onPressed: scheduleSlot,
                        icon: const Icon(
                          Icons.event_available_outlined,
                          size: 18,
                        ),
                        label: const Text('Schedule Slot'),
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
}

class _SalonPreviewSheet extends StatelessWidget {
  final Salon salon;
  final int barberCount;
  final bool isCurrentlyOpen;
  final bool instantAvailable;
  final VoidCallback onScheduleSlot;
  final VoidCallback onInstant;
  final VoidCallback? onCall;
  final VoidCallback onDirections;

  const _SalonPreviewSheet({
    required this.salon,
    required this.barberCount,
    required this.isCurrentlyOpen,
    required this.instantAvailable,
    required this.onScheduleSlot,
    required this.onInstant,
    required this.onCall,
    required this.onDirections,
  });

  @override
  Widget build(BuildContext context) {
    final photos = salon.photoUrls;
    return FractionallySizedBox(
      heightFactor: 0.76,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 2, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (photos.isEmpty)
              Container(
                height: 190,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.mint.withAlpha(90),
                  borderRadius: BorderRadius.circular(18),
                ),
                alignment: Alignment.center,
                child: SalonLogo(
                  logoUrl: salon.coverImageUrl,
                  color: AppColors.primary,
                  size: 82,
                ),
              )
            else
              SizedBox(
                key: ValueKey('salon-preview-photos-${salon.id}'),
                height: 190,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.78,
                      child: Image.network(
                        photos[index],
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: AppColors.line,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        salon.displayName,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (salon.address.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          salon.address,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _SalonRating(
                  rating: salon.rating,
                  reviewCount: salon.reviewCount,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AppPill(
                  icon: isCurrentlyOpen
                      ? Icons.check_circle_outline
                      : Icons.schedule_outlined,
                  label: isCurrentlyOpen ? 'Open now' : 'Closed now',
                  color: isCurrentlyOpen ? AppColors.success : AppColors.muted,
                ),
                AppPill(
                  icon: Icons.schedule_outlined,
                  label: _compactTimeRange(salon),
                  color: AppColors.primary,
                ),
                AppPill(
                  icon: Icons.content_cut,
                  label: '$barberCount barbers',
                  color: AppColors.coral,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('salon-preview-call'),
                    onPressed: onCall,
                    icon: const Icon(Icons.call_outlined),
                    label: const Text('Call'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('salon-preview-directions'),
                    onPressed: onDirections,
                    icon: const Icon(Icons.directions_outlined),
                    label: const Text('Directions'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('salon-preview-schedule-slot'),
                    onPressed: onScheduleSlot,
                    icon: const Icon(Icons.event_available_outlined),
                    label: const Text('Schedule Slot'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('salon-preview-book-instantly'),
                    onPressed: instantAvailable ? onInstant : null,
                    icon: const Icon(Icons.bolt_outlined),
                    label: Text(
                      instantAvailable ? 'Book instantly' : 'Unavailable',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SalonFact extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SalonFact({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.ink, fontSize: 14),
          ),
        ),
      ],
    );
  }
}

class _SalonRating extends StatelessWidget {
  final double rating;
  final int reviewCount;

  const _SalonRating({required this.rating, required this.reviewCount});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, color: AppColors.amber, size: 18),
        const SizedBox(width: 3),
        Text(
          '$rating',
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (reviewCount > 0)
          Text(' ($reviewCount)', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

String _compactTimeRange(Salon salon) {
  if (salon.openTime.trim().isEmpty || salon.closeTime.trim().isEmpty) {
    return 'Hours pending';
  }
  String compact(String value) =>
      value.replaceAll(':00', '').replaceAll(' ', '');
  return '${compact(salon.openTime)}-${compact(salon.closeTime)}';
}

class _ServiceCategory {
  final IconData icon;
  final String label;
  final Color color;

  const _ServiceCategory({
    required this.icon,
    required this.label,
    required this.color,
  });

  bool matches(SalonService service) {
    final category = service.category.toLowerCase();
    final name = service.name.toLowerCase();
    switch (label) {
      case 'Haircut':
        return category.contains('hair') && !category.contains('color') ||
            name.contains('cut') ||
            name.contains('fade');
      case 'Beard':
        return category.contains('beard') ||
            category.contains('shav') ||
            name.contains('shave');
      case 'Facial':
        return category.contains('facial') ||
            category.contains('cleanup') ||
            category.contains('skin') ||
            name.contains('facial') ||
            name.contains('cleanup');
      case 'Spa':
        return category.contains('spa') ||
            category.contains('massage') ||
            name.contains('spa') ||
            name.contains('massage');
      case 'Mani/Pedi':
        return category.contains('mani') ||
            category.contains('pedi') ||
            category.contains('nail');
      case 'Threading':
        return category.contains('thread');
      case 'Waxing':
        return category.contains('wax');
      case 'Color':
        return category.contains('color') ||
            category.contains('colour') ||
            name.contains('color') ||
            name.contains('colour');
      case 'Makeup':
        return category.contains('makeup') ||
            category.contains('bridal') ||
            category.contains('groom package') ||
            category.contains('combo') ||
            name.contains('makeup');
      default:
        return false;
    }
  }
}

const _popularCategories = [
  _ServiceCategory(
    icon: Icons.content_cut,
    label: 'Haircut',
    color: AppColors.primary,
  ),
  _ServiceCategory(
    icon: Icons.face_retouching_natural,
    label: 'Beard',
    color: AppColors.goldDeep,
  ),
  _ServiceCategory(
    icon: Icons.spa_outlined,
    label: 'Facial',
    color: AppColors.leaf,
  ),
  _ServiceCategory(icon: Icons.spa, label: 'Spa', color: AppColors.plum),
  _ServiceCategory(
    icon: Icons.back_hand_outlined,
    label: 'Mani/Pedi',
    color: AppColors.rose,
  ),
  _ServiceCategory(
    icon: Icons.gesture,
    label: 'Threading',
    color: AppColors.gold,
  ),
  _ServiceCategory(
    icon: Icons.waves_outlined,
    label: 'Waxing',
    color: AppColors.copper,
  ),
  _ServiceCategory(
    icon: Icons.palette_outlined,
    label: 'Color',
    color: AppColors.copper,
  ),
  _ServiceCategory(
    icon: Icons.auto_awesome,
    label: 'Makeup',
    color: AppColors.rose,
  ),
];
