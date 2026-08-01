import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/booking_status_timeline.dart';
import '../../widgets/salon_logo.dart';
import 'salon_detail_screen.dart';
import 'my_bookings_screen.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  _ServiceCategory? _selectedCategory;
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
    final bookableSalons = appState.bookableSalons;
    final visibleSalons = _rankedSalons(appState);
    final accent = _selectedCategory?.color ?? AppColors.primary;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
    final currentBooking = _currentBooking(appState.customerBookings);

    return Scaffold(
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (currentBooking != null)
            CurrentBookingBottomPanel(
              booking: currentBooking,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
              ),
            ),
          const AppBottomNav(selectedIndex: 0),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: appState.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              _LocationHeader(canLogout: appState.hasActiveCustomerSession),
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
                actionLabel: _selectedCategory == null ? null : 'Clear',
                onAction: _selectedCategory == null
                    ? null
                    : () => setState(() => _selectedCategory = null),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: isIOS ? 92 : 82,
                child: ListView.separated(
                  key: const Key('service-category-list'),
                  scrollDirection: Axis.horizontal,
                  itemCount: _popularCategories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final category = _popularCategories[index];
                    return _CategoryCard(
                      category: category,
                      selected: _selectedCategory == category,
                      count: category.salonCount(bookableSalons),
                      useIOSLayout: isIOS,
                      onTap: () => _toggleCategory(category),
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              _ResultsHeader(
                title: _searchQuery.isNotEmpty
                    ? 'Search results'
                    : (_selectedCategory == null
                          ? 'Recommended'
                          : '${_selectedCategory!.label} matches'),
                subtitle: _selectedCategory == null
                    ? 'Top-rated salons open near you'
                    : 'Open salons offering ${_selectedCategory!.label.toLowerCase()}',
              ),
              const SizedBox(height: 8),
              if (visibleSalons.isEmpty)
                const EmptyState(
                  icon: Icons.search_off,
                  title: 'No open salons found',
                  message: 'Try another service or search again later.',
                )
              else
                for (final salon in visibleSalons) ...[
                  _SalonCard(salon: salon, selectedCategory: _selectedCategory),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Booking? _currentBooking(List<Booking> bookings) {
    final now = DateTime.now();
    final visible = bookings.where((booking) {
      switch (booking.status) {
        case BookingStatus.pending:
        case BookingStatus.confirmed:
        case BookingStatus.inProgress:
          return true;
        case BookingStatus.rejected:
        case BookingStatus.cancelled:
          return now.difference(booking.createdAt).inHours < 24;
        case BookingStatus.completed:
          return false;
      }
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return visible.isEmpty ? null : visible.first;
  }

  void _toggleCategory(_ServiceCategory category) {
    setState(() {
      _selectedCategory = _selectedCategory == category ? null : category;
    });
  }

  List<Salon> _rankedSalons(AppState appState) {
    final category = _selectedCategory;
    final query = _searchQuery.trim().toLowerCase();
    final salons = appState.bookableSalons
        .where(
          (salon) =>
              appState.isSalonCurrentlyOpen(salon.id) &&
              (category == null ||
                  salon.availableServices.any(category.matches)) &&
              (query.isEmpty || _matchesSearch(salon, query)),
        )
        .toList();

    salons.sort((a, b) {
      return b.rating.compareTo(a.rating);
    });

    return salons;
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
  final bool canLogout;

  const _LocationHeader({required this.canLogout});

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
        AccountOverflowMenu(
          role: UserRole.customer,
          canLogout: canLogout,
          onNotificationOpened: (destination) {
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
  final int count;
  final bool useIOSLayout;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.category,
    required this.selected,
    required this.count,
    required this.useIOSLayout,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: useIOSLayout ? 112 : 104,
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
                    fontSize: useIOSLayout ? 14 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$count shops',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? category.color : AppColors.muted,
                    fontSize: useIOSLayout ? 14 : 12,
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
  final _ServiceCategory? selectedCategory;

  const _SalonCard({required this.salon, this.selectedCategory});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final accent = selectedCategory?.color ?? AppColors.primary;
    final matchedServices = selectedCategory == null
        ? salon.availableServices
        : salon.availableServices.where(selectedCategory!.matches).toList();
    final previewServices = matchedServices
        .take(3)
        .map((s) => s.name)
        .join(', ');
    final barbers = appState.barbersForSalon(salon.id);
    final instantAvailable = appState.isInstantBookingAvailableForServices(
      salon.id,
      matchedServices.map((service) => service.id),
    );

    void openSalon() {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SalonDetailScreen(salonId: salon.id)),
      );
    }

    return GlassCard(
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
                      logoUrl: salon.coverImageUrl,
                      color: accent,
                      size: 42,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            salon.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            previewServices,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
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
                        label: _compactTimeRange(
                          salon,
                          compactForIOS:
                              Theme.of(context).platform == TargetPlatform.iOS,
                        ),
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
                    Expanded(
                      child: _SalonFact(
                        icon: Icons.near_me_outlined,
                        label: salon.distanceLabel,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                Row(
                  children: [
                    if (Theme.of(context).platform == TargetPlatform.iOS)
                      Expanded(
                        child: _IOSSalonActions(
                          instantAvailable: instantAvailable,
                          onPressed: openSalon,
                        ),
                      )
                    else ...[
                      if (instantAvailable) ...[
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: openSalon,
                            icon: const Icon(Icons.bolt_outlined, size: 19),
                            label: const Text('Book instantly'),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: openSalon,
                          icon: const Icon(Icons.storefront_outlined, size: 18),
                          label: const Text('View salon'),
                        ),
                      ),
                    ],
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

class _IOSSalonActions extends StatelessWidget {
  final bool instantAvailable;
  final VoidCallback onPressed;

  const _IOSSalonActions({
    required this.instantAvailable,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (instantAvailable) ...[
          Expanded(
            child: FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const _CompactButtonLabel(
                icon: Icons.bolt_outlined,
                label: 'Book instantly',
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const _CompactButtonLabel(
              icon: Icons.storefront_outlined,
              label: 'View salon',
            ),
          ),
        ),
      ],
    );
  }
}

class _CompactButtonLabel extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CompactButtonLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
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

String _compactTimeRange(Salon salon, {bool compactForIOS = false}) {
  String compact(String value) =>
      value.replaceAll(':00', '').replaceAll(' ', '');
  var opening = compact(salon.openTime);
  if (compactForIOS) {
    opening = opening.replaceFirst(RegExp(r'(AM|PM)$'), '');
  }
  return '$opening-${compact(salon.closeTime)}';
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

  int salonCount(List<Salon> salons) {
    return salons.where((salon) => salon.availableServices.any(matches)).length;
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
