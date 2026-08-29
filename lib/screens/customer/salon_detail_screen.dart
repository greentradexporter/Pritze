import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../utils/url_launcher_utils.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/booking_status_timeline.dart';
import '../../widgets/salon_logo.dart';
import 'my_bookings_screen.dart';
import 'salon_booking_screen.dart';

enum SalonDetailEntryAction { instant, service, barber }

class SalonDetailScreen extends StatefulWidget {
  final String salonId;
  final SalonDetailEntryAction? entryAction;
  final bool directScheduleEntry;

  const SalonDetailScreen({
    super.key,
    required this.salonId,
    this.entryAction,
    this.directScheduleEntry = false,
  });

  @override
  State<SalonDetailScreen> createState() => _SalonDetailScreenState();
}

class _SalonDetailScreenState extends State<SalonDetailScreen> {
  bool _openedEntryAction = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.salonId);

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
    final isBookable = appState.isSalonBookable(salon.id);
    final isSetupComplete = appState.isSalonSetupComplete(salon.id);
    final isCurrentlyOpen = appState.isSalonCurrentlyOpen(salon.id);
    final canBookNow = isBookable && isCurrentlyOpen;
    final barbers = appState.barbersForSalon(salon.id);
    final instantServices = services
        .where(
          (service) => appState.isInstantBookingAvailable(
            salon.id,
            serviceId: service.id,
          ),
        )
        .toList();

    if (!_openedEntryAction && widget.entryAction != null) {
      _openedEntryAction = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        switch (widget.entryAction!) {
          case SalonDetailEntryAction.instant:
            _showServicePickerSheet(context, salon, instantOnly: true);
          case SalonDetailEntryAction.service:
            final selected = await _showServicePickerSheet(
              context,
              salon,
              replacePageOnSelection: widget.directScheduleEntry,
            );
            if (widget.directScheduleEntry && !selected && context.mounted) {
              Navigator.of(context).maybePop();
            }
          case SalonDetailEntryAction.barber:
            _showBarberPickerSheet(context, salon, barbers);
        }
      });
    }

    return Scaffold(
      bottomNavigationBar: CustomerActiveBookingFooter(
        onOpenBooking: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen())),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 236,
            pinned: true,
            backgroundColor: AppColors.canvas,
            surfaceTintColor: Colors.transparent,
            title: Text(salon.displayName),
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
                        onPressed: salon.phone.trim().isEmpty
                            ? null
                            : () {
                                UrlLauncherUtils.makePhoneCall(
                                  context,
                                  salon.phone,
                                );
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
                if (!canBookNow) ...[
                  const SizedBox(height: 10),
                  GlassCard(
                    color: AppColors.champagne.withAlpha(80),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: AppColors.goldDeep,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isSetupComplete
                                ? 'This salon is currently closed. You can still view its services and team.'
                                : 'This salon is listed while its booking setup is being completed.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                if (services.isNotEmpty || barbers.isNotEmpty) ...[
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
                ],
                const SizedBox(height: 22),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openService(
    BuildContext context,
    Salon salon,
    SalonService service, {
    bool instantOnly = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SalonBookingScreen(
          salonId: salon.id,
          serviceId: service.id,
          instantOnly: instantOnly,
        ),
      ),
    );
  }

  Future<bool> _showServicePickerSheet(
    BuildContext context,
    Salon salon, {
    bool instantOnly = false,
    bool replacePageOnSelection = false,
  }) {
    final appState = AppStateScope.read(context);
    final pageContext = context;
    final searchController = TextEditingController();
    var searchQuery = '';
    var selectedService = false;
    final selectedInstantIds = <String>{};
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
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final normalizedQuery = searchQuery.trim().toLowerCase();
          final visibleServices = services.where((service) {
            if (normalizedQuery.isEmpty) {
              return true;
            }
            return service.name.toLowerCase().contains(normalizedQuery) ||
                service.category.toLowerCase().contains(normalizedQuery);
          }).toList();
          return FractionallySizedBox(
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
                            ? 'Choose instant services'
                            : 'Choose a service',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        instantOnly
                            ? 'Select one or more services. The salon will assign one available barber who can perform all of them.'
                            : 'Pick a service first, then choose an available barber.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('salon-service-search-field'),
                        controller: searchController,
                        textInputAction: TextInputAction.search,
                        onChanged: (value) {
                          setSheetState(() => searchQuery = value);
                        },
                        decoration: InputDecoration(
                          hintText: 'Search this salon’s services',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear service search',
                                  onPressed: () {
                                    searchController.clear();
                                    setSheetState(() => searchQuery = '');
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: visibleServices.isEmpty
                      ? const EmptyState(
                          icon: Icons.search_off,
                          title: 'No matching services',
                          message: 'Try another service name or category.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(18),
                          itemCount: visibleServices.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final service = visibleServices[index];
                            return _ServiceTile(
                              service: service,
                              availableBarbers: appState
                                  .barbersForService(salon.id, service.id)
                                  .length,
                              selected: selectedInstantIds.contains(service.id),
                              multiSelect: instantOnly,
                              onTap: () {
                                if (!appState.isSalonCurrentlyOpen(salon.id)) {
                                  _showBookingUnavailable(pageContext, salon);
                                  return;
                                }
                                if (!appState.isSalonBookable(salon.id)) {
                                  _showBookingUnavailable(pageContext, salon);
                                  return;
                                }
                                if (instantOnly) {
                                  setSheetState(() {
                                    if (!selectedInstantIds.add(service.id)) {
                                      selectedInstantIds.remove(service.id);
                                    }
                                  });
                                  return;
                                }
                                selectedService = true;
                                Navigator.pop(sheetContext);
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (pageContext.mounted) {
                                    if (replacePageOnSelection) {
                                      Navigator.of(pageContext).pushReplacement(
                                        MaterialPageRoute(
                                          builder: (_) => SalonBookingScreen(
                                            salonId: salon.id,
                                            serviceId: service.id,
                                          ),
                                        ),
                                      );
                                    } else {
                                      _openService(pageContext, salon, service);
                                    }
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
                if (instantOnly) ...[
                  const Divider(height: 1),
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(18, 12, 18, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('continue-instant-services'),
                        onPressed: selectedInstantIds.isEmpty
                            ? null
                            : () {
                                final selected = selectedInstantIds.toList();
                                Navigator.pop(sheetContext);
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!pageContext.mounted) return;
                                  Navigator.of(pageContext).push(
                                    MaterialPageRoute(
                                      builder: (_) => SalonBookingScreen(
                                        salonId: salon.id,
                                        serviceId: selected.first,
                                        initialInstantServiceIds: selected,
                                        instantOnly: true,
                                      ),
                                    ),
                                  );
                                });
                              },
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: Text(
                          selectedInstantIds.isEmpty
                              ? 'Choose at least one service'
                              : 'Continue with ${selectedInstantIds.length} ${selectedInstantIds.length == 1 ? 'service' : 'services'}',
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ).then((_) => selectedService).whenComplete(searchController.dispose);
  }

  Future<void> _showBarberPickerSheet(
    BuildContext context,
    Salon salon,
    List<Barber> barbers,
  ) {
    final pageContext = context;
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
                      itemBuilder: (itemContext, index) {
                        final barber = barbers[index];
                        return GlassCard(
                          onTap: () {
                            final appState = AppStateScope.read(pageContext);
                            if (!appState.isSalonCurrentlyOpen(salon.id) ||
                                !appState.isSalonBookable(salon.id)) {
                              _showBookingUnavailable(pageContext, salon);
                              return;
                            }
                            Navigator.pop(sheetContext);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (pageContext.mounted) {
                                _showBarberServiceSheet(
                                  pageContext,
                                  salon,
                                  barber,
                                );
                              }
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
                                        itemContext,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${barber.experienceYears} yrs · ${barber.speciality}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        itemContext,
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
                        final appState = AppStateScope.read(context);
                        if (!appState.isSalonCurrentlyOpen(salon.id) ||
                            !appState.isSalonBookable(salon.id)) {
                          _showBookingUnavailable(context, salon);
                          return;
                        }
                        Navigator.of(sheetContext).pop();
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SalonBookingScreen(
                                salonId: salon.id,
                                serviceId: service.id,
                                initialBarberId: barber.id,
                              ),
                            ),
                          );
                        });
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

  void _showBookingUnavailable(BuildContext context, Salon salon) {
    final appState = AppStateScope.read(context);
    final setupComplete = appState.isSalonSetupComplete(salon.id);
    final message = setupComplete
        ? '${salon.displayName} is currently closed. You can browse services and barbers, but appointments can only be placed while the salon is open.'
        : '${salon.displayName} is still completing its booking setup. You can browse the listing, but appointments are not available yet.';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.schedule_outlined),
        title: Text(setupComplete ? 'Salon is closed' : 'Booking unavailable'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

class InstantServiceSelectionScreen extends StatefulWidget {
  final String salonId;

  const InstantServiceSelectionScreen({super.key, required this.salonId});

  @override
  State<InstantServiceSelectionScreen> createState() =>
      _InstantServiceSelectionScreenState();
}

class _InstantServiceSelectionScreenState
    extends State<InstantServiceSelectionScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedServiceIds = {};
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.salonId);
    if (salon == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Choose services')),
        body: const EmptyState(
          icon: Icons.storefront_outlined,
          title: 'Salon not found',
          message: 'This salon is no longer available.',
        ),
      );
    }

    final instantServices = salon.availableServices
        .where(
          (service) => appState.isInstantBookingAvailable(
            salon.id,
            serviceId: service.id,
          ),
        )
        .toList();
    final normalizedQuery = _searchQuery.trim().toLowerCase();
    final visibleServices = instantServices.where((service) {
      return normalizedQuery.isEmpty ||
          service.name.toLowerCase().contains(normalizedQuery) ||
          service.category.toLowerCase().contains(normalizedQuery);
    }).toList();

    return Scaffold(
      appBar: AppBar(title: Text(salon.displayName)),
      bottomNavigationBar: CustomerActiveBookingFooter(
        onOpenBooking: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen())),
        action: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: FilledButton.icon(
            key: const ValueKey('continue-instant-services'),
            onPressed: _selectedServiceIds.isEmpty
                ? null
                : () => _continueToBooking(salon),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(
              _selectedServiceIds.isEmpty
                  ? 'Choose at least one service'
                  : 'Continue with ${_selectedServiceIds.length} ${_selectedServiceIds.length == 1 ? 'service' : 'services'}',
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose instant services',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Select one or more services. The salon will assign an available barber.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const ValueKey('salon-service-search-field'),
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search this salon’s services',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear service search',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                              icon: const Icon(Icons.close),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visibleServices.isEmpty
                  ? const EmptyState(
                      icon: Icons.design_services_outlined,
                      title: 'No instant services available',
                      message:
                          'Try again while the salon is accepting instant bookings.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(18),
                      itemCount: visibleServices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final service = visibleServices[index];
                        return _ServiceTile(
                          service: service,
                          availableBarbers: appState
                              .barbersForService(salon.id, service.id)
                              .length,
                          selected: _selectedServiceIds.contains(service.id),
                          multiSelect: true,
                          onTap: () {
                            if (!appState.isSalonCurrentlyOpen(salon.id) ||
                                !appState.isSalonBookable(salon.id)) {
                              _showBookingUnavailable(context, salon);
                              return;
                            }
                            setState(() {
                              if (!_selectedServiceIds.add(service.id)) {
                                _selectedServiceIds.remove(service.id);
                              }
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

  void _continueToBooking(Salon salon) {
    final selected = _selectedServiceIds.toList();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SalonBookingScreen(
          salonId: salon.id,
          serviceId: selected.first,
          initialInstantServiceIds: selected,
          instantOnly: true,
        ),
      ),
    );
  }

  void _showBookingUnavailable(BuildContext context, Salon salon) {
    final appState = AppStateScope.read(context);
    final setupComplete = appState.isSalonSetupComplete(salon.id);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.schedule_outlined),
        title: Text(setupComplete ? 'Salon is closed' : 'Booking unavailable'),
        content: Text(
          setupComplete
              ? '${salon.displayName} is currently closed. You can browse services, but appointments can only be placed while the salon is open.'
              : '${salon.displayName} is still completing its booking setup. Appointments are not available yet.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Got it'),
          ),
        ],
      ),
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
                                    salon.displayName,
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
                            if (salon.address.trim().isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                salon.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
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

  const _DetailFact({
    required this.icon,
    required this.label,
    required this.color,
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 5),
        labelText,
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

class _ServiceTile extends StatelessWidget {
  final SalonService service;
  final int availableBarbers;
  final VoidCallback? onTap;
  final bool selected;
  final bool multiSelect;

  const _ServiceTile({
    required this.service,
    required this.availableBarbers,
    required this.onTap,
    this.selected = false,
    this.multiSelect = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.mint.withAlpha(110) : AppColors.surface,
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
              if (multiSelect) ...[
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline_rounded,
                  color: selected ? AppColors.primary : AppColors.muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _compactTimeRange(Salon salon) {
  return formatSalonHoursRange(salon);
}
