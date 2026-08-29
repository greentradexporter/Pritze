enum BookingStatus {
  pending,
  confirmed,
  inProgress,
  completed,
  cancelled,
  rejected,
}

enum CustomerArrivalStatus {
  notStarted,
  leavingNow,
  onTheWay,
  runningLate,
  arrived,
}

extension CustomerArrivalStatusLabel on CustomerArrivalStatus {
  String get label => switch (this) {
    CustomerArrivalStatus.notStarted => 'Not started',
    CustomerArrivalStatus.leavingNow => 'Leaving now',
    CustomerArrivalStatus.onTheWay => 'On the way',
    CustomerArrivalStatus.runningLate => 'Running late',
    CustomerArrivalStatus.arrived => 'Arrived',
  };
}

enum BarberBookingBucket { upcoming, active, history, cancelled }

enum SalonBookingBucket { requests, upcoming, active, history, cancelled }

enum CustomerBookingBucket { active, history, cancelled }

enum AppNotificationDestination { bookings, overview, team }

class AppNotificationNavigation {
  final AppNotificationDestination destination;
  final String bookingId;

  const AppNotificationNavigation({
    required this.destination,
    this.bookingId = '',
  });
}

extension BookingStatusLabel on BookingStatus {
  String get label {
    switch (this) {
      case BookingStatus.pending:
        return 'Pending';
      case BookingStatus.confirmed:
        return 'Confirmed';
      case BookingStatus.inProgress:
        return 'In progress';
      case BookingStatus.completed:
        return 'Completed';
      case BookingStatus.cancelled:
        return 'Cancelled';
      case BookingStatus.rejected:
        return 'Rejected';
    }
  }
}

enum JoinRequestStatus { pending, approved, rejected, withdrawn }

extension JoinRequestStatusLabel on JoinRequestStatus {
  String get label {
    switch (this) {
      case JoinRequestStatus.pending:
        return 'Pending';
      case JoinRequestStatus.approved:
        return 'Approved';
      case JoinRequestStatus.rejected:
        return 'Rejected';
      case JoinRequestStatus.withdrawn:
        return 'Withdrawn';
    }
  }
}

enum UserRole { customer, owner, barber }

extension UserRoleLabel on UserRole {
  String get label {
    switch (this) {
      case UserRole.customer:
        return 'Customer';
      case UserRole.owner:
        return 'Owner';
      case UserRole.barber:
        return 'Barber';
    }
  }
}

enum LoginProvider { email, google, phone }

class ReferralCodes {
  final String customerInviteCode;
  final String salonInviteCode;

  const ReferralCodes({
    required this.customerInviteCode,
    this.salonInviteCode = '',
  });
}

class ReferralSummary {
  final int pendingCustomerCount;
  final int qualifiedCustomerCount;
  final int pendingSalonCount;
  final int qualifiedSalonCount;
  final int customerInviterRewardProin;
  final int customerReferredRewardProin;
  final int salonInviterRewardProin;
  final int salonReferredRewardProin;
  final int earnedCustomerReferralProin;
  final int earnedSalonReferralProin;
  final int earnedReferralProin;

  const ReferralSummary({
    this.pendingCustomerCount = 0,
    this.qualifiedCustomerCount = 0,
    this.pendingSalonCount = 0,
    this.qualifiedSalonCount = 0,
    this.customerInviterRewardProin = 0,
    this.customerReferredRewardProin = 0,
    this.salonInviterRewardProin = 0,
    this.salonReferredRewardProin = 0,
    this.earnedCustomerReferralProin = 0,
    this.earnedSalonReferralProin = 0,
    this.earnedReferralProin = 0,
  });
}

class DiscountQuote {
  final String quoteId;
  final String campaignId;
  final String campaignName;
  final String discountType;
  final double discountPercent;
  final int fixedDiscountAmount;
  final bool voucherApplied;
  final String voucherMaskedCode;
  final int originalAmount;
  final int discountBaseAmount;
  final int discountAmount;
  final int customerPayableAmount;
  final int pritzePayoutAmount;
  final int salonTotalEarning;
  final DateTime? expiresAt;
  final DateTime? campaignEndsAt;

  const DiscountQuote({
    this.quoteId = '',
    this.campaignId = '',
    this.campaignName = '',
    this.discountType = 'percent',
    this.discountPercent = 0,
    this.fixedDiscountAmount = 0,
    this.voucherApplied = false,
    this.voucherMaskedCode = '',
    required this.originalAmount,
    this.discountBaseAmount = 0,
    this.discountAmount = 0,
    int? customerPayableAmount,
    this.pritzePayoutAmount = 0,
    int? salonTotalEarning,
    this.expiresAt,
    this.campaignEndsAt,
  }) : customerPayableAmount = customerPayableAmount ?? originalAmount,
       salonTotalEarning = salonTotalEarning ?? originalAmount;

  bool get hasDiscount => discountAmount > 0 && campaignId.isNotEmpty;
}

class CheckoutCouponResult {
  final String benefitType;
  final String message;
  final int amountProin;
  final bool alreadyClaimed;
  final DiscountQuote? discountQuote;

  const CheckoutCouponResult({
    required this.benefitType,
    required this.message,
    this.amountProin = 0,
    this.alreadyClaimed = false,
    this.discountQuote,
  });

  bool get grantsProin => benefitType == 'proin';
  bool get appliesDiscount => discountQuote?.hasDiscount == true;
}

class CheckoutDiscountOffer {
  final String campaignId;
  final String campaignName;
  final String discountType;
  final double discountPercent;
  final int fixedDiscountAmount;
  final String voucherMaskedCode;
  final int originalAmount;
  final int discountAmount;
  final int customerPayableAmount;
  final DateTime? campaignEndsAt;

  const CheckoutDiscountOffer({
    required this.campaignId,
    required this.campaignName,
    required this.discountType,
    required this.discountPercent,
    required this.fixedDiscountAmount,
    required this.voucherMaskedCode,
    required this.originalAmount,
    required this.discountAmount,
    required this.customerPayableAmount,
    this.campaignEndsAt,
  });

  bool get hasSaving => discountAmount > 0 && campaignId.isNotEmpty;

  String get offerLabel {
    if (discountType == 'fixed') return '₹$fixedDiscountAmount off';
    final percent = discountPercent % 1 == 0
        ? discountPercent.toInt().toString()
        : discountPercent.toStringAsFixed(2);
    return '$percent% off';
  }
}

class ProinWalletSummary {
  final int availableProin;
  final int reservedProin;
  final int creditLimitProin;
  final int spendableProin;
  final int lifetimeGrantedProin;
  final int lifetimeRedeemedProin;
  final int lifetimeExpiredProin;
  final DateTime? nextExpiryAt;
  final List<ProinExpiringLot> expiringLots;

  const ProinWalletSummary({
    this.availableProin = 0,
    this.reservedProin = 0,
    this.creditLimitProin = 0,
    this.spendableProin = 0,
    this.lifetimeGrantedProin = 0,
    this.lifetimeRedeemedProin = 0,
    this.lifetimeExpiredProin = 0,
    this.nextExpiryAt,
    this.expiringLots = const [],
  });

  int get effectiveSpendableProin {
    if (spendableProin > 0) return spendableProin;
    final computed = availableProin + creditLimitProin;
    return computed < 0 ? 0 : computed;
  }

  bool get hasCreditLine => creditLimitProin > 0;

  bool get isUsingCreditLine => availableProin < 0;

  int get creditLineUsedProin => isUsingCreditLine ? -availableProin : 0;
}

class ProinExpiringLot {
  final String lotId;
  final int amountProin;
  final DateTime expiresAt;
  final String sourceType;

  const ProinExpiringLot({
    this.lotId = '',
    required this.amountProin,
    required this.expiresAt,
    this.sourceType = '',
  });
}

class ProinBookingQuote {
  final int availableProin;
  final int maximumRedeemableProin;
  final int payableBeforeProin;
  final int customerPayableAmount;

  const ProinBookingQuote({
    this.availableProin = 0,
    this.maximumRedeemableProin = 0,
    required this.payableBeforeProin,
    required this.customerPayableAmount,
  });

  bool get canUseProin => maximumRedeemableProin > 0;
}

class ProinCouponClaimResult {
  final int amountProin;
  final int availableProin;
  final DateTime? expiresAt;
  final bool alreadyClaimed;

  const ProinCouponClaimResult({
    required this.amountProin,
    required this.availableProin,
    this.expiresAt,
    this.alreadyClaimed = false,
  });
}

class ProinActivityEntry {
  final String transactionId;
  final String type;
  final String direction;
  final int amountProin;
  final int restoredProin;
  final int expiredProin;
  final String sourceType;
  final String bookingId;
  final DateTime createdAt;

  const ProinActivityEntry({
    required this.transactionId,
    required this.type,
    required this.direction,
    required this.amountProin,
    this.restoredProin = 0,
    this.expiredProin = 0,
    this.sourceType = '',
    this.bookingId = '',
    required this.createdAt,
  });
}

extension LoginProviderLabel on LoginProvider {
  String get label {
    switch (this) {
      case LoginProvider.email:
        return 'Email';
      case LoginProvider.phone:
        return 'Phone';
      case LoginProvider.google:
        return 'Google';
    }
  }
}

class UserAccount {
  final String id;
  final String name;
  final String contact;
  final LoginProvider provider;
  final String photoUrl;
  final String gender;
  final String birthDate;
  final List<String> preferredStyles;
  final List<String> stylePhotoUrls;
  final double salonRating;
  final int salonRatingCount;

  const UserAccount({
    required this.id,
    required this.name,
    required this.contact,
    required this.provider,
    this.photoUrl = '',
    this.gender = '',
    this.birthDate = '',
    this.preferredStyles = const [],
    this.stylePhotoUrls = const [],
    this.salonRating = 0,
    this.salonRatingCount = 0,
  });

  UserAccount copyWith({
    String? id,
    String? name,
    String? contact,
    LoginProvider? provider,
    String? photoUrl,
    String? gender,
    String? birthDate,
    List<String>? preferredStyles,
    List<String>? stylePhotoUrls,
    double? salonRating,
    int? salonRatingCount,
  }) {
    return UserAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      contact: contact ?? this.contact,
      provider: provider ?? this.provider,
      photoUrl: photoUrl ?? this.photoUrl,
      gender: gender ?? this.gender,
      birthDate: birthDate ?? this.birthDate,
      preferredStyles: preferredStyles ?? this.preferredStyles,
      stylePhotoUrls: stylePhotoUrls ?? this.stylePhotoUrls,
      salonRating: salonRating ?? this.salonRating,
      salonRatingCount: salonRatingCount ?? this.salonRatingCount,
    );
  }
}

class SalonFeedback {
  final String bookingId;
  final String customerUid;
  final String salonId;
  final String salonName;
  final int rating;
  final String note;
  final DateTime createdAt;

  const SalonFeedback({
    required this.bookingId,
    required this.customerUid,
    required this.salonId,
    required this.salonName,
    required this.rating,
    required this.note,
    required this.createdAt,
  });
}

class CustomerSalonRating {
  final String bookingId;
  final String customerUid;
  final String salonId;
  final String salonName;
  final int rating;
  final String note;
  final DateTime createdAt;

  const CustomerSalonRating({
    required this.bookingId,
    required this.customerUid,
    required this.salonId,
    required this.salonName,
    required this.rating,
    required this.note,
    required this.createdAt,
  });
}

class SalonService {
  final String id;
  final String name;
  final String category;
  final int price;
  final int durationMinutes;
  final bool isAvailable;
  final bool instantBookingEnabled;
  final bool isCustom;

  const SalonService({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.durationMinutes,
    this.isAvailable = true,
    this.instantBookingEnabled = true,
    this.isCustom = false,
  });

  SalonService copyWith({
    String? id,
    String? name,
    String? category,
    int? price,
    int? durationMinutes,
    bool? isAvailable,
    bool? instantBookingEnabled,
    bool? isCustom,
  }) {
    return SalonService(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      price: price ?? this.price,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      isAvailable: isAvailable ?? this.isAvailable,
      instantBookingEnabled:
          instantBookingEnabled ?? this.instantBookingEnabled,
      isCustom: isCustom ?? this.isCustom,
    );
  }
}

class Salon {
  final String id;
  final String name;
  final String ownerName;
  final String address;
  final String directionsUrl;
  final String phone;
  final String email;
  final String logoUrl;
  final List<String> photoUrls;
  final String distanceLabel;
  final double rating;
  final int reviewCount;
  final String openTime;
  final String closeTime;
  final bool isOpen;
  final bool instantBookingsEnabled;
  final String? instantBookingsPausedDate;
  final List<SalonService> services;

  const Salon({
    required this.id,
    required this.name,
    required this.ownerName,
    required this.address,
    this.directionsUrl = '',
    required this.phone,
    this.email = '',
    required this.logoUrl,
    this.photoUrls = const [],
    required this.distanceLabel,
    required this.rating,
    required this.reviewCount,
    required this.openTime,
    required this.closeTime,
    required this.isOpen,
    this.instantBookingsEnabled = true,
    this.instantBookingsPausedDate,
    required this.services,
  });

  Salon copyWith({
    String? id,
    String? name,
    String? ownerName,
    String? address,
    String? directionsUrl,
    String? phone,
    String? email,
    String? logoUrl,
    List<String>? photoUrls,
    String? distanceLabel,
    double? rating,
    int? reviewCount,
    String? openTime,
    String? closeTime,
    bool? isOpen,
    bool? instantBookingsEnabled,
    String? instantBookingsPausedDate,
    List<SalonService>? services,
  }) {
    return Salon(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerName: ownerName ?? this.ownerName,
      address: address ?? this.address,
      directionsUrl: directionsUrl ?? this.directionsUrl,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      logoUrl: logoUrl ?? this.logoUrl,
      photoUrls: photoUrls ?? this.photoUrls,
      distanceLabel: distanceLabel ?? this.distanceLabel,
      rating: rating ?? this.rating,
      reviewCount: reviewCount ?? this.reviewCount,
      openTime: openTime ?? this.openTime,
      closeTime: closeTime ?? this.closeTime,
      isOpen: isOpen ?? this.isOpen,
      instantBookingsEnabled:
          instantBookingsEnabled ?? this.instantBookingsEnabled,
      instantBookingsPausedDate:
          instantBookingsPausedDate ?? this.instantBookingsPausedDate,
      services: services ?? this.services,
    );
  }

  String get coverImageUrl {
    if (photoUrls.isNotEmpty) {
      return photoUrls.first;
    }
    return logoUrl;
  }

  String get displayName {
    final value = name.trim();
    return value.isEmpty ? 'Salon listing' : value;
  }

  List<SalonService> get availableServices =>
      services.where((service) => service.isAvailable).toList(growable: false);
}

class Barber {
  final String id;
  final String? uid;
  final String salonId;
  final String name;
  final String phone;
  final String email;
  final String speciality;
  final int experienceYears;
  final String resumeSummary;
  final List<String> serviceIds;
  final bool isActive;

  const Barber({
    required this.id,
    this.uid,
    required this.salonId,
    required this.name,
    required this.phone,
    this.email = '',
    required this.speciality,
    this.experienceYears = 1,
    this.resumeSummary = 'Customer-first grooming professional.',
    required this.serviceIds,
    this.isActive = true,
  });

  Barber copyWith({
    String? id,
    String? uid,
    String? salonId,
    String? name,
    String? phone,
    String? email,
    String? speciality,
    int? experienceYears,
    String? resumeSummary,
    List<String>? serviceIds,
    bool? isActive,
  }) {
    return Barber(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      salonId: salonId ?? this.salonId,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      speciality: speciality ?? this.speciality,
      experienceYears: experienceYears ?? this.experienceYears,
      resumeSummary: resumeSummary ?? this.resumeSummary,
      serviceIds: serviceIds ?? this.serviceIds,
      isActive: isActive ?? this.isActive,
    );
  }
}

class TimeSlot {
  final String salonId;
  final String serviceId;
  final String barberId;
  final DateTime start;

  const TimeSlot({
    required this.salonId,
    required this.serviceId,
    required this.barberId,
    required this.start,
  });

  String get key => '$barberId-${start.toIso8601String()}';
}

class Booking {
  final String id;
  final String? customerUid;
  final String salonId;
  final String serviceId;
  final List<String> serviceIds;
  final String barberId;
  final String customerName;
  final String customerPhone;
  final DateTime start;
  final int durationMinutes;
  final String serviceName;
  final int servicePrice;
  final Map<String, int> servicePriceBreakdown;
  final int bookingFee;
  final bool paymentRequired;
  final String paymentStatus;
  final String discountCampaignId;
  final String discountCampaignName;
  final double discountPercent;
  final int discountBaseAmount;
  final int discountAmount;
  final int customerPayableBeforeProin;
  final int customerPayableAmount;
  final int pritzePayoutAmount;
  final int salonTotalEarning;
  final String discountStatus;
  final String proinStatus;
  final int proinRequestedAmount;
  final int proinReservedAmount;
  final int proinRedeemedAmount;
  final int proinReleasedAmount;
  final int proinExpiredOnReleaseAmount;
  final String proinReimbursementStatus;
  final BookingStatus status;
  final DateTime createdAt;
  final bool isInstant;
  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final DateTime? rejectedAt;
  final DateTime? customerArrivalReminderSentAt;
  final DateTime? ownerArrivalReminderSentAt;
  final int arrivalMinutes;
  final String cancellationReason;
  final String cancelledBy;
  final CustomerArrivalStatus arrivalStatus;
  final DateTime? arrivalStatusUpdatedAt;
  final bool arrivalSharingActive;
  final DateTime? arrivalSharingExpiresAt;

  const Booking({
    required this.id,
    this.customerUid,
    required this.salonId,
    required this.serviceId,
    this.serviceIds = const [],
    required this.barberId,
    required this.customerName,
    required this.customerPhone,
    required this.start,
    this.durationMinutes = 30,
    this.serviceName = '',
    this.servicePrice = 0,
    this.servicePriceBreakdown = const {},
    this.bookingFee = 0,
    this.paymentRequired = false,
    this.paymentStatus = 'not_required',
    this.discountCampaignId = '',
    this.discountCampaignName = '',
    this.discountPercent = 0,
    this.discountBaseAmount = 0,
    this.discountAmount = 0,
    int? customerPayableBeforeProin,
    int? customerPayableAmount,
    this.pritzePayoutAmount = 0,
    int? salonTotalEarning,
    this.discountStatus = 'none',
    this.proinStatus = 'none',
    this.proinRequestedAmount = 0,
    this.proinReservedAmount = 0,
    this.proinRedeemedAmount = 0,
    this.proinReleasedAmount = 0,
    this.proinExpiredOnReleaseAmount = 0,
    this.proinReimbursementStatus = 'none',
    required this.status,
    required this.createdAt,
    this.isInstant = false,
    this.acceptedAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.rejectedAt,
    this.customerArrivalReminderSentAt,
    this.ownerArrivalReminderSentAt,
    this.arrivalMinutes = 0,
    this.cancellationReason = '',
    this.cancelledBy = '',
    this.arrivalStatus = CustomerArrivalStatus.notStarted,
    this.arrivalStatusUpdatedAt,
    this.arrivalSharingActive = false,
    this.arrivalSharingExpiresAt,
  }) : customerPayableBeforeProin =
           customerPayableBeforeProin ?? customerPayableAmount ?? servicePrice,
       customerPayableAmount = customerPayableAmount ?? servicePrice,
       salonTotalEarning = salonTotalEarning ?? servicePrice;

  bool get hasDiscount => discountAmount > 0 && discountCampaignId.isNotEmpty;

  bool get hasProin =>
      proinRequestedAmount > 0 ||
      proinReservedAmount > 0 ||
      proinRedeemedAmount > 0;

  int get proinAppliedAmount =>
      proinRedeemedAmount > 0 ? proinRedeemedAmount : proinReservedAmount;

  int get totalPritzeContribution => pritzePayoutAmount + proinAppliedAmount;

  int get customerArrivalMinutes {
    if (arrivalMinutes > 0) {
      return arrivalMinutes;
    }
    return isInstant ? 15 : 0;
  }

  List<String> get resolvedServiceIds {
    if (serviceIds.isNotEmpty) {
      return List.unmodifiable(serviceIds);
    }
    return serviceId.trim().isEmpty ? const [] : [serviceId];
  }

  int get salonArrivalMinutes => customerArrivalMinutes + 5;

  DateTime get salonArrivalDeadline => start.add(const Duration(minutes: 5));

  String resolvedServiceName([SalonService? currentService]) {
    final orderedName = serviceName.trim();
    if (orderedName.isNotEmpty) {
      return orderedName;
    }
    final fallbackName = currentService?.name.trim() ?? '';
    return fallbackName.isEmpty ? 'Service' : fallbackName;
  }

  int resolvedServicePrice([SalonService? currentService]) {
    if (servicePrice > 0) {
      return servicePrice;
    }
    return currentService?.price ?? 0;
  }

  Booking copyWith({
    String? id,
    String? customerUid,
    String? salonId,
    String? serviceId,
    List<String>? serviceIds,
    String? barberId,
    String? customerName,
    String? customerPhone,
    DateTime? start,
    int? durationMinutes,
    String? serviceName,
    int? servicePrice,
    Map<String, int>? servicePriceBreakdown,
    int? bookingFee,
    bool? paymentRequired,
    String? paymentStatus,
    String? discountCampaignId,
    String? discountCampaignName,
    double? discountPercent,
    int? discountBaseAmount,
    int? discountAmount,
    int? customerPayableBeforeProin,
    int? customerPayableAmount,
    int? pritzePayoutAmount,
    int? salonTotalEarning,
    String? discountStatus,
    String? proinStatus,
    int? proinRequestedAmount,
    int? proinReservedAmount,
    int? proinRedeemedAmount,
    int? proinReleasedAmount,
    int? proinExpiredOnReleaseAmount,
    String? proinReimbursementStatus,
    BookingStatus? status,
    DateTime? createdAt,
    bool? isInstant,
    DateTime? acceptedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? cancelledAt,
    DateTime? rejectedAt,
    DateTime? customerArrivalReminderSentAt,
    DateTime? ownerArrivalReminderSentAt,
    int? arrivalMinutes,
    String? cancellationReason,
    String? cancelledBy,
    CustomerArrivalStatus? arrivalStatus,
    DateTime? arrivalStatusUpdatedAt,
    bool? arrivalSharingActive,
    DateTime? arrivalSharingExpiresAt,
  }) {
    return Booking(
      id: id ?? this.id,
      customerUid: customerUid ?? this.customerUid,
      salonId: salonId ?? this.salonId,
      serviceId: serviceId ?? this.serviceId,
      serviceIds: serviceIds ?? this.serviceIds,
      barberId: barberId ?? this.barberId,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      start: start ?? this.start,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      serviceName: serviceName ?? this.serviceName,
      servicePrice: servicePrice ?? this.servicePrice,
      servicePriceBreakdown:
          servicePriceBreakdown ?? this.servicePriceBreakdown,
      bookingFee: bookingFee ?? this.bookingFee,
      paymentRequired: paymentRequired ?? this.paymentRequired,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      discountCampaignId: discountCampaignId ?? this.discountCampaignId,
      discountCampaignName: discountCampaignName ?? this.discountCampaignName,
      discountPercent: discountPercent ?? this.discountPercent,
      discountBaseAmount: discountBaseAmount ?? this.discountBaseAmount,
      discountAmount: discountAmount ?? this.discountAmount,
      customerPayableBeforeProin:
          customerPayableBeforeProin ?? this.customerPayableBeforeProin,
      customerPayableAmount:
          customerPayableAmount ?? this.customerPayableAmount,
      pritzePayoutAmount: pritzePayoutAmount ?? this.pritzePayoutAmount,
      salonTotalEarning: salonTotalEarning ?? this.salonTotalEarning,
      discountStatus: discountStatus ?? this.discountStatus,
      proinStatus: proinStatus ?? this.proinStatus,
      proinRequestedAmount: proinRequestedAmount ?? this.proinRequestedAmount,
      proinReservedAmount: proinReservedAmount ?? this.proinReservedAmount,
      proinRedeemedAmount: proinRedeemedAmount ?? this.proinRedeemedAmount,
      proinReleasedAmount: proinReleasedAmount ?? this.proinReleasedAmount,
      proinExpiredOnReleaseAmount:
          proinExpiredOnReleaseAmount ?? this.proinExpiredOnReleaseAmount,
      proinReimbursementStatus:
          proinReimbursementStatus ?? this.proinReimbursementStatus,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      isInstant: isInstant ?? this.isInstant,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      rejectedAt: rejectedAt ?? this.rejectedAt,
      customerArrivalReminderSentAt:
          customerArrivalReminderSentAt ?? this.customerArrivalReminderSentAt,
      ownerArrivalReminderSentAt:
          ownerArrivalReminderSentAt ?? this.ownerArrivalReminderSentAt,
      arrivalMinutes: arrivalMinutes ?? this.arrivalMinutes,
      cancellationReason: cancellationReason ?? this.cancellationReason,
      cancelledBy: cancelledBy ?? this.cancelledBy,
      arrivalStatus: arrivalStatus ?? this.arrivalStatus,
      arrivalStatusUpdatedAt:
          arrivalStatusUpdatedAt ?? this.arrivalStatusUpdatedAt,
      arrivalSharingActive: arrivalSharingActive ?? this.arrivalSharingActive,
      arrivalSharingExpiresAt:
          arrivalSharingExpiresAt ?? this.arrivalSharingExpiresAt,
    );
  }
}

class JoinRequest {
  final String id;
  final String? requesterUid;
  final String salonId;
  final String barberName;
  final String barberPhone;
  final String barberEmail;
  final String speciality;
  final int experienceYears;
  final String resumeSummary;
  final List<String> serviceIds;
  final JoinRequestStatus status;
  final DateTime requestedAt;

  const JoinRequest({
    required this.id,
    this.requesterUid,
    required this.salonId,
    required this.barberName,
    required this.barberPhone,
    this.barberEmail = '',
    required this.speciality,
    this.experienceYears = 1,
    this.resumeSummary = 'Customer-first grooming professional.',
    required this.serviceIds,
    required this.status,
    required this.requestedAt,
  });

  JoinRequest copyWith({
    String? id,
    String? requesterUid,
    String? salonId,
    String? barberName,
    String? barberPhone,
    String? barberEmail,
    String? speciality,
    int? experienceYears,
    String? resumeSummary,
    List<String>? serviceIds,
    JoinRequestStatus? status,
    DateTime? requestedAt,
  }) {
    return JoinRequest(
      id: id ?? this.id,
      requesterUid: requesterUid ?? this.requesterUid,
      salonId: salonId ?? this.salonId,
      barberName: barberName ?? this.barberName,
      barberPhone: barberPhone ?? this.barberPhone,
      barberEmail: barberEmail ?? this.barberEmail,
      speciality: speciality ?? this.speciality,
      experienceYears: experienceYears ?? this.experienceYears,
      resumeSummary: resumeSummary ?? this.resumeSummary,
      serviceIds: serviceIds ?? this.serviceIds,
      status: status ?? this.status,
      requestedAt: requestedAt ?? this.requestedAt,
    );
  }
}
