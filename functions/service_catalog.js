"use strict";

const SERVICE_CATALOG = Object.freeze([
  {name: "Haircut Men", category: "Hair", price: 399, durationMinutes: 30},
  {name: "Haircut Women", category: "Hair", price: 499, durationMinutes: 40},
  {name: "Hair Wash Men", category: "Hair Care", price: 299, durationMinutes: 20},
  {name: "Hair wash Women", category: "Hair Care", price: 399, durationMinutes: 30},
  {name: "Haircut + Hair Wash", category: "Hair", price: 599, durationMinutes: 45},
  {name: "Blow Dry / Hair Styling", category: "Hair", price: 499, durationMinutes: 30},
  {name: "Hair Spa", category: "Hair Spa", price: 899, durationMinutes: 45},
  {name: "Hair Colour", category: "Hair Color", price: 1299, durationMinutes: 60},
  {name: "Root Touch-up", category: "Hair Color", price: 999, durationMinutes: 45},
  {name: "Keratin / Smoothening", category: "Hair Texture", price: 2499, durationMinutes: 90},
  {name: "Head Massage", category: "Massage", price: 499, durationMinutes: 30},
  {name: "Facial", category: "Facial", price: 999, durationMinutes: 45},
  {name: "Face Cleanup", category: "Cleanup", price: 499, durationMinutes: 30},
  {name: "D-Tan", category: "Bleach & Detan", price: 399, durationMinutes: 30},
  {name: "Bleach", category: "Bleach & Detan", price: 399, durationMinutes: 30},
  {name: "Beard Trim", category: "Beard", price: 199, durationMinutes: 20},
  {name: "Shave", category: "Shaving", price: 199, durationMinutes: 20},
  {name: "Beard Styling", category: "Beard", price: 299, durationMinutes: 25},
  {name: "Haircut + Beard", category: "Beard", price: 599, durationMinutes: 45},
  {name: "Beard Colour", category: "Hair Color", price: 399, durationMinutes: 30},
  {name: "Eyebrow Threading", category: "Threading", price: 99, durationMinutes: 15},
  {name: "Upper Lip Threading", category: "Threading", price: 99, durationMinutes: 15},
  {name: "Full Face Threading", category: "Threading", price: 299, durationMinutes: 30},
  {name: "Full Arms Waxing", category: "Waxing", price: 499, durationMinutes: 35},
  {name: "Full Legs Waxing", category: "Waxing", price: 699, durationMinutes: 45},
  {name: "Underarms Waxing", category: "Waxing", price: 299, durationMinutes: 20},
  {name: "Full Body Waxing", category: "Waxing", price: 1499, durationMinutes: 90},
  {name: "Manicure", category: "Mani/Pedi", price: 499, durationMinutes: 35},
  {name: "Pedicure", category: "Mani/Pedi", price: 599, durationMinutes: 45},
  {name: "Party / Bridal Makeup.", category: "Makeup", price: 2499, durationMinutes: 90},
]);

function normalizeServiceName(value) {
  return String(value || "")
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
}

function catalogServiceId(name) {
  return `catalog-${normalizeServiceName(name).replace(/ /g, "-")}`;
}

function canonicalizeSalonServices(services) {
  const existingByName = new Map();
  for (const service of Array.isArray(services) ? services : []) {
    const normalized = normalizeServiceName(service && service.name);
    if (normalized && !existingByName.has(normalized)) {
      existingByName.set(normalized, service);
    }
  }

  return SERVICE_CATALOG.map((template) => {
    const existing = existingByName.get(normalizeServiceName(template.name));
    return {
      id: typeof existing?.id === "string" && existing.id.trim() ?
        existing.id : catalogServiceId(template.name),
      name: template.name,
      category: template.category,
      price: Number.isInteger(existing?.price) && existing.price > 0 ?
        existing.price : template.price,
      durationMinutes:
        Number.isInteger(existing?.durationMinutes) &&
        existing.durationMinutes > 0 ?
          existing.durationMinutes : template.durationMinutes,
      isAvailable: existing?.isAvailable !== false,
      instantBookingEnabled: existing?.instantBookingEnabled !== false,
      isCustom: false,
    };
  });
}

module.exports = {
  SERVICE_CATALOG,
  canonicalizeSalonServices,
  catalogServiceId,
  normalizeServiceName,
};
