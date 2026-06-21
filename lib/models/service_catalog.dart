import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_models.dart';

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
  'Beard',
  'Shaving',
  'Men Grooming',
  'Facial',
  'Cleanup',
  'Bleach & Detan',
  'Advanced Skin',
  'Threading',
  'Waxing',
  'Mani/Pedi',
  'Nails',
  'Makeup',
  'Bridal & Groom',
  'Massage',
  'Body Grooming',
  'Bridal Package',
  'Groom Package',
  'Combo',
  'Kids',
  'Add-On',
  'Home Service',
];

final serviceCatalog = <ServiceTemplate>[
  ..._templates('Hair', 399, 30, [
    'Haircut',
    'Kids Haircut',
    'Senior Citizen Haircut',
    'Hair Trim',
    'Fringe / Bangs Cut',
    'Layer Cut',
    'Step Cut',
    'Bob Cut',
    'U Cut',
    'V Cut',
    'Feather Cut',
    'Pixie Cut',
    'Hair Styling',
    'Blow Dry',
    'Hair Wash + Blow Dry',
    'Hair Setting',
    'Hair Ironing',
    'Hair Crimping',
    'Hair Curling',
    'Party Hairstyle',
    'Bridal Hairstyle',
    'Groom Hairstyle',
  ]),
  ..._templates('Hair Care', 499, 30, [
    'Hair Wash',
    'Shampoo + Conditioning',
    'Deep Conditioning',
    'Hair Mask',
    'Scalp Treatment',
    'Dandruff Treatment',
    'Anti-Hairfall Treatment',
    'Oil Massage',
    'Head Massage',
  ]),
  ..._templates('Hair Spa', 899, 45, [
    'Hair Spa',
    'Anti-Dandruff Hair Spa',
    'Anti-Hairfall Hair Spa',
    'Dry Hair Spa',
    'Damaged Hair Spa',
    'Smoothening Hair Spa',
    'Premium Hair Spa',
  ]),
  ..._templates('Hair Color', 1299, 60, [
    'Hair Colour',
    'Root Touch-Up',
    'Global Hair Colour',
    'Highlights',
    'Streaks',
    'Balayage',
    'Ombre Colour',
    'Fashion Colour',
    'Grey Coverage',
    'Beard Colour',
    'Moustache Colour',
    'Hair Colour Correction',
  ]),
  ..._templates('Hair Texture', 2499, 90, [
    'Hair Straightening',
    'Hair Smoothening',
    'Hair Rebonding',
    'Keratin Treatment',
    'Hair Botox',
    'Nanoplastia',
    'Cysteine Treatment',
    'Perming',
    'Permanent Curling',
    'Temporary Straightening',
    'Temporary Curling',
  ]),
  ..._templates('Beard', 199, 20, [
    'Beard Trim',
    'Beard Styling',
    'Beard Shaping',
    'Beard Cut',
    'Beard Line-Up',
    'Beard Wash',
    'Beard Spa',
    'Beard Colour',
    'Beard Straightening',
    'Moustache Trim',
    'Moustache Styling',
  ]),
  ..._templates('Shaving', 199, 20, [
    'Clean Shave',
    'Luxury Shave',
    'Foam Shave',
    'Razor Shave',
    'Head Shave',
    'Hot Towel Shave',
  ]),
  ..._templates('Men Grooming', 699, 45, [
    'Haircut + Beard',
    'Haircut + Shave',
    'Haircut + Beard + Hair Wash',
    'Groom Styling',
    'Men’s Facial',
    'Men’s Cleanup',
    'Men’s Waxing',
  ]),
  ..._templates('Facial', 999, 45, [
    'Basic Facial',
    'Fruit Facial',
    'Gold Facial',
    'Diamond Facial',
    'Pearl Facial',
    'Charcoal Facial',
    'Anti-Tan Facial',
    'Anti-Acne Facial',
    'Skin Brightening Facial',
    'Hydrating Facial',
    'Anti-Aging Facial',
    'Bridal Facial',
    'Premium Facial',
  ]),
  ..._templates('Cleanup', 499, 30, [
    'Face Cleanup',
    'Fruit Cleanup',
    'Anti-Tan Cleanup',
    'Blackhead Removal',
    'Whitehead Removal',
    'Face Massage',
    'Face Mask',
  ]),
  ..._templates('Bleach & Detan', 399, 30, [
    'Face Bleach',
    'Neck Bleach',
    'Hands Bleach',
    'Feet Bleach',
    'Full Body Bleach',
    'Face Detan',
    'Neck Detan',
    'Hands Detan',
    'Feet Detan',
    'Full Body Detan',
  ]),
  ..._templates('Advanced Skin', 1499, 60, [
    'Hydra Facial',
    'Chemical Peel',
    'Microdermabrasion',
    'Skin Polishing',
    'Skin Brightening Treatment',
    'Acne Treatment',
    'Pigmentation Treatment',
    'Under-Eye Treatment',
  ]),
  ..._templates('Threading', 99, 15, [
    'Eyebrow Threading',
    'Upper Lip Threading',
    'Lower Lip Threading',
    'Forehead Threading',
    'Chin Threading',
    'Jawline Threading',
    'Side Locks Threading',
    'Neck Threading',
    'Full Face Threading',
  ]),
  ..._templates('Waxing', 299, 30, [
    'Upper Lip Waxing',
    'Chin Waxing',
    'Face Waxing',
    'Underarms Waxing',
    'Half Hands Waxing',
    'Full Hands Waxing',
    'Half Legs Waxing',
    'Full Legs Waxing',
    'Back Waxing',
    'Stomach Waxing',
    'Chest Waxing',
    'Full Body Waxing',
    'Rica Waxing',
    'Chocolate Waxing',
    'Brazilian Waxing',
    'Bikini Waxing',
    'Full Face Waxing',
    'Full Arms Rica Waxing',
    'Full Legs Rica Waxing',
    'Full Body Rica Waxing',
  ]),
  ..._templates('Mani/Pedi', 499, 35, [
    'Basic Manicure',
    'Classic Manicure',
    'Spa Manicure',
    'Luxury Manicure',
    'Gel Manicure',
    'French Manicure',
    'Nail Cut + File',
    'Nail Cleaning',
    'Nail Polish',
    'Hand Massage',
    'Basic Pedicure',
    'Classic Pedicure',
    'Spa Pedicure',
    'Luxury Pedicure',
    'Gel Pedicure',
    'French Pedicure',
    'Foot Cleaning',
    'Foot Scrub',
    'Foot Massage',
    'Heel Cleaning',
    'Callus Removal',
  ]),
  ..._templates('Nails', 399, 30, [
    'Nail Polish',
    'Gel Polish',
    'Nail Art',
    'French Nail Art',
    'Nail Extension',
    'Acrylic Nails',
    'Gel Nails',
    'Nail Refill',
    'Nail Removal',
    'Nail Repair',
    'Bridal Nail Art',
  ]),
  ..._templates('Makeup', 2499, 90, [
    'Light Makeup',
    'Party Makeup',
    'Engagement Makeup',
    'Reception Makeup',
    'HD Makeup',
    'Airbrush Makeup',
    'Nude Makeup',
    'Glam Makeup',
    'Saree Draping',
    'Hair Styling with Makeup',
  ]),
  ..._templates('Bridal & Groom', 4999, 120, [
    'Bridal Makeup',
    'Bridal Hair Styling',
    'Bridal Draping',
    'Groom Makeup',
    'Groom Styling',
    'Pre-Wedding Makeup',
    'Wedding Day Package',
    'Reception Package',
  ]),
  ..._templates('Massage', 899, 45, [
    'Head Massage',
    'Oil Head Massage',
    'Dry Head Massage',
    'Face Massage',
    'Neck Massage',
    'Shoulder Massage',
    'Body Massage',
    'Back Massage',
    'Foot Massage',
    'Hand Massage',
    'Body Scrub',
    'Body Polishing',
    'Body Spa',
    'Aromatherapy Massage',
    'Relaxation Massage',
  ]),
  ..._templates('Body Grooming', 799, 45, [
    'Body Polishing',
    'Body Scrub',
    'Body Detan',
    'Body Bleach',
    'Back Cleaning',
    'Underarm Cleaning',
    'Full Body Grooming',
    'Personal Grooming',
  ]),
  ..._templates('Bridal Package', 5999, 150, [
    'Bridal Makeup Package',
    'Bridal Facial Package',
    'Bridal Hair Package',
    'Bridal Skin Package',
    'Bridal Waxing Package',
    'Bridal Nail Package',
    'Complete Bridal Package',
  ]),
  ..._templates('Groom Package', 2999, 100, [
    'Groom Makeup Package',
    'Groom Facial Package',
    'Groom Haircut + Beard Package',
    'Groom Styling Package',
    'Complete Groom Package',
  ]),
  ..._templates('Combo', 999, 60, [
    'Haircut + Beard',
    'Haircut + Beard + Hair Wash',
    'Haircut + Facial',
    'Haircut + Hair Spa',
    'Grooming Combo',
    'Premium Men’s Combo',
    'Facial + Threading',
    'Facial + Waxing',
    'Haircut + Hair Spa',
    'Haircut + Styling',
    'Manicure + Pedicure',
    'Waxing + Cleanup',
    'Premium Beauty Combo',
    'Haircut + Hair Wash',
    'Hair Spa + Haircut',
    'Facial + Detan',
    'Head Massage + Hair Wash',
    'Salon Day Package',
  ]),
  ..._templates('Kids', 199, 25, [
    'Kids Haircut',
    'Kids Hair Wash',
    'Kids Styling',
    'Kids Nail Cut',
    'Kids Party Hairstyle',
  ]),
  ..._templates('Add-On', 99, 15, [
    'Hair Wash Add-On',
    'Beard Wash Add-On',
    'Blow Dry Add-On',
    'Conditioning Add-On',
    'Detan Add-On',
    'Scrub Add-On',
    'Massage Add-On',
    'Premium Product Add-On',
    'Extra Length Hair Charge',
    'Extra Thick Hair Charge',
    'Home Service Charge',
  ]),
  ..._templates('Home Service', 499, 45, [
    'Haircut at Home',
    'Beard at Home',
    'Facial at Home',
    'Makeup at Home',
    'Bridal Makeup at Home',
    'Mani/Pedi at Home',
    'Waxing at Home',
    'Massage at Home',
  ]),
];

List<ServiceTemplate> _templates(
  String category,
  int price,
  int durationMinutes,
  List<String> names,
) {
  return [
    for (final name in names)
      ServiceTemplate(
        name: name,
        category: category,
        price: price,
        durationMinutes: durationMinutes,
      ),
  ];
}

String serviceIconAssetForCategory(String category) {
  final normalized = category.toLowerCase();
  if (normalized.contains('beard') || normalized.contains('shav')) {
    return 'assets/service_icons/beard.jpeg';
  }
  if (normalized.contains('facial') ||
      normalized.contains('cleanup') ||
      normalized.contains('skin') ||
      normalized.contains('bleach') ||
      normalized.contains('detan')) {
    return 'assets/service_icons/facial.jpeg';
  }
  if (normalized.contains('spa') || normalized.contains('massage')) {
    return 'assets/service_icons/spa.jpeg';
  }
  if (normalized.contains('mani') ||
      normalized.contains('pedi') ||
      normalized.contains('nail')) {
    return 'assets/service_icons/mani_pedi.jpeg';
  }
  if (normalized.contains('thread')) {
    return 'assets/service_icons/threading.jpeg';
  }
  if (normalized.contains('wax')) {
    return 'assets/service_icons/waxing.jpeg';
  }
  if (normalized.contains('color') || normalized.contains('colour')) {
    return 'assets/service_icons/hair_color.jpeg';
  }
  return 'assets/service_icons/haircut.jpeg';
}

bool serviceMatchesBarberSpeciality(SalonService service, String speciality) {
  final value = speciality.toLowerCase();
  final category = service.category.toLowerCase();
  final name = service.name.toLowerCase();
  if (value.contains('all-round')) {
    return true;
  }
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
      normalized.contains('skin')) {
    return AppColors.leaf;
  }
  if (normalized.contains('spa') || normalized.contains('massage')) {
    return AppColors.charcoal;
  }
  if (normalized.contains('mani') ||
      normalized.contains('pedi') ||
      normalized.contains('nail')) {
    return AppColors.rose;
  }
  if (normalized.contains('thread') || normalized.contains('wax')) {
    return AppColors.gold;
  }
  if (normalized.contains('color') || normalized.contains('colour')) {
    return AppColors.copper;
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
      normalized.contains('skin')) {
    return Icons.spa_outlined;
  }
  if (normalized.contains('mani') ||
      normalized.contains('pedi') ||
      normalized.contains('nail')) {
    return Icons.back_hand_outlined;
  }
  if (normalized.contains('color') || normalized.contains('colour')) {
    return Icons.palette_outlined;
  }
  return Icons.content_cut;
}
