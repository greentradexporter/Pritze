import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_models.dart';
import 'legacy_service_catalog.dart';

class ServiceTemplate {
  final String name;
  final String category;
  final int price;
  final int durationMinutes;

  const ServiceTemplate({
    required this.name,
    required this.category,
    required this.price,
    required this.durationMinutes,
  });
}

const serviceCategoryLabels = <String>[
  'Hair',
  'Hair Care',
  'Hair Spa',
  'Hair Color',
  'Hair Texture',
  'Massage',
  'Facial',
  'Cleanup',
  'Bleach & Detan',
  'Beard',
  'Shaving',
  'Threading',
  'Waxing',
  'Mani/Pedi',
  'Makeup',
];

const serviceCatalog = <ServiceTemplate>[
  ServiceTemplate(
    name: 'Haircut Men',
    category: 'Hair',
    price: 399,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Haircut Women',
    category: 'Hair',
    price: 499,
    durationMinutes: 40,
  ),
  ServiceTemplate(
    name: 'Hair Wash Men',
    category: 'Hair Care',
    price: 299,
    durationMinutes: 20,
  ),
  ServiceTemplate(
    name: 'Hair wash Women',
    category: 'Hair Care',
    price: 399,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Haircut + Hair Wash',
    category: 'Hair',
    price: 599,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Blow Dry / Hair Styling',
    category: 'Hair',
    price: 499,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Hair Spa',
    category: 'Hair Spa',
    price: 899,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Hair Colour',
    category: 'Hair Color',
    price: 1299,
    durationMinutes: 60,
  ),
  ServiceTemplate(
    name: 'Root Touch-up',
    category: 'Hair Color',
    price: 999,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Keratin / Smoothening',
    category: 'Hair Texture',
    price: 2499,
    durationMinutes: 90,
  ),
  ServiceTemplate(
    name: 'Head Massage',
    category: 'Massage',
    price: 499,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Facial',
    category: 'Facial',
    price: 999,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Face Cleanup',
    category: 'Cleanup',
    price: 499,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'D-Tan',
    category: 'Bleach & Detan',
    price: 399,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Bleach',
    category: 'Bleach & Detan',
    price: 399,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Beard Trim',
    category: 'Beard',
    price: 199,
    durationMinutes: 20,
  ),
  ServiceTemplate(
    name: 'Shave',
    category: 'Shaving',
    price: 199,
    durationMinutes: 20,
  ),
  ServiceTemplate(
    name: 'Beard Styling',
    category: 'Beard',
    price: 299,
    durationMinutes: 25,
  ),
  ServiceTemplate(
    name: 'Haircut + Beard',
    category: 'Beard',
    price: 599,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Beard Colour',
    category: 'Hair Color',
    price: 399,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Eyebrow Threading',
    category: 'Threading',
    price: 99,
    durationMinutes: 15,
  ),
  ServiceTemplate(
    name: 'Upper Lip Threading',
    category: 'Threading',
    price: 99,
    durationMinutes: 15,
  ),
  ServiceTemplate(
    name: 'Full Face Threading',
    category: 'Threading',
    price: 299,
    durationMinutes: 30,
  ),
  ServiceTemplate(
    name: 'Full Arms Waxing',
    category: 'Waxing',
    price: 499,
    durationMinutes: 35,
  ),
  ServiceTemplate(
    name: 'Full Legs Waxing',
    category: 'Waxing',
    price: 699,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Underarms Waxing',
    category: 'Waxing',
    price: 299,
    durationMinutes: 20,
  ),
  ServiceTemplate(
    name: 'Full Body Waxing',
    category: 'Waxing',
    price: 1499,
    durationMinutes: 90,
  ),
  ServiceTemplate(
    name: 'Manicure',
    category: 'Mani/Pedi',
    price: 499,
    durationMinutes: 35,
  ),
  ServiceTemplate(
    name: 'Pedicure',
    category: 'Mani/Pedi',
    price: 599,
    durationMinutes: 45,
  ),
  ServiceTemplate(
    name: 'Party / Bridal Makeup.',
    category: 'Makeup',
    price: 2499,
    durationMinutes: 90,
  ),
];

String normalizeServiceName(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final Set<String> _approvedServiceNames = serviceCatalog
    .map((service) => normalizeServiceName(service.name))
    .toSet();

final Set<String> _legacyServiceNames = legacyBuiltInServiceNames
    .map(normalizeServiceName)
    .toSet();

bool isApprovedServiceName(String name) {
  return _approvedServiceNames.contains(normalizeServiceName(name));
}

ServiceTemplate? serviceTemplateForName(String name) {
  final normalized = normalizeServiceName(name);
  for (final service in serviceCatalog) {
    if (normalizeServiceName(service.name) == normalized) {
      return service;
    }
  }
  return null;
}

String serviceCatalogId(String name) {
  final slug = normalizeServiceName(name).replaceAll(' ', '-');
  return 'catalog-$slug';
}

bool inferServiceIsCustom(String name, Object? storedValue) {
  if (storedValue is bool) {
    return storedValue;
  }
  final normalized = normalizeServiceName(name);
  return !_approvedServiceNames.contains(normalized) &&
      !_legacyServiceNames.contains(normalized);
}

/// Produces the one authoritative salon menu used by Firebase-backed salons.
///
/// Matching existing services retain salon-controlled values (price, duration,
/// availability and instant-booking state). Retired/custom entries are removed,
/// missing entries receive the catalogue defaults, and the output is always in
/// the same 30-service order.
List<SalonService> canonicalSalonServices(Iterable<SalonService> services) {
  final existingByName = <String, SalonService>{};
  for (final service in services) {
    final normalized = normalizeServiceName(service.name);
    if (_approvedServiceNames.contains(normalized)) {
      existingByName.putIfAbsent(normalized, () => service);
    }
  }

  return serviceCatalog
      .map((template) {
        final normalized = normalizeServiceName(template.name);
        final existing = existingByName[normalized];
        if (existing == null) {
          return SalonService(
            id: serviceCatalogId(template.name),
            name: template.name,
            category: template.category,
            price: template.price,
            durationMinutes: template.durationMinutes,
          );
        }
        return existing.copyWith(
          name: template.name,
          category: template.category,
          isCustom: false,
        );
      })
      .toList(growable: false);
}

bool hasCanonicalSalonServices(Iterable<SalonService> services) {
  final list = services.toList(growable: false);
  if (list.length != serviceCatalog.length) {
    return false;
  }
  for (var index = 0; index < serviceCatalog.length; index++) {
    if (list[index].name != serviceCatalog[index].name ||
        list[index].category != serviceCatalog[index].category ||
        list[index].isCustom) {
      return false;
    }
  }
  return true;
}

String serviceIconAssetForService(String serviceName, {String category = ''}) {
  final normalizedName = normalizeServiceName(serviceName);
  final normalizedCategory = category.toLowerCase();
  final combined = '$normalizedName $normalizedCategory';
  if (normalizedName.contains('haircut')) {
    return 'assets/service_icons/haircut.jpeg';
  }
  if (combined.contains('beard') || combined.contains('shav')) {
    return 'assets/service_icons/beard.jpeg';
  }
  if (combined.contains('wax')) {
    return 'assets/service_icons/waxing.jpeg';
  }
  if (combined.contains('thread')) {
    return 'assets/service_icons/threading.jpeg';
  }
  if (combined.contains('mani') ||
      combined.contains('pedi') ||
      combined.contains('nail')) {
    return 'assets/service_icons/mani_pedi.jpeg';
  }
  if (combined.contains('makeup') ||
      combined.contains('bridal') ||
      combined.contains('party')) {
    return 'assets/service_icons/facial.jpeg';
  }
  if (combined.contains('facial') ||
      combined.contains('cleanup') ||
      combined.contains('skin') ||
      combined.contains('bleach') ||
      combined.contains('detan')) {
    return 'assets/service_icons/facial.jpeg';
  }
  if (combined.contains('color') ||
      combined.contains('colour') ||
      combined.contains('root touch') ||
      combined.contains('texture') ||
      combined.contains('keratin') ||
      combined.contains('smoothening')) {
    return 'assets/service_icons/hair_color.jpeg';
  }
  if (combined.contains('spa') ||
      combined.contains('massage') ||
      combined.contains('hair wash') ||
      combined.contains('hair care')) {
    return 'assets/service_icons/spa.jpeg';
  }
  return 'assets/service_icons/haircut.jpeg';
}

String serviceIconAssetForCategory(String category) {
  return serviceIconAssetForService(category, category: category);
}

bool serviceMatchesBarberSpeciality(SalonService service, String speciality) {
  final value = speciality.toLowerCase();
  final category = service.category.toLowerCase();
  final name = service.name.toLowerCase();
  if (value.contains('all-round')) return true;
  if (value.contains('beard') || value.contains('shave')) {
    return category.contains('beard') ||
        category.contains('shav') ||
        name.contains('beard') ||
        name.contains('shave');
  }
  if (value.contains('color')) {
    return category.contains('color') ||
        category.contains('colour') ||
        name.contains('color') ||
        name.contains('colour');
  }
  if (value.contains('spa')) {
    return category.contains('spa') ||
        category.contains('massage') ||
        name.contains('spa') ||
        name.contains('massage');
  }
  if (value.contains('skin') || value.contains('cleanup')) {
    return category.contains('facial') ||
        category.contains('cleanup') ||
        category.contains('skin') ||
        category.contains('bleach') ||
        category.contains('detan');
  }
  if (value.contains('kids')) {
    return category.contains('kids') || name.contains('kid');
  }
  if (value.contains('styling')) {
    return category.contains('hair') &&
        (name.contains('styl') ||
            name.contains('blow') ||
            name.contains('setting') ||
            name.contains('curl') ||
            name.contains('iron'));
  }
  return category == 'hair' ||
      name.contains('cut') ||
      name.contains('fade') ||
      name.contains('trim');
}

Color serviceColorForCategory(String category) {
  final normalized = category.toLowerCase();
  if (normalized.contains('beard') || normalized.contains('shav')) {
    return AppColors.goldDeep;
  }
  if (normalized.contains('facial') ||
      normalized.contains('cleanup') ||
      normalized.contains('skin') ||
      normalized.contains('bleach') ||
      normalized.contains('detan')) {
    return AppColors.leaf;
  }
  if (normalized.contains('spa') || normalized.contains('massage')) {
    return AppColors.plum;
  }
  if (normalized.contains('mani') ||
      normalized.contains('pedi') ||
      normalized.contains('nail')) {
    return AppColors.rose;
  }
  if (normalized.contains('thread') || normalized.contains('wax')) {
    return AppColors.gold;
  }
  if (normalized.contains('color') ||
      normalized.contains('colour') ||
      normalized.contains('texture')) {
    return AppColors.copper;
  }
  if (normalized.contains('makeup') || normalized.contains('bridal')) {
    return AppColors.rose;
  }
  return AppColors.primary;
}

IconData serviceFallbackIconForCategory(String category) {
  final normalized = category.toLowerCase();
  if (normalized.contains('beard') || normalized.contains('shav')) {
    return Icons.face_retouching_natural;
  }
  if (normalized.contains('facial') ||
      normalized.contains('cleanup') ||
      normalized.contains('skin') ||
      normalized.contains('bleach') ||
      normalized.contains('detan')) {
    return Icons.spa_outlined;
  }
  if (normalized.contains('spa') || normalized.contains('massage')) {
    return Icons.spa_outlined;
  }
  if (normalized.contains('mani') ||
      normalized.contains('pedi') ||
      normalized.contains('nail')) {
    return Icons.back_hand_outlined;
  }
  if (normalized.contains('thread')) {
    return Icons.gesture;
  }
  if (normalized.contains('wax')) {
    return Icons.waves_outlined;
  }
  if (normalized.contains('color') ||
      normalized.contains('colour') ||
      normalized.contains('texture')) {
    return Icons.palette_outlined;
  }
  if (normalized.contains('makeup') || normalized.contains('bridal')) {
    return Icons.auto_awesome;
  }
  return Icons.content_cut;
}
