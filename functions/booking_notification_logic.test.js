const assert = require("node:assert/strict");
const test = require("node:test");

const {
  bookingRecipientRoles,
  bookingStatusRecipients,
} = require("./booking_notification_logic");

const booking = {
  customerUid: "customer-1",
  ownerUid: "owner-1",
  barberUid: "barber-1",
};

test("booking changes notify customer, owner, and assigned barber", () => {
  for (const status of ["confirmed", "rejected"]) {
    assert.deepEqual(
      bookingStatusRecipients({}, {...booking, status}),
      ["customer-1", "owner-1", "barber-1"],
    );
  }
});

test("customer cancellation notifies salon owner and assigned barber", () => {
  assert.deepEqual(
    bookingStatusRecipients({}, {
      ...booking,
      status: "cancelled",
      cancelledBy: "customer",
    }),
    ["customer-1", "owner-1", "barber-1"],
  );
});

test("salon cancellation notifies customer and assigned barber", () => {
  assert.deepEqual(
    bookingStatusRecipients({}, {
      ...booking,
      status: "cancelled",
      cancelledBy: "salon",
    }),
    ["customer-1", "owner-1", "barber-1"],
  );
});

test("booking recipients are restricted to their active app role", () => {
  assert.deepEqual(bookingRecipientRoles(booking), {
    "customer-1": ["customer"],
    "owner-1": ["owner"],
    "barber-1": ["barber"],
  });
});
