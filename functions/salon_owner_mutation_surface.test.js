const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
const ownerMutationStart = source.indexOf("exports.saveOwnerSalonProfile");
const ownerMutations = source.slice(
  ownerMutationStart,
  source.indexOf("exports.updateCustomerProfile", ownerMutationStart),
);

test("salon owner writes use focused authenticated callables", () => {
  for (const callable of [
    "saveOwnerSalonProfile",
    "setOwnerInstantBookingEnabled",
    "saveOwnerSalonServices",
    "saveOwnerBarber",
  ]) {
    assert.match(
      ownerMutations,
      new RegExp(`exports\\.${callable} = onMobileCall`),
    );
  }
  assert.match(ownerMutations, /requireAuthenticatedUid\(request\)/);
  assert.match(ownerMutations, /requireOwnedSalon\(\{uid, salonId\}\)/);
});

test("salon mutations update only their intended cloud resources", () => {
  const instantToggle = ownerMutations.slice(
    ownerMutations.indexOf("exports.setOwnerInstantBookingEnabled"),
    ownerMutations.indexOf("exports.saveOwnerSalonServices"),
  );
  const serviceSave = ownerMutations.slice(
    ownerMutations.indexOf("exports.saveOwnerSalonServices"),
    ownerMutations.indexOf("exports.saveOwnerBarber"),
  );

  assert.match(instantToggle, /instantBookingsEnabled: enabled/);
  assert.match(instantToggle, /instantBookingsPausedDate: ""/);
  assert.doesNotMatch(instantToggle, /services,/);
  assert.match(serviceSave, /canonicalizeSalonServices\(submitted\)/);
  assert.match(serviceSave, /serviceCount: services\.length/);
});
