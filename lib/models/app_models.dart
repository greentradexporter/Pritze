enum BookingStatus {
  pending,
  confirmed,
  inProgress,
  completed,
  cancelled,
  rejected,
}

enum BarberBookingBucket { upcoming, active, history, cancelled }

enum SalonBookingBucket { requests, upcoming, active, history, cancelled }

enum CustomerBookingBucket { active, history, cancelled }

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

  const UserAccount({
    required this.id,
    required this.name,
    required this.contact,
    required this.provider,
  });

  UserAccount copyWith({
    String? id,
    String? name,
    String? contact,
    LoginProvider? provider,
  }) {
    return UserAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      contact: contact ?? this.contact,
      provider: provider ?? this.provider,
    );
  }
}

class SalonService {
  final String id;
  final String name;
  final String category;
  final int price;
  final int durationMinutes;

  const SalonService({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.durationMinutes,
  });

  SalonService copyWith({
    String? id,
    String? name,
    String? category,
    int? price,
    int? durationMinutes,
  }) {
    return SalonService(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      price: price ?? this.price,
      durationMinutes: durationMinutes ?? this.durationMinutes,
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
  final String logoUrl;
  final List<String> photoUrls;
  final String distanceLabel;
  final double rating;
  final int reviewCount;
  final String openTime;
  final String closeTime;
  final bool isOpen;
  final List<SalonService> services;

  const Salon({
    required this.id,
    required this.name,
    required this.ownerName,
    required this.address,
    this.directionsUrl = '',
    required this.phone,
    required this.logoUrl,
    this.photoUrls = const [],
    required this.distanceLabel,
    required this.rating,
    required this.reviewCount,
    required this.openTime,
    required this.closeTime,
    required this.isOpen,
    required this.services,
  });

  Salon copyWith({
    String? id,
    String? name,
    String? ownerName,
    String? address,
    String? directionsUrl,
    String? phone,
    String? logoUrl,
    List<String>? photoUrls,
    String? distanceLabel,
    double? rating,
    int? reviewCount,
    String? openTime,
    String? closeTime,
    bool? isOpen,
    List<SalonService>? services,
  }) {
    return Salon(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerName: ownerName ?? this.ownerName,
      address: address ?? this.address,
      directionsUrl: directionsUrl ?? this.directionsUrl,
      phone: phone ?? this.phone,
      logoUrl: logoUrl ?? this.logoUrl,
      photoUrls: photoUrls ?? this.photoUrls,
      distanceLabel: distanceLabel ?? this.distanceLabel,
      rating: rating ?? this.rating,
      reviewCount: reviewCount ?? this.reviewCount,
      openTime: openTime ?? this.openTime,
      closeTime: closeTime ?? this.closeTime,
      isOpen: isOpen ?? this.isOpen,
      services: services ?? this.services,
    );
  }

  String get coverImageUrl {
    if (photoUrls.isNotEmpty) {
      return photoUrls.first;
    }
    return logoUrl;
  }
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
  final String barberId;
  final String customerName;
  final String customerPhone;
  final DateTime start;
  final int durationMinutes;
  final String serviceName;
  final int servicePrice;
  final BookingStatus status;
  final DateTime createdAt;

  const Booking({
    required this.id,
    this.customerUid,
    required this.salonId,
    required this.serviceId,
    required this.barberId,
    required this.customerName,
    required this.customerPhone,
    required this.start,
    this.durationMinutes = 30,
    this.serviceName = '',
    this.servicePrice = 0,
    required this.status,
    required this.createdAt,
  });

  Booking copyWith({
    String? id,
    String? customerUid,
    String? salonId,
    String? serviceId,
    String? barberId,
    String? customerName,
    String? customerPhone,
    DateTime? start,
    int? durationMinutes,
    String? serviceName,
    int? servicePrice,
    BookingStatus? status,
    DateTime? createdAt,
  }) {
    return Booking(
      id: id ?? this.id,
      customerUid: customerUid ?? this.customerUid,
      salonId: salonId ?? this.salonId,
      serviceId: serviceId ?? this.serviceId,
      barberId: barberId ?? this.barberId,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      start: start ?? this.start,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      serviceName: serviceName ?? this.serviceName,
      servicePrice: servicePrice ?? this.servicePrice,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
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
