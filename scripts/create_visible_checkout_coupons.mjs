import readline from "node:readline/promises";

const projectId = "trimtime-46539";
const region = "us-central1";
const apiKey = "AIzaSyA5UaxhHMrHinDsz-XY1SK7KLpcwaV88_E";

async function callCallable(name, data, idToken) {
  const response = await fetch(
    `https://${region}-${projectId}.cloudfunctions.net/${name}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(idToken ? {Authorization: `Bearer ${idToken}`} : {}),
      },
      body: JSON.stringify({data}),
    },
  );
  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = {raw: text};
  }
  if (!response.ok || parsed.error) {
    const message =
      parsed.error?.message || parsed.raw || text || response.statusText;
    const code = parsed.error?.status || parsed.error?.code || response.status;
    throw new Error(`${name} failed (${code}): ${message}`);
  }
  return parsed.result ?? parsed.data ?? parsed;
}

const input = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
});
const credentials = JSON.parse(await input.question(""));
input.close();
const signIn = await callCallable("signInAdminWithPassword", {
  userId: credentials.userId,
  password: credentials.password,
});
const tokenResponse = await fetch(
  `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${apiKey}`,
  {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      token: signIn.customToken,
      returnSecureToken: true,
    }),
  },
);
const tokenPayload = await tokenResponse.json();
if (!tokenResponse.ok || tokenPayload.error) {
  throw new Error(
    `custom token exchange failed: ${
      tokenPayload.error?.message || tokenResponse.statusText
    }`,
  );
}
const idToken = tokenPayload.idToken;

const start = Date.now() - 5 * 60 * 1000;
const end = Date.now() + 14 * 24 * 60 * 60 * 1000;
const common = {
  active: true,
  voucherOnly: true,
  visibleAtCheckout: true,
  discountType: "percent",
  fixedDiscountAmount: 100,
  payoutMultiplier: 2,
  totalPayoutBudget: 5000,
  perSalonPayoutBudget: 1000,
  perCustomerPayoutBudget: 500,
  maximumUsesPerCustomer: 10,
  maximumDiscountAmount: 250,
  minimumServiceAmount: 0,
  startsAtMillis: start,
  endsAtMillis: end,
  salonIds: [],
  excludedSalonIds: [],
  customerUids: [],
  serviceIds: [],
  eligibleBookingNumbers: [],
  minimumBookingNumber: 1,
  maximumBookingNumber: 0,
  newToSalonOnly: false,
  returningToSalonOnly: false,
  termsVersion: "visible-checkout-test-v1",
};

await callCallable(
  "upsertDiscountCampaignAsAdmin",
  {
    ...common,
    campaignId: "visible_checkout_10_aug28",
    name: "Pritze Visible 10",
    priority: 40,
    voucherCode: "VISAUG10",
    discountPercent: 10,
    reason: "Create active visible checkout coupon offer for Android app verification.",
  },
  idToken,
);

await callCallable(
  "upsertDiscountCampaignAsAdmin",
  {
    ...common,
    campaignId: "visible_checkout_20_aug28",
    active: false,
    name: "Pritze Visible 20",
    priority: 50,
    voucherCode: "VISAUG20",
    discountPercent: 20,
    reason: "Disable oversized visible checkout test coupon that exceeds current vault coverage.",
  },
  idToken,
);

await callCallable(
  "upsertDiscountCampaignAsAdmin",
  {
    ...common,
    campaignId: "visible_checkout_05_aug28",
    name: "Pritze Visible 5",
    priority: 30,
    voucherCode: "VISAUG05",
    discountPercent: 5,
    reason: "Create active visible checkout coupon offer for Android app verification.",
  },
  idToken,
);

const adminData = await callCallable(
  "getDiscountAdministrationDataAsAdmin",
  {},
  idToken,
);
const created = adminData.campaigns
  .filter((campaign) =>
    [
      "visible_checkout_05_aug28",
      "visible_checkout_10_aug28",
      "visible_checkout_20_aug28",
    ].includes(campaign.campaignId),
  )
  .map((campaign) => ({
    id: campaign.campaignId,
    name: campaign.name,
    active: campaign.active,
    visibleAtCheckout: campaign.visibleAtCheckout,
    voucherOnly: campaign.voucherOnly,
    percent: campaign.discountPercent,
    masked: campaign.voucherMaskedCode,
  }));

console.log(JSON.stringify({created}, null, 2));
