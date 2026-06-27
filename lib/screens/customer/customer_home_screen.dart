import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/salon_logo.dart';
import '../../widgets/service_icon.dart';
import '../../widgets/trimtime_logo.dart';
import 'salon_booking_screen.dart';
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
    final openSalons = bookableSalons.where((salon) => salon.isOpen).length;
    final availableSlots = bookableSalons.fold<int>(
      0,
      (sum, salon) => sum + appState.availableSlotCountForSalon(salon.id),
    );
    final visibleSalons = _rankedSalons(appState);
    final accent = _selectedCategory?.color ?? AppColors.primary;

    return Scaffold(
      bottomNavigationBar: const AppBottomNav(selectedIndex: 0),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: appState.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
            children: [
              _BrandHeader(
                openSalons: openSalons,
                accent: accent,
                canLogout: appState.hasActiveCustomerSession,
              ),
              const SizedBox(height: 14),
              _HomeCommand(
                accent: accent,
                openSalons: openSalons,
                availableSlots: availableSlots,
                selectedCategory: _selectedCategory,
                searchController: _searchController,
                onSearchChanged: (value) =>
                    setState(() => _searchQuery = value),
                onClearSearch: _searchQuery.isEmpty
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
              const SizedBox(height: 10),
              SizedBox(
                height: 82,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final category in _popularCategories)
                      _CategoryChip(
                        category: category,
                        selected: _selectedCategory == category,
                        count: category.salonCount(bookableSalons),
                        onTap: () => _toggleCategory(category),
                      ),
                  ],
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
                    ? 'Sorted by opening, slots, and rating.'
                    : 'Filtered by service, then ranked by open status, next slot, and rating.',
                accent: accent,
              ),
              const SizedBox(height: 10),
              if (visibleSalons.isEmpty)
                const EmptyState(
                  icon: Icons.search_off,
                  title: 'No matching services',
                  message: 'Try another service or check nearby salons later.',
                )
              else
                for (final salon in visibleSalons) ...[
                  _SalonCard(salon: salon, selectedCategory: _selectedCategory),
                  const SizedBox(height: 14),
                ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleCategory(_ServiceCategory category) {
    setState(() {
      _selectedCategory = _selectedCategory == category ? null : category;
    });
  }

  List<Salon> _rankedSalons(AppState appState) {
    final category = _selectedCategory;
    final query = _searchQuery.trim().toLowerCase();
    if (category == null) {
      final salons = List<Salon>.from(appState.bookableSalons);
      if (query.isEmpty) {
        return salons;
      }
      return salons.where((salon) => _matchesSearch(salon, query)).toList();
    }

    final salons = appState.bookableSalons
        .where(
          (salon) =>
              salon.services.any(category.matches) &&
              (query.isEmpty || _matchesSearch(salon, query)),
        )
        .toList();

    salons.sort((a, b) {
      final openCompare = (b.isOpen ? 1 : 0).compareTo(a.isOpen ? 1 : 0);
      if (openCompare != 0) {
        return openCompare;
      }

      final aSlot = _earliestSlotForCategory(appState, a, category);
      final bSlot = _earliestSlotForCategory(appState, b, category);
      if (aSlot != null && bSlot != null) {
        final slotCompare = aSlot.start.compareTo(bSlot.start);
        if (slotCompare != 0) {
          return slotCompare;
        }
      } else if (aSlot != null) {
        return -1;
      } else if (bSlot != null) {
        return 1;
      }

      return b.rating.compareTo(a.rating);
    });

    return salons;
  }

  bool _matchesSearch(Salon salon, String query) {
    return salon.name.toLowerCase().contains(query) ||
        salon.address.toLowerCase().contains(query) ||
        salon.ownerName.toLowerCase().contains(query) ||
        salon.services.any(
          (service) =>
              service.name.toLowerCase().contains(query) ||
              service.category.toLowerCase().contains(query),
        );
  }

  TimeSlot? _earliestSlotForCategory(
    AppState appState,
    Salon salon,
    _ServiceCategory category,
  ) {
    return appState.earliestSlotForServices(
      salon.id,
      salon.services.where(category.matches).map((service) => service.id),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final int openSalons;
  final Color accent;
  final bool canLogout;

  const _BrandHeader({
    required this.openSalons,
    required this.accent,
    required this.canLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const TrimtimeLogo(size: 48),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pritze',
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(fontSize: 25, height: 1),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    color: AppColors.muted,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Skip the wait · $openSalons open now',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
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

class _HomeCommand extends StatelessWidget {
  final Color accent;
  final int openSalons;
  final int availableSlots;
  final _ServiceCategory? selectedCategory;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback? onClearSearch;

  const _HomeCommand({
    required this.accent,
    required this.openSalons,
    required this.availableSlots,
    required this.selectedCategory,
    required this.searchController,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selectedCategory == null
                ? 'Skip the wait. Book your cut.'
                : '${selectedCategory!.label} sorted by availability',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontSize: 24),
          ),
          const SizedBox(height: 8),
          Text(
            selectedCategory == null
                ? 'Search services, compare barbers, and lock a live slot in a few taps.'
                : 'Open shops appear first, then earliest slots, then rating.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          _HeroSearch(
            accent: accent,
            controller: searchController,
            onChanged: onSearchChanged,
            onClear: onClearSearch,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _CompactSignal(
                icon: Icons.storefront_outlined,
                value: '$openSalons open',
                color: accent,
              ),
              const SizedBox(width: 8),
              _CompactSignal(
                icon: Icons.event_available_outlined,
                value: '$availableSlots slots',
                color: accent,
              ),
              const Spacer(),
              Container(
                height: 36,
                width: 36,
                decoration: BoxDecoration(
                  color: accent.withAlpha(18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.arrow_forward, color: accent, size: 19),
              ),
            ],
          ),
        ],
      ),
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
        suffixIcon: IconButton(
          onPressed: onClear,
          icon: Icon(
            controller.text.isEmpty ? Icons.tune : Icons.close,
            color: accent,
          ),
          tooltip: controller.text.isEmpty ? 'Filters' : 'Clear search',
        ),
        filled: true,
        fillColor: AppColors.canvas,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
    );
  }
}

class _CompactSignal extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color color;

  const _CompactSignal({
    required this.icon,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color accent;

  const _ResultsHeader({
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        Container(
          height: 34,
          width: 34,
          decoration: BoxDecoration(
            color: accent.withAlpha(18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.swap_vert, color: accent, size: 19),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final _ServiceCategory category;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: selected ? category.color.withAlpha(18) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: 142,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? category.color : AppColors.line,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                ServiceImageIcon(
                  category: category.label,
                  color: category.color,
                  size: 42,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? category.color : AppColors.ink,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count shops',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? category.color : AppColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: category.color, size: 18),
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
        ? salon.services
        : salon.services.where(selectedCategory!.matches).toList();
    final previewServices = matchedServices
        .take(3)
        .map((s) => s.name)
        .join(', ');
    final barbers = appState.barbersForSalon(salon.id);
    final nextSlot = _earliestSlotForServices(
      appState,
      salon.id,
      matchedServices,
    );
    final nextSlotLabel = nextSlot == null
        ? 'No slot'
        : appState.formatTime(nextSlot.start);

    return GlassCard(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SalonDetailScreen(salonId: salon.id),
          ),
        );
      },
      padding: const EdgeInsets.all(0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 5,
              decoration: BoxDecoration(
                color: salon.isOpen ? accent : AppColors.muted,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(18),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SalonLogo(
                          logoUrl: salon.coverImageUrl,
                          color: accent,
                          size: 46,
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
                                style: Theme.of(
                                  context,
                                ).textTheme.titleLarge?.copyWith(fontSize: 18),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                previewServices,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _MiniStatus(
                          label: salon.isOpen ? 'Open' : 'Closed',
                          color: salon.isOpen ? accent : AppColors.muted,
                        ),
                      ],
                    ),
                    const SizedBox(height: 13),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MetaChip(
                          icon: Icons.star,
                          label: '${salon.rating}',
                          color: AppColors.amber,
                        ),
                        _MetaChip(
                          icon: Icons.schedule,
                          label: nextSlotLabel,
                          color: accent,
                        ),
                        _MetaChip(
                          icon: Icons.badge_outlined,
                          label: '${barbers.length} barbers',
                          color: AppColors.primary,
                        ),
                        _MetaChip(
                          icon: Icons.near_me_outlined,
                          label: salon.distanceLabel,
                          color: AppColors.muted,
                        ),
                      ],
                    ),
                    if (selectedCategory != null) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final service in matchedServices.take(3))
                            _ServiceShortcut(
                              service: service,
                              color: accent,
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
                          if (matchedServices.length > 3)
                            _MetaChip(
                              label: '+${matchedServices.length - 3} more',
                              color: accent,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _AvatarStack(barbers: barbers, color: accent),
                        const Spacer(),
                        Text(
                          selectedCategory == null
                              ? 'View'
                              : 'Book ${selectedCategory!.label.toLowerCase()}',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward, color: accent, size: 18),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStatus extends StatelessWidget {
  final String label;
  final Color color;

  const _MiniStatus({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;

  const _MetaChip({this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarStack extends StatelessWidget {
  final List<Barber> barbers;
  final Color color;

  const _AvatarStack({required this.barbers, required this.color});

  @override
  Widget build(BuildContext context) {
    final visibleBarbers = barbers.take(3).toList();
    final remaining = barbers.length - visibleBarbers.length;
    if (visibleBarbers.isEmpty) {
      return _MetaChip(
        icon: Icons.badge_outlined,
        label: 'No staff',
        color: AppColors.muted,
      );
    }

    return SizedBox(
      width:
          28.0 + ((visibleBarbers.length - 1) * 20) + (remaining > 0 ? 24 : 0),
      height: 28,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var index = 0; index < visibleBarbers.length; index++)
            Positioned(
              left: index * 20,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: color.withAlpha(28),
                foregroundColor: color,
                child: Text(
                  visibleBarbers[index].name.characters.first,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          if (remaining > 0)
            Positioned(
              left: visibleBarbers.length * 20,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.champagne,
                foregroundColor: color,
                child: Text(
                  '+$remaining',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

TimeSlot? _earliestSlotForServices(
  AppState appState,
  String salonId,
  Iterable<SalonService> services,
) {
  return appState.earliestSlotForServices(
    salonId,
    services.map((service) => service.id),
  );
}

class _ServiceShortcut extends StatelessWidget {
  final SalonService service;
  final Color color;
  final VoidCallback onTap;

  const _ServiceShortcut({
    required this.service,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(Icons.event_available, size: 18, color: color),
      label: Text('${service.name} · ₹${service.price}'),
      onPressed: onTap,
      backgroundColor: color.withAlpha(16),
      side: BorderSide.none,
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.w800),
    );
  }
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
    return salons.where((salon) => salon.services.any(matches)).length;
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
  _ServiceCategory(icon: Icons.spa, label: 'Spa', color: AppColors.charcoal),
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
