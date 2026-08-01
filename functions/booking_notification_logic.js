function bookingStatusRecipients(_before, after) {
  if (after.status === "cancelled") {
    if (after.cancelledBy === "customer") {
      return [after.ownerUid, after.barberUid].filter(Boolean);
    }
    if (after.cancelledBy === "salon" || after.cancelledBy === "owner") {
      return [after.customerUid, after.barberUid].filter(Boolean);
    }
  }
  if (after.status === "confirmed" || after.status === "rejected") {
    return [after.customerUid, after.barberUid].filter(Boolean);
  }
  return [after.customerUid, after.ownerUid, after.barberUid].filter(Boolean);
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

function excludeActor(recipients, actorUid) {
  return [...new Set((recipients || []).filter((uid) => {
    return typeof uid === "string" && uid.trim() && uid !== actorUid;
  }))];
}

module.exports = {
  bookingRecipientRoles,
  bookingStatusRecipients,
  excludeActor,
};
