enum BookingStatus { pending, confirmed, inProgress, completed, cancelled }

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
    }
  }
}

enum JoinRequestStatus { pending, approved, rejected }

extension JoinRequestStatusLabel on JoinRequestStatus {
  String get label {
    switch (this) {
      case JoinRequestStatus.pending:
        return 'Pending';
      case JoinRequestStatus.approved:
        return 'Approved';
      case JoinRequestStatus.rejected:
        return 'Rejected';
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

enum LoginProvider { phone, gmail }

extension LoginProviderLabel on LoginProvider {
  String get label {
    switch (this) {
      case LoginProvider.phone:
        return 'Phone';
      case LoginProvider.gmail:
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
  final String phone;
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
    required this.phone,
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
    String? phone,
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
      phone: phone ?? this.phone,
      distanceLabel: distanceLabel ?? this.distanceLabel,
      rating: rating ?? this.rating,
      reviewCount: reviewCount ?? this.reviewCount,
      openTime: openTime ?? this.openTime,
      closeTime: closeTime ?? this.closeTime,
      isOpen: isOpen ?? this.isOpen,
      services: services ?? this.services,
    );
  }
}

class Barber {
  final String id;
  final String? uid;
  final String salonId;
  final String name;
  final String phone;
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
  final String salonId;
  final String serviceId;
  final String barberId;
  final String customerName;
  final String customerPhone;
  final DateTime start;
  final BookingStatus status;
  final DateTime createdAt;

  const Booking({
    required this.id,
    required this.salonId,
    required this.serviceId,
    required this.barberId,
    required this.customerName,
    required this.customerPhone,
    required this.start,
    required this.status,
    required this.createdAt,
  });

  Booking copyWith({
    String? id,
    String? salonId,
    String? serviceId,
    String? barberId,
    String? customerName,
    String? customerPhone,
    DateTime? start,
    BookingStatus? status,
    DateTime? createdAt,
  }) {
    return Booking(
      id: id ?? this.id,
      salonId: salonId ?? this.salonId,
      serviceId: serviceId ?? this.serviceId,
      barberId: barberId ?? this.barberId,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      start: start ?? this.start,
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
      speciality: speciality ?? this.speciality,
      experienceYears: experienceYears ?? this.experienceYears,
      resumeSummary: resumeSummary ?? this.resumeSummary,
      serviceIds: serviceIds ?? this.serviceIds,
      status: status ?? this.status,
      requestedAt: requestedAt ?? this.requestedAt,
    );
  }
}
