import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';

import '../../models/app_models.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/auth_login_panel.dart';
import '../../widgets/booking_status_timeline.dart';
import '../../widgets/salon_logo.dart';
import 'my_bookings_screen.dart';

class SalonBookingScreen extends StatefulWidget {
  final String salonId;
  final String serviceId;
  final String? initialBarberId;
  final String? rescheduleBookingId;
  final bool instantOnly;
  final List<String> initialInstantServiceIds;

  const SalonBookingScreen({
    super.key,
    required this.salonId,
    required this.serviceId,
    this.initialBarberId,
    this.rescheduleBookingId,
    this.instantOnly = false,
    this.initialInstantServiceIds = const [],
  });

  @override
  State<SalonBookingScreen> createState() => _SalonBookingScreenState();
}

class _SalonBookingScreenState extends State<SalonBookingScreen> {
  String? _selectedSlotKey;
  String? _selectedBarberId;
  bool _isBooking = false;
  bool _isInstantBooking = false;
  int _instantArrivalMinutes = 15;
  String _discountQuoteKey = '';
  Future<DiscountQuote>? _discountQuoteFuture;
  String _proinQuoteKey = '';
  Future<ProinBookingQuote>? _proinQuoteFuture;
  String _proinWalletKey = '';
  Future<ProinWalletSummary>? _proinWalletFuture;
  String _visibleDiscountOffersKey = '';
  Future<List<CheckoutDiscountOffer>>? _visibleDiscountOffersFuture;
  bool _useProin = false;
  final TextEditingController _couponController = TextEditingController();
  bool _isApplyingCoupon = false;
  String _applyingVisibleCampaignId = '';
  String _appliedVisibleCampaignId = '';
  String _couponMessage = '';
  bool _couponApplied = false;

  bool get _priceSelectionPending =>
      _isApplyingCoupon || _applyingVisibleCampaignId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _selectedBarberId = widget.initialBarberId;
  }

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
  }

  String _discountKey(
    AppState appState,
    String salonId,
    Iterable<String> serviceIds,
  ) {
    final ids = serviceIds.toSet().toList()..sort();
    return '${appState.customerAccount?.id ?? 'guest'}|$salonId|${ids.join(',')}';
  }

  Future<DiscountQuote> _discountQuote(
    AppState appState,
    String salonId,
    Iterable<String> serviceIds,
  ) {
    final ids = serviceIds.toSet().toList()..sort();
    final key = _discountKey(appState, salonId, ids);
    if (_discountQuoteFuture == null || _discountQuoteKey != key) {
      final originalAmount = ids.fold<int>(
        0,
        (total, id) => total + (appState.getService(salonId, id)?.price ?? 0),
      );
      _discountQuoteKey = key;
      _discountQuoteFuture = Future.value(
        DiscountQuote(originalAmount: originalAmount),
      );
    }
    return _discountQuoteFuture!;
  }

  Future<ProinBookingQuote> _proinQuote(
    AppState appState,
    String salonId,
    Iterable<String> serviceIds,
    Future<DiscountQuote> discountFuture,
  ) {
    final ids = serviceIds.toSet().toList()..sort();
    final key =
        '${appState.customerAccount?.id ?? 'guest'}|$salonId|${ids.join(',')}';
    if (_proinQuoteFuture == null || _proinQuoteKey != key) {
      _proinQuoteKey = key;
      _proinQuoteFuture = discountFuture.then(
        (discount) => appState.getProinBookingQuote(
          salonId: salonId,
          serviceIds: ids,
          discountQuote: discount,
        ),
      );
    }
    return _proinQuoteFuture!;
  }

  Future<ProinWalletSummary> _customerProinWallet(AppState appState) {
    final key = appState.customerAccount?.id ?? 'guest';
    if (_proinWalletFuture == null || _proinWalletKey != key) {
      _proinWalletKey = key;
      _proinWalletFuture = appState.refreshCustomerProinWallet();
    }
    return _proinWalletFuture!;
  }

  Future<List<CheckoutDiscountOffer>> _visibleDiscountOffers(
    AppState appState,
    String salonId,
    Iterable<String> serviceIds,
  ) {
    final ids = serviceIds.toSet().toList()..sort();
    final key = _discountKey(appState, salonId, ids);
    if (_visibleDiscountOffersFuture == null ||
        _visibleDiscountOffersKey != key) {
      _visibleDiscountOffersKey = key;
      _visibleDiscountOffersFuture = appState.listCheckoutDiscountOffers(
        salonId: salonId,
        serviceIds: ids,
      );
    }
    return _visibleDiscountOffersFuture!;
  }

  void _retryVisibleDiscountOffers() {
    setState(() {
      _visibleDiscountOffersKey = '';
      _visibleDiscountOffersFuture = null;
    });
  }

  void _setUseProin(bool value) {
    setState(() {
      _useProin = value;
      if (value) {
        _proinQuoteFuture = null;
        _proinQuoteKey = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.salonId);
    final isRescheduling = widget.rescheduleBookingId != null;
    final isInstantOnly = widget.instantOnly && !isRescheduling;
    final requestedInstantIds = <String>{
      ...widget.initialInstantServiceIds,
      if (widget.serviceId.trim().isNotEmpty) widget.serviceId,
    }.toList();
    final instantServices = requestedInstantIds
        .map((id) => appState.getService(widget.salonId, id))
        .whereType<SalonService>()
        .toList();
    final primaryService = appState.getService(
      widget.salonId,
      widget.serviceId,
    );
    final service = isInstantOnly && instantServices.isNotEmpty
        ? SalonService(
            id: instantServices.first.id,
            name: instantServices.map((item) => item.name).join(', '),
            category: 'Instant services',
            price: instantServices.fold<int>(
              0,
              (total, item) => total + item.price,
            ),
            durationMinutes: instantServices.fold<int>(
              0,
              (total, item) => total + item.durationMinutes,
            ),
          )
        : primaryService;

    if (salon == null ||
        service == null ||
        (!isInstantOnly && !service.isAvailable) ||
        (isInstantOnly &&
            (instantServices.length != requestedInstantIds.length ||
                instantServices.any((item) => !item.isAvailable)))) {
      return Scaffold(
        appBar: AppBar(title: const Text('Book')),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Service unavailable',
          message: 'The salon has temporarily hidden this service.',
        ),
      );
    }

    final eligibleBarbers = isInstantOnly
        ? appState.barbersForServices(widget.salonId, requestedInstantIds)
        : appState.barbersForService(widget.salonId, widget.serviceId);
    final canRequestInstant =
        appState.isInstantMultiServiceBookingAvailable(
          salon.id,
          requestedInstantIds,
          arrivalMinutes: _instantArrivalMinutes,
        ) &&
        eligibleBarbers.isNotEmpty;
    final activeCustomerBooking = appState.activeCustomerBooking;
    final blockingBooking =
        activeCustomerBooking != null &&
        activeCustomerBooking.id != widget.rescheduleBookingId;
    final selectedBarberId =
        eligibleBarbers.any((barber) => barber.id == _selectedBarberId)
        ? _selectedBarberId
        : null;
    final selectedBarber = eligibleBarbers
        .where((barber) => barber.id == selectedBarberId)
        .firstOrNull;
    final slots = appState.slotsForService(
      widget.salonId,
      widget.serviceId,
      barberId: selectedBarberId,
    );
    final selectedSlot = slots
        .where((slot) => slot.key == _selectedSlotKey)
        .firstOrNull;
    const accent = AppColors.primary;
    final pricingServiceIds = isInstantOnly
        ? requestedInstantIds
        : <String>[service.id];
    final discountFuture = appState.customerAccount == null
        ? null
        : _discountQuote(appState, salon.id, pricingServiceIds);
    final walletFuture = appState.customerAccount == null || isRescheduling
        ? null
        : _customerProinWallet(appState);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isRescheduling
              ? 'Reschedule'
              : isInstantOnly
              ? 'Instant booking'
              : 'Book slot',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: AppPill(
              icon: Icons.currency_rupee,
              label: '${service.price}',
              color: accent,
              backgroundColor: accent.withAlpha(16),
            ),
          ),
        ],
      ),
      bottomNavigationBar: CustomerActiveBookingFooter(
        onOpenBooking: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen())),
        action: isInstantOnly
            ? null
            : SafeArea(
                minimum: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                child: FilledButton.icon(
                  onPressed:
                      selectedSlot == null ||
                          _isBooking ||
                          blockingBooking ||
                          _priceSelectionPending
                      ? null
                      : () => _startBookingLogin(context, selectedSlot),
                  icon: _isBooking
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle),
                  label: Text(
                    _isBooking
                        ? 'Booking...'
                        : blockingBooking
                        ? 'Cancel current booking first'
                        : isRescheduling
                        ? 'Confirm new time'
                        : 'Confirm appointment',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        children: [
          _BookingSummary(
            salon: salon,
            service: service,
            barberCount: eligibleBarbers.length,
            accent: accent,
            showBookingFee: false,
          ),
          const SizedBox(height: 12),
          if (!appState.hasActiveCustomerSession)
            const _SignInForOfferCard()
          else
            FutureBuilder<DiscountQuote>(
              future: discountFuture,
              builder: (context, discountSnapshot) {
                if (discountSnapshot.hasError) {
                  return _PricingErrorCard(
                    onRetry: _clearPricingQuotes,
                    message: _bookingErrorText(discountSnapshot.error!),
                  );
                }
                final discount = discountSnapshot.data;
                final discountLoading =
                    discountSnapshot.connectionState != ConnectionState.done;
                if (isRescheduling || discount == null) {
                  return _DiscountQuoteCard(
                    originalAmount: service.price,
                    quote: discount,
                    loading: discountLoading,
                  );
                }
                return FutureBuilder<ProinWalletSummary>(
                  future: walletFuture,
                  builder: (context, walletSnapshot) {
                    final walletError = walletSnapshot.hasError
                        ? _bookingErrorText(walletSnapshot.error!)
                        : '';
                    final wallet =
                        walletSnapshot.data ?? appState.customerProinWallet;
                    final walletLoading =
                        walletSnapshot.connectionState !=
                            ConnectionState.done &&
                        wallet.availableProin <= 0;
                    final canToggleProin =
                        wallet.availableProin > 0 && walletError.isEmpty;
                    if (!_useProin || !canToggleProin) {
                      final useProin = false;
                      return Column(
                        children: [
                          _DiscountQuoteCard(
                            originalAmount: service.price,
                            quote: discount,
                            loading: discountLoading,
                            useProin: useProin,
                          ),
                          const SizedBox(height: 10),
                          _ProinRedemptionCard(
                            wallet: wallet,
                            quote: null,
                            loading: walletLoading,
                            quoteLoading: false,
                            error: walletError,
                            selected: false,
                            onChanged: canToggleProin ? _setUseProin : null,
                          ),
                        ],
                      );
                    }
                    return FutureBuilder<ProinBookingQuote>(
                      future: _proinQuote(
                        appState,
                        salon.id,
                        pricingServiceIds,
                        discountFuture!,
                      ),
                      builder: (context, proinSnapshot) {
                        final proin = proinSnapshot.data;
                        final proinError = proinSnapshot.hasError
                            ? _bookingErrorText(proinSnapshot.error!)
                            : '';
                        final useProin =
                            _useProin &&
                            proinError.isEmpty &&
                            proin?.canUseProin == true;
                        return Column(
                          children: [
                            _DiscountQuoteCard(
                              originalAmount: service.price,
                              quote: discount,
                              loading: discountLoading,
                              proinQuote: proin,
                              useProin: useProin,
                            ),
                            const SizedBox(height: 10),
                            _ProinRedemptionCard(
                              wallet: wallet,
                              quote: proin,
                              loading: walletLoading,
                              quoteLoading:
                                  proinSnapshot.connectionState !=
                                  ConnectionState.done,
                              error: proinError,
                              selected: _useProin && proinError.isEmpty,
                              onChanged: canToggleProin ? _setUseProin : null,
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          if (!isRescheduling) ...[
            const SizedBox(height: 10),
            _buildCheckoutDiscountControls(
              context,
              appState,
              salon.id,
              pricingServiceIds,
            ),
          ],
          const SizedBox(height: 14),
          if (isInstantOnly) ...[
            _InstantBookingCard(
              enabled: canRequestInstant && !_priceSelectionPending,
              isLoading: _isInstantBooking,
              selectedArrivalMinutes: _instantArrivalMinutes,
              activeBooking: activeCustomerBooking,
              onArrivalMinutesChanged: (minutes) {
                setState(() => _instantArrivalMinutes = minutes);
              },
              onRequest: () => _startInstantBookingLogin(context),
            ),
          ] else ...[
            if (selectedBarber == null) ...[
              const SectionHeader(title: 'Choose barber'),
              const SizedBox(height: 10),
              _BarberChoiceList(
                barbers: eligibleBarbers,
                selectedBarberId: selectedBarberId,
                accent: accent,
                onSelected: (barberId) {
                  setState(() {
                    _selectedBarberId = barberId;
                    _selectedSlotKey = null;
                  });
                },
              ),
              const SizedBox(height: 22),
            ] else ...[
              GlassCard(
                color: accent.withAlpha(12),
                child: Row(
                  children: [
                    SoftIconBox(
                      icon: Icons.badge_outlined,
                      color: accent,
                      size: 42,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Booking with ${selectedBarber.name}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
            ],
            const SectionHeader(title: 'Available slots'),
            const SizedBox(height: 10),
            if (slots.isEmpty)
              EmptyState(
                icon: Icons.event_busy,
                title: 'No slots open',
                message: selectedBarberId == null
                    ? 'Try another service or check back later.'
                    : 'Try another barber or check back later.',
              )
            else
              _SlotGrid(
                slots: slots,
                selectedSlotKey: _selectedSlotKey,
                accent: accent,
                onDateChanged: () {
                  setState(() => _selectedSlotKey = null);
                },
                onSelected: (slot) {
                  setState(() {
                    _selectedSlotKey = slot.key;
                  });
                },
              ),
            const SizedBox(height: 12),
            GlassCard(
              color: accent.withAlpha(12),
              child: Row(
                children: [
                  SoftIconBox(
                    icon: Icons.lock_outline,
                    color: accent,
                    size: 42,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No booking fee today. The salon receives your appointment and contact details.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 74),
        ],
      ),
    );
  }

  Widget _buildCheckoutDiscountControls(
    BuildContext context,
    AppState appState,
    String salonId,
    List<String> serviceIds,
  ) {
    return Column(
      children: [
        if (appState.customerAccount != null)
          FutureBuilder<List<CheckoutDiscountOffer>>(
            future: _visibleDiscountOffers(appState, salonId, serviceIds),
            builder: (context, offerSnapshot) {
              if (offerSnapshot.connectionState != ConnectionState.done &&
                  !offerSnapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: _CheckoutOffersLoadingCard(),
                );
              }
              if (offerSnapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _CheckoutOfferLoadErrorCard(
                    message: friendlyErrorMessage(
                      offerSnapshot.error,
                      fallback: 'Offers could not be loaded. Try again.',
                    ),
                    onRetry: _retryVisibleDiscountOffers,
                  ),
                );
              }
              final offers =
                  offerSnapshot.data ?? const <CheckoutDiscountOffer>[];
              if (offers.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CheckoutVisibleOffersCard(
                  offers: offers,
                  applyingCampaignId: _applyingVisibleCampaignId,
                  appliedCampaignId: _appliedVisibleCampaignId,
                  onApply: (offer) => _applyVisibleCheckoutDiscount(
                    context,
                    salonId,
                    serviceIds,
                    offer,
                  ),
                ),
              );
            },
          ),
        _CheckoutCouponCard(
          controller: _couponController,
          applying: _isApplyingCoupon,
          applied: _couponApplied,
          message: _couponMessage,
          onApply: () => _applyCheckoutCoupon(context, salonId, serviceIds),
          onRemove: _removeCheckoutCoupon,
        ),
      ],
    );
  }

  Future<void> _startBookingLogin(BuildContext context, TimeSlot slot) async {
    if (_isBooking || _priceSelectionPending) {
      return;
    }
    final appState = AppStateScope.read(context);
    if (appState.hasActiveCustomerSession) {
      await _completeBooking(context, slot);
      return;
    }

    final didLogin = await _showCustomerLoginSheet(context);
    if (didLogin == true && context.mounted) {
      await _completeBooking(context, slot);
    }
  }

  Future<void> _completeBooking(BuildContext context, TimeSlot slot) async {
    if (_isBooking || _priceSelectionPending) {
      return;
    }
    setState(() => _isBooking = true);
    final appState = AppStateScope.read(context);
    late final Booking booking;
    try {
      if (widget.rescheduleBookingId == null) {
        final quote = await _discountQuote(appState, widget.salonId, [
          slot.serviceId,
        ]);
        var requestedProin = 0;
        if (_useProin) {
          final proinQuote = await _proinQuote(appState, widget.salonId, [
            slot.serviceId,
          ], Future.value(quote));
          requestedProin = proinQuote.maximumRedeemableProin;
        }
        booking = await appState.createBooking(
          slot: slot,
          quoteId: quote.quoteId,
          requestedProin: requestedProin,
        );
      } else {
        booking = await appState.rescheduleBooking(
          widget.rescheduleBookingId!,
          slot: slot,
        );
      }
    } catch (error) {
      _clearPricingQuotes();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Booking failed: ${_bookingErrorText(error)}')),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _isBooking = false);
      }
    }
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _BookingSuccessDialog(
          title: widget.rescheduleBookingId == null
              ? 'Booking confirmed'
              : 'Booking rescheduled',
          message: widget.rescheduleBookingId == null
              ? 'Your appointment is registered with the salon.'
              : 'Your new appointment time is registered with the salon.',
          salonName: salon?.name ?? 'Salon',
          serviceName: booking.resolvedServiceName(service),
          appointmentTime:
              '${appState.formatDate(booking.start)}, '
              '${appState.formatTime(booking.start)}',
          barberName: barber?.name ?? 'Assigned barber',
          onDone: () {
            Navigator.pop(dialogContext);
            if (widget.rescheduleBookingId != null && context.mounted) {
              Navigator.pop(context);
            }
          },
          onMyBookings: () {
            Navigator.pop(dialogContext);
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
            );
          },
        );
      },
    );
  }

  Future<void> _startInstantBookingLogin(BuildContext context) async {
    if (_isInstantBooking || _priceSelectionPending) {
      return;
    }
    final appState = AppStateScope.read(context);
    if (appState.hasActiveCustomerSession) {
      await _completeInstantBooking(context);
      return;
    }

    final didLogin = await _showCustomerLoginSheet(context);
    if (didLogin == true && context.mounted) {
      await _completeInstantBooking(context);
    }
  }

  Future<void> _completeInstantBooking(BuildContext context) async {
    if (_isInstantBooking || _priceSelectionPending) {
      return;
    }
    setState(() => _isInstantBooking = true);
    final appState = AppStateScope.read(context);
    late final Booking booking;
    try {
      final serviceIds = widget.initialInstantServiceIds.isEmpty
          ? [widget.serviceId]
          : widget.initialInstantServiceIds;
      final quote = await _discountQuote(appState, widget.salonId, serviceIds);
      var requestedProin = 0;
      if (_useProin) {
        final proinQuote = await _proinQuote(
          appState,
          widget.salonId,
          serviceIds,
          Future.value(quote),
        );
        requestedProin = proinQuote.maximumRedeemableProin;
      }
      booking = await appState.createInstantBooking(
        salonId: widget.salonId,
        serviceIds: serviceIds,
        arrivalMinutes: _instantArrivalMinutes,
        quoteId: quote.quoteId,
        requestedProin: requestedProin,
      );
    } catch (error) {
      _clearPricingQuotes();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Instant request failed: ${_bookingErrorText(error)}'),
        ),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _isInstantBooking = false);
      }
    }
    final salon = appState.getSalon(booking.salonId);
    final service = appState.getService(booking.salonId, booking.serviceId);
    final barber = appState.getBarber(booking.barberId);

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _BookingSuccessDialog(
          title: 'Instant request sent',
          message:
              'The salon has your request. Your reach-by time will be set when the salon accepts it.',
          salonName: salon?.name ?? 'Salon',
          serviceName: booking.resolvedServiceName(service),
          appointmentTime:
              '${booking.customerArrivalMinutes} min after salon acceptance',
          barberName: barber?.name ?? 'Any available barber',
          onDone: () => Navigator.pop(dialogContext),
          onMyBookings: () {
            Navigator.pop(dialogContext);
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
            );
          },
        );
      },
    );
  }

  void _clearPricingQuotes() {
    _discountQuoteFuture = null;
    _discountQuoteKey = '';
    _proinQuoteFuture = null;
    _proinQuoteKey = '';
    _proinWalletFuture = null;
    _proinWalletKey = '';
    _visibleDiscountOffersFuture = null;
    _visibleDiscountOffersKey = '';
    _useProin = false;
    _applyingVisibleCampaignId = '';
    _appliedVisibleCampaignId = '';
    _couponMessage = '';
    _couponApplied = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _applyCheckoutCoupon(
    BuildContext context,
    String salonId,
    Iterable<String> serviceIds,
  ) async {
    if (_isApplyingCoupon) return;
    final code = _couponController.text.trim().toUpperCase();
    if (!RegExp(r'^(?=.*[A-Z])[A-Z\d]{4,20}$').hasMatch(code)) {
      setState(() {
        _couponMessage =
            'Enter a 4-20 character voucher or coupon code with a letter.';
        _couponApplied = false;
      });
      return;
    }
    setState(() {
      _isApplyingCoupon = true;
      _couponMessage = '';
    });
    try {
      var appState = AppStateScope.read(context);
      if (!appState.hasActiveCustomerSession) {
        final didLogin = await _showCustomerLoginSheet(context);
        if (didLogin != true || !context.mounted) return;
        appState = AppStateScope.read(context);
      }
      final result = await appState.applyCheckoutCoupon(
        salonId: salonId,
        serviceIds: serviceIds,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        if (result.discountQuote != null) {
          _discountQuoteKey = _discountKey(appState, salonId, serviceIds);
          _discountQuoteFuture = Future.value(result.discountQuote!);
        }
        _appliedVisibleCampaignId = '';
        _proinQuoteKey = '';
        _proinQuoteFuture = null;
        _proinWalletKey = '';
        _proinWalletFuture = result.grantsProin
            ? Future.value(appState.customerProinWallet)
            : null;
        _useProin =
            result.grantsProin &&
            appState.customerProinWallet.availableProin > 0;
        _couponMessage = result.grantsProin && _useProin
            ? '${result.message} Proin is ready to use on this booking.'
            : result.message;
        _couponApplied = result.appliesDiscount || result.grantsProin;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _couponMessage = _bookingErrorText(error);
        _couponApplied = false;
      });
    } finally {
      if (mounted) setState(() => _isApplyingCoupon = false);
    }
  }

  Future<void> _applyVisibleCheckoutDiscount(
    BuildContext context,
    String salonId,
    Iterable<String> serviceIds,
    CheckoutDiscountOffer offer,
  ) async {
    if (_applyingVisibleCampaignId.isNotEmpty) return;
    final optimisticQuote = DiscountQuote(
      campaignId: offer.campaignId,
      campaignName: offer.campaignName,
      discountType: offer.discountType,
      discountPercent: offer.discountPercent,
      fixedDiscountAmount: offer.fixedDiscountAmount,
      voucherApplied: offer.voucherMaskedCode.isNotEmpty,
      voucherMaskedCode: offer.voucherMaskedCode,
      originalAmount: offer.originalAmount,
      discountBaseAmount: offer.originalAmount,
      discountAmount: offer.discountAmount,
      customerPayableAmount: offer.customerPayableAmount,
      campaignEndsAt: offer.campaignEndsAt,
    );
    setState(() {
      _applyingVisibleCampaignId = offer.campaignId;
      _discountQuoteKey = _discountKey(
        AppStateScope.read(context),
        salonId,
        serviceIds,
      );
      _discountQuoteFuture = Future.value(optimisticQuote);
      _appliedVisibleCampaignId = offer.campaignId;
      _couponMessage = 'Applying ${offer.campaignName}...';
      _couponApplied = true;
      _useProin = false;
      _proinQuoteKey = '';
      _proinQuoteFuture = null;
    });
    try {
      var appState = AppStateScope.read(context);
      if (!appState.hasActiveCustomerSession) {
        final didLogin = await _showCustomerLoginSheet(context);
        if (didLogin != true || !context.mounted) return;
        appState = AppStateScope.read(context);
      }
      final result = await appState.applyVisibleCheckoutDiscount(
        salonId: salonId,
        serviceIds: serviceIds,
        campaignId: offer.campaignId,
      );
      if (!mounted) return;
      setState(() {
        if (result.discountQuote != null) {
          _discountQuoteKey = _discountKey(appState, salonId, serviceIds);
          _discountQuoteFuture = Future.value(result.discountQuote!);
        }
        _couponController.clear();
        _proinQuoteKey = '';
        _proinQuoteFuture = null;
        _proinWalletKey = '';
        _proinWalletFuture = null;
        _useProin = false;
        _appliedVisibleCampaignId = offer.campaignId;
        _couponMessage = result.message;
        _couponApplied = result.appliesDiscount;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _discountQuoteFuture = null;
        _discountQuoteKey = '';
        _couponMessage = _bookingErrorText(error);
        _couponApplied = false;
        _appliedVisibleCampaignId = '';
      });
    } finally {
      if (mounted) setState(() => _applyingVisibleCampaignId = '');
    }
  }

  void _removeCheckoutCoupon() {
    _couponController.clear();
    _discountQuoteFuture = null;
    _discountQuoteKey = '';
    _proinQuoteFuture = null;
    _proinQuoteKey = '';
    _proinWalletFuture = null;
    _proinWalletKey = '';
    _useProin = false;
    _applyingVisibleCampaignId = '';
    _appliedVisibleCampaignId = '';
    _couponMessage = '';
    _couponApplied = false;
    setState(() {});
  }

  String _bookingErrorText(Object error) {
    if (error is FirebaseException && error.code == 'permission-denied') {
      return 'Please sign in again, then book this slot.';
    }
    final message = error.toString();
    final lowerMessage = message.toLowerCase();
    if (message.contains('sign in again')) {
      return 'Please sign in again, then book this slot.';
    }
    if (lowerMessage.contains('cancel or complete your current booking') ||
        lowerMessage.contains('active booking')) {
      return 'You already have an active booking.';
    }
    if (lowerMessage.contains('just booked')) {
      return 'This slot was just booked. Please choose another time.';
    }
    return friendlyErrorMessage(
      error,
      fallback: 'The booking could not be completed. Please try again.',
    );
  }

  Future<bool?> _showCustomerLoginSheet(BuildContext context) async {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(118),
      builder: (sheetContext) {
        void finishLogin() {
          if (sheetContext.mounted) {
            Navigator.pop(sheetContext, true);
          }
        }

        return _BookingLoginSheet(onLoggedIn: finishLogin);
      },
    );
  }
}

class _BookingLoginSheet extends StatelessWidget {
  final VoidCallback onLoggedIn;

  const _BookingLoginSheet({required this.onLoggedIn});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      key: const ValueKey('booking-login-sheet'),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 32,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, bottomInset + 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 52,
                    width: 52,
                    decoration: BoxDecoration(
                      color: AppColors.champagne,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.lock_person_outlined,
                      color: AppColors.primaryDark,
                      size: 27,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Complete your booking',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Sign in securely to finish your appointment.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8EA),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF0D6A5)),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      color: AppColors.primaryDark,
                      size: 24,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '₹0 booking fee',
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'No payment is taken now. Pay only the service price at the salon.',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AuthLoginPanel(
                role: UserRole.customer,
                embedded: true,
                phoneHelperText: 'We will send a secure one-time code.',
                onLoggedIn: onLoggedIn,
              ),
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shield_outlined, size: 17, color: AppColors.muted),
                  SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'Your details are used only to manage your booking',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingSuccessDialog extends StatelessWidget {
  final String title;
  final String message;
  final String salonName;
  final String serviceName;
  final String appointmentTime;
  final String barberName;
  final VoidCallback onDone;
  final VoidCallback onMyBookings;

  const _BookingSuccessDialog({
    this.title = 'Booking confirmed',
    this.message = 'Your appointment is registered with the salon.',
    required this.salonName,
    required this.serviceName,
    required this.appointmentTime,
    required this.barberName,
    required this.onDone,
    required this.onMyBookings,
  });

  Widget _buildDialog(BuildContext context) {
    final waitingTitle = title == 'Instant request sent'
        ? 'Waiting for the salon to accept'
        : 'Appointment registered';
    return Dialog(
      key: const ValueKey('booking-success-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Material(
            color: AppColors.surface,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFFFF4DC), Color(0xFFFFFCF7)],
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 5),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.success.withAlpha(52),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(height: 1.4),
                        ),
                        const SizedBox(height: 14),
                        const AppPill(
                          icon: Icons.currency_rupee,
                          label: '0 booking fee',
                          color: AppColors.primaryDark,
                          backgroundColor: Colors.white,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'BOOKING DETAILS',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFBFAF7),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Column(
                            children: [
                              _BookingSuccessDetailRow(
                                icon: Icons.storefront_outlined,
                                label: 'Salon',
                                value: salonName,
                              ),
                              const Divider(indent: 58),
                              _BookingSuccessDetailRow(
                                icon: Icons.spa_outlined,
                                label: 'Service',
                                value: serviceName,
                              ),
                              const Divider(indent: 58),
                              _BookingSuccessDetailRow(
                                icon: Icons.schedule_outlined,
                                label: 'Date & time',
                                value: appointmentTime,
                              ),
                              const Divider(indent: 58),
                              _BookingSuccessDetailRow(
                                icon: Icons.badge_outlined,
                                label: 'Professional',
                                value: barberName,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.champagne.withAlpha(116),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.hourglass_top_rounded,
                                  color: AppColors.primaryDark,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      waitingTitle,
                                      style: const TextStyle(
                                        color: AppColors.ink,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    const Text(
                                      'Track updates anytime in My bookings.',
                                      style: TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: onDone,
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Done'),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: onMyBookings,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text('View my bookings'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _buildDialog(context);
}

class _BookingSuccessDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _BookingSuccessDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.champagne.withAlpha(148),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.primaryDark, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SignInForOfferCard extends StatelessWidget {
  const _SignInForOfferCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.champagne.withAlpha(88),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withAlpha(32)),
      ),
      child: const Row(
        children: [
          Icon(Icons.local_offer_outlined, color: AppColors.primaryDark),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sign in to reveal your personal Pritze discount.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckoutOfferLoadErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _CheckoutOfferLoadErrorCard({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      color: AppColors.amber.withAlpha(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SoftIconBox(
            icon: Icons.local_offer_outlined,
            color: AppColors.amber,
            size: 38,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Offers could not be loaded',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry offers'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckoutOffersLoadingCard extends StatelessWidget {
  const _CheckoutOffersLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('checkout-discount-offers-loading'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withAlpha(44)),
      ),
      child: const Row(
        children: [
          SoftIconBox(
            icon: Icons.local_offer_outlined,
            color: AppColors.primary,
            size: 38,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Checking available discounts...',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }
}

class _CheckoutVisibleOffersCard extends StatelessWidget {
  final List<CheckoutDiscountOffer> offers;
  final String applyingCampaignId;
  final String appliedCampaignId;
  final ValueChanged<CheckoutDiscountOffer> onApply;

  const _CheckoutVisibleOffersCard({
    required this.offers,
    required this.applyingCampaignId,
    required this.appliedCampaignId,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final visibleOffers = offers.take(4).toList(growable: false);
    return Container(
      key: const ValueKey('checkout-visible-discount-offers'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFF4D8), Color(0xFFFFFBF2)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withAlpha(64)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.sell_outlined,
                color: AppColors.primary,
                size: 38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offers.length == 1
                          ? 'Available discount'
                          : 'Available discounts',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap one before booking to update your final price.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < visibleOffers.length; index++) ...[
            _CheckoutVisibleOfferTile(
              offer: visibleOffers[index],
              applying: applyingCampaignId == visibleOffers[index].campaignId,
              applied: appliedCampaignId == visibleOffers[index].campaignId,
              disabled:
                  applyingCampaignId.isNotEmpty ||
                  (appliedCampaignId.isNotEmpty &&
                      appliedCampaignId != visibleOffers[index].campaignId),
              onApply: () => onApply(visibleOffers[index]),
            ),
            if (index < visibleOffers.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _CheckoutVisibleOfferTile extends StatelessWidget {
  final CheckoutDiscountOffer offer;
  final bool applying;
  final bool applied;
  final bool disabled;
  final VoidCallback onApply;

  const _CheckoutVisibleOfferTile({
    required this.offer,
    required this.applying,
    required this.applied,
    required this.disabled,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final canTap = !disabled && !applying && !applied;
    return Material(
      color: Colors.white.withAlpha(220),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: canTap ? onApply : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: applied
                  ? AppColors.success.withAlpha(90)
                  : AppColors.gold.withAlpha(70),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(18),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  offer.offerLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer.campaignName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Save ₹${offer.discountAmount} · Pay ₹${offer.customerPayableAmount}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: canTap ? onApply : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(74, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: applying
                    ? const SizedBox(
                        height: 17,
                        width: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(applied ? 'Applied' : 'Apply'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckoutCouponCard extends StatelessWidget {
  final TextEditingController controller;
  final bool applying;
  final bool applied;
  final String message;
  final VoidCallback onApply;
  final VoidCallback onRemove;

  const _CheckoutCouponCard({
    required this.controller,
    required this.applying,
    required this.applied,
    required this.message,
    required this.onApply,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('checkout-coupon-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF4),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: applied
              ? AppColors.success.withAlpha(90)
              : AppColors.primary.withAlpha(48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SoftIconBox(
                icon: Icons.confirmation_number_outlined,
                color: AppColors.primary,
                size: 40,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Have a coupon code?',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Enter a code you received from Pritze.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('checkout-coupon-input'),
                  controller: controller,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 20,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    TextInputFormatter.withFunction((oldValue, newValue) {
                      return newValue.copyWith(
                        text: newValue.text.toUpperCase(),
                        selection: TextSelection.collapsed(
                          offset: newValue.text.length,
                        ),
                      );
                    }),
                  ],
                  decoration: const InputDecoration(
                    hintText: 'Coupon code',
                    counterText: '',
                    prefixIcon: Icon(Icons.local_offer_outlined),
                  ),
                  onSubmitted: (_) {
                    if (!applying) onApply();
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const ValueKey('checkout-coupon-apply'),
                onPressed: applying ? null : onApply,
                child: applying
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(applied ? 'Applied' : 'Apply'),
              ),
            ],
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  applied ? Icons.check_circle_outline : Icons.info_outline,
                  size: 18,
                  color: applied ? AppColors.success : AppColors.primaryDark,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: applied
                          ? AppColors.success
                          : AppColors.primaryDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (applied)
                  TextButton(onPressed: onRemove, child: const Text('Remove')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DiscountQuoteCard extends StatelessWidget {
  final int originalAmount;
  final DiscountQuote? quote;
  final bool loading;
  final ProinBookingQuote? proinQuote;
  final bool useProin;

  const _DiscountQuoteCard({
    required this.originalAmount,
    required this.quote,
    required this.loading,
    this.proinQuote,
    this.useProin = false,
  });

  @override
  Widget build(BuildContext context) {
    final value = quote ?? DiscountQuote(originalAmount: originalAmount);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: value.hasDiscount
            ? const LinearGradient(
                colors: [Color(0xFFFFF4D8), Color(0xFFFFFBF2)],
              )
            : null,
        color: value.hasDiscount ? null : const Color(0xFFF8F6F1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: value.hasDiscount
              ? AppColors.primary.withAlpha(64)
              : AppColors.line,
        ),
      ),
      child: Column(
        children: [
          _PriceLine(label: 'Service amount', value: value.originalAmount),
          if (value.hasDiscount) ...[
            const SizedBox(height: 8),
            _PriceLine(
              label: '${value.campaignName} discount',
              value: -value.discountAmount,
              color: AppColors.success,
            ),
            if (value.quoteId.isNotEmpty) ...[
              const SizedBox(height: 7),
              const Row(
                children: [
                  Icon(Icons.lock_clock_outlined, size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'This price is locked for 10 minutes.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            if (value.campaignEndsAt != null) ...[
              const SizedBox(height: 7),
              Row(
                children: [
                  const Icon(Icons.event_available_outlined, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Offer valid until ${_discountExpiryLabel(value.campaignEndsAt!)}.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
          if (useProin && proinQuote?.canUseProin == true) ...[
            const SizedBox(height: 8),
            _PriceLine(
              label: 'Proin used',
              value: -proinQuote!.maximumRedeemableProin,
              color: AppColors.success,
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _PriceLine(
            label: 'Pay at salon counter',
            value: useProin && proinQuote != null
                ? proinQuote!.customerPayableAmount
                : value.customerPayableAmount,
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

class _ProinRedemptionCard extends StatelessWidget {
  final ProinWalletSummary wallet;
  final ProinBookingQuote? quote;
  final bool loading;
  final bool quoteLoading;
  final String error;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  const _ProinRedemptionCard({
    required this.wallet,
    required this.quote,
    required this.loading,
    required this.quoteLoading,
    required this.error,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final available = quote?.availableProin ?? wallet.availableProin;
    final redeemable = quote?.maximumRedeemableProin ?? 0;
    final canUse =
        onChanged != null && !loading && !quoteLoading && error.isEmpty;
    final isSelected = selected && error.isEmpty;
    final subtitle = loading
        ? 'Available Proin: $available · updating'
        : error.isNotEmpty
        ? error
        : quoteLoading && isSelected
        ? 'Available $available · calculating deduction'
        : isSelected && redeemable > 0
        ? 'Available $available · ₹$redeemable will be deducted'
        : 'Available Proin: $available';
    return Container(
      key: const ValueKey('booking-proin-redemption'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8EE),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withAlpha(85)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: canUse ? () => onChanged?.call(!isSelected) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SoftIconBox(
                icon: Icons.toll_rounded,
                color: AppColors.primary,
                size: 38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Use Proin for booking',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: error.isNotEmpty ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: error.isNotEmpty
                            ? AppColors.coral
                            : AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Checkbox.adaptive(
                key: const ValueKey('booking-use-proin-switch'),
                value: isSelected,
                onChanged: canUse
                    ? (value) => onChanged?.call(value ?? false)
                    : null,
                activeColor: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PricingErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PricingErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.primaryDark),
          const SizedBox(width: 10),
          Expanded(child: Text('Price could not be refreshed. $message')),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

String _discountExpiryLabel(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${value.day.toString().padLeft(2, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/${value.year} '
      '$hour:$minute $period';
}

class _PriceLine extends StatelessWidget {
  final String label;
  final int value;
  final Color? color;
  final bool emphasized;

  const _PriceLine({
    required this.label,
    required this.value,
    this.color,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final amount = value < 0 ? '-₹${value.abs()}' : '₹$value';
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color ?? AppColors.ink,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          amount,
          style: TextStyle(
            color: color ?? AppColors.ink,
            fontSize: emphasized ? 18 : 14,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _BookingSummary extends StatelessWidget {
  final Salon salon;
  final SalonService service;
  final int barberCount;
  final Color accent;
  final bool showBookingFee;

  const _BookingSummary({
    required this.salon,
    required this.service,
    required this.barberCount,
    required this.accent,
    required this.showBookingFee,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 5,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SalonLogo(logoUrl: salon.logoUrl, color: accent, size: 52),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            salon.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            service.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineMedium,
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
                      icon: Icons.schedule,
                      label: '${service.durationMinutes} min',
                      color: accent,
                    ),
                    AppPill(
                      icon: Icons.badge_outlined,
                      label:
                          '$barberCount ${barberCount == 1 ? 'barber' : 'barbers'}',
                      color: AppColors.primary,
                    ),
                    if (showBookingFee)
                      AppPill(
                        icon: Icons.currency_rupee,
                        label: '0 booking fee',
                        color: AppColors.goldDeep,
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

class _InstantBookingCard extends StatelessWidget {
  final bool enabled;
  final bool isLoading;
  final int selectedArrivalMinutes;
  final Booking? activeBooking;
  final ValueChanged<int> onArrivalMinutesChanged;
  final VoidCallback onRequest;

  const _InstantBookingCard({
    required this.enabled,
    required this.isLoading,
    required this.selectedArrivalMinutes,
    required this.activeBooking,
    required this.onArrivalMinutesChanged,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    if (activeBooking != null) {
      return const SizedBox.shrink(
        key: ValueKey('active-instant-booking-block'),
      );
    }

    return GlassCard(
      color: AppColors.champagne.withAlpha(112),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SoftIconBox(
            icon: Icons.bolt_outlined,
            color: AppColors.primary,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Instant booking',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose how soon you can reach after the salon accepts.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.ink),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    key: const ValueKey('instant-arrival-selector'),
                    showSelectedIcon: false,
                    segments: [
                      for (final minutes in instantArrivalMinuteOptions)
                        ButtonSegment<int>(
                          value: minutes,
                          label: Text('$minutes min'),
                        ),
                    ],
                    selected: {selectedArrivalMinutes},
                    onSelectionChanged: isLoading
                        ? null
                        : (selection) =>
                              onArrivalMinutesChanged(selection.first),
                  ),
                ),
                if (!enabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Instant booking is unavailable for this service right now.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.coral,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: enabled && !isLoading ? onRequest : null,
                    icon: isLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.flash_on_outlined),
                    label: Text(
                      isLoading ? 'Sending...' : 'Request instant booking',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarberChoiceList extends StatelessWidget {
  final List<Barber> barbers;
  final String? selectedBarberId;
  final Color accent;
  final ValueChanged<String?> onSelected;

  const _BarberChoiceList({
    required this.barbers,
    required this.selectedBarberId,
    required this.accent,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (barbers.isEmpty) {
      return const EmptyState(
        icon: Icons.badge,
        title: 'No barbers available',
        message: 'This service does not have an assigned barber yet.',
      );
    }

    final cardHeight = MediaQuery.textScalerOf(
      context,
    ).scale(118).clamp(118.0, 148.0);

    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: barbers.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BarberChoiceCard(
              title: 'Any available',
              subtitle:
                  '${barbers.length} ${barbers.length == 1 ? 'barber' : 'barbers'}',
              initial: 'A',
              selected: selectedBarberId == null,
              accent: accent,
              onTap: () => onSelected(null),
            );
          }

          final barber = barbers[index - 1];
          return _BarberChoiceCard(
            title: barber.name,
            subtitle: barber.speciality,
            initial: barber.name.characters.first,
            selected: selectedBarberId == barber.id,
            accent: accent,
            onTap: () => onSelected(barber.id),
          );
        },
      ),
    );
  }
}

class _BarberChoiceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String initial;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _BarberChoiceCard({
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 164,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accent : AppColors.line,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F0F172A),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: selected ? accent : accent.withAlpha(16),
                  foregroundColor: selected ? Colors.white : accent,
                  child: Text(
                    initial,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                Icon(
                  selected ? Icons.check_circle : Icons.add_circle_outline,
                  color: accent,
                  size: 19,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotGrid extends StatefulWidget {
  final List<TimeSlot> slots;
  final String? selectedSlotKey;
  final Color accent;
  final VoidCallback onDateChanged;
  final ValueChanged<TimeSlot> onSelected;

  const _SlotGrid({
    required this.slots,
    required this.selectedSlotKey,
    required this.accent,
    required this.onDateChanged,
    required this.onSelected,
  });

  @override
  State<_SlotGrid> createState() => _SlotGridState();
}

class _SlotGridState extends State<_SlotGrid> {
  late DateTime _selectedDate = _initialSelectedDate();

  @override
  void didUpdateWidget(covariant _SlotGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedSlot = _selectedSlot(widget.slots, widget.selectedSlotKey);
    if (selectedSlot != null) {
      _selectedDate = _dateOnly(selectedSlot.start);
      return;
    }
    if (!_bookingDates().contains(_selectedDate)) {
      _selectedDate = _initialSelectedDate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final dates = _bookingDates();
    final slotsForDate = widget.slots
        .where((slot) => _dateOnly(slot.start) == _selectedDate)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          key: const ValueKey('booking-date-selector'),
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: dates.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final date = dates[index];
              final availableCount = widget.slots
                  .where((slot) => _dateOnly(slot.start) == date)
                  .length;
              return ChoiceChip(
                key: ValueKey('booking-date-${_dateKey(date)}'),
                selected: date == _selectedDate,
                onSelected: (_) {
                  if (date == _selectedDate) return;
                  setState(() => _selectedDate = date);
                  widget.onDateChanged();
                },
                avatar: Icon(
                  availableCount == 0
                      ? Icons.event_busy_outlined
                      : Icons.event_available_outlined,
                  size: 17,
                ),
                label: Text(
                  '${_weekdayLabel(date)} · ${appState.formatDate(date)}',
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Available times for ${appState.formatDate(_selectedDate)}',
          key: const ValueKey('selected-booking-date-label'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 10),
        if (slotsForDate.isEmpty)
          const EmptyState(
            icon: Icons.event_busy_outlined,
            title: 'No times available',
            message: 'Choose another date from the 30-day calendar.',
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: slotsForDate.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.45,
            ),
            itemBuilder: (context, index) {
              final slot = slotsForDate[index];
              return _SlotCard(
                slot: slot,
                selected: slot.key == widget.selectedSlotKey,
                accent: widget.accent,
                onTap: () => widget.onSelected(slot),
              );
            },
          ),
        const SizedBox(height: 18),
      ],
    );
  }

  DateTime _initialSelectedDate() {
    final selectedSlot = _selectedSlot(widget.slots, widget.selectedSlotKey);
    if (selectedSlot != null) {
      return _dateOnly(selectedSlot.start);
    }
    return widget.slots.isEmpty
        ? _dateOnly(DateTime.now())
        : _dateOnly(widget.slots.first.start);
  }

  List<DateTime> _bookingDates() {
    final today = _dateOnly(DateTime.now());
    return List<DateTime>.generate(
      scheduledBookingHorizonDays,
      (index) => today.add(Duration(days: index)),
      growable: false,
    );
  }

  TimeSlot? _selectedSlot(List<TimeSlot> slots, String? key) {
    if (key == null) return null;
    return slots.where((slot) => slot.key == key).firstOrNull;
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _weekdayLabel(DateTime date) => const <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ][date.weekday - 1];
}

class _SlotCard extends StatelessWidget {
  final TimeSlot slot;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _SlotCard({
    required this.slot,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final barber = appState.getBarber(slot.barberId);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent.withAlpha(16) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accent : AppColors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.schedule,
              color: accent,
              size: 22,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    appState.formatTime(slot.start),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    barber?.name ?? 'Any barber',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
