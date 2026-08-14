function bookingStatusRecipients(_before, after) {
  return [...new Set([
    after.customerUid,
    after.ownerUid,
    after.barberUid,
  ].filter(Boolean))];
}

function bookingRecipientRoles(booking) {
  const rolesByUser = {};
  addRecipientRole(rolesByUser, booking.customerUid, "customer");
  addRecipientRole(rolesByUser, booking.ownerUid, "owner");
  addRecipientRole(rolesByUser, booking.barberUid, "barber");
  return rolesByUser;
}

function addRecipientRole(rolesByUser, uid, role) {
  if (typeof uid !== "string" || !uid.trim()) {
    return;
  }
  const normalizedUid = uid.trim();
  const roles = rolesByUser[normalizedUid] || [];
  if (!roles.includes(role)) {
    roles.push(role);
  }
  rolesByUser[normalizedUid] = roles;
}

module.exports = {
  bookingRecipientRoles,
  bookingStatusRecipients,
};
