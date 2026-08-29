const CUSTOMER_ARRIVAL_STATUSES = new Set([
  "notStarted",
  "leavingNow",
  "onTheWay",
  "runningLate",
  "arrived",
]);

const MAX_LOCATION_AGE_MS = 5 * 60 * 1000;
const MAX_SHARING_DURATION_MS = 60 * 60 * 1000;

function validArrivalStatus(value) {
  return CUSTOMER_ARRIVAL_STATUSES.has(String(value || ""));
}

function validCoordinates(latitude, longitude) {
  return Number.isFinite(latitude) && latitude >= -90 && latitude <= 90 &&
    Number.isFinite(longitude) && longitude >= -180 && longitude <= 180;
}

function validLocationUpdate({
  latitude,
  longitude,
  accuracyMeters,
  capturedAtMillis,
  nowMillis = Date.now(),
}) {
  return validCoordinates(latitude, longitude) &&
    Number.isFinite(accuracyMeters) && accuracyMeters >= 0 &&
    accuracyMeters <= 2000 && Number.isFinite(capturedAtMillis) &&
    Math.abs(nowMillis - capturedAtMillis) <= MAX_LOCATION_AGE_MS;
}

function sharingExpiresAtMillis({
  nowMillis = Date.now(),
  bookingStartMillis,
  durationMinutes = 30,
}) {
  const bookingCutoff = Number(bookingStartMillis) +
    Math.max(30, Number(durationMinutes) || 30) * 60 * 1000 + 30 * 60 * 1000;
  return Math.min(nowMillis + MAX_SHARING_DURATION_MS, bookingCutoff);
}

function distanceMeters(first, second) {
  if (!validCoordinates(first.latitude, first.longitude) ||
      !validCoordinates(second.latitude, second.longitude)) return null;
  const radians = (degrees) => degrees * Math.PI / 180;
  const earthRadiusMeters = 6371000;
  const latitudeDelta = radians(second.latitude - first.latitude);
  const longitudeDelta = radians(second.longitude - first.longitude);
  const a = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(radians(first.latitude)) *
    Math.cos(radians(second.latitude)) *
    Math.sin(longitudeDelta / 2) ** 2;
  return earthRadiusMeters * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function estimatedArrivalMinutes(distance, speedMetersPerSecond) {
  if (!Number.isFinite(distance) || distance < 0) return 0;
  const safeSpeed = Number.isFinite(speedMetersPerSecond) &&
    speedMetersPerSecond >= 1.4 ?
    Math.min(speedMetersPerSecond, 33) : 5.5;
  return Math.max(1, Math.min(180, Math.ceil(distance / safeSpeed / 60)));
}

function coordinatesFromSalon(salon = {}) {
  const explicit = {
    latitude: Number(salon.latitude ?? salon.mapLatitude),
    longitude: Number(salon.longitude ?? salon.mapLongitude),
  };
  if (validCoordinates(explicit.latitude, explicit.longitude)) return explicit;
  let directionsUrl = String(salon.directionsUrl || "").trim();
  try {
    directionsUrl = decodeURIComponent(directionsUrl);
  } catch (_) {
    // Keep the original value when a pasted link contains malformed escapes.
  }
  const match = directionsUrl.match(
    /(?:@|[?&](?:q|query|destination)=|\/place\/)(-?\d{1,2}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)/i,
  );
  if (!match) return null;
  const parsed = {latitude: Number(match[1]), longitude: Number(match[2])};
  return validCoordinates(parsed.latitude, parsed.longitude) ? parsed : null;
}

module.exports = {
  CUSTOMER_ARRIVAL_STATUSES,
  MAX_SHARING_DURATION_MS,
  coordinatesFromSalon,
  distanceMeters,
  estimatedArrivalMinutes,
  sharingExpiresAtMillis,
  validArrivalStatus,
  validCoordinates,
  validLocationUpdate,
};
