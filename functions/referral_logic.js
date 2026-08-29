const crypto = require("node:crypto");

const REFERRAL_CODE_PATTERN = /^(?=.*[A-Z])(?=.*\d)[A-Z\d]{6}$/;
const REFERRAL_LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ";
const REFERRAL_DIGITS = "23456789";
const REFERRAL_ALPHABET = REFERRAL_LETTERS + REFERRAL_DIGITS;

function normalizeReferralCode(value) {
  const code = String(value ?? "").trim().toUpperCase();
  return REFERRAL_CODE_PATTERN.test(code) ? code : "";
}

function generateReferralCode(randomInt = crypto.randomInt) {
  const characters = [
    REFERRAL_LETTERS[randomInt(REFERRAL_LETTERS.length)],
    REFERRAL_DIGITS[randomInt(REFERRAL_DIGITS.length)],
  ];
  while (characters.length < 6) {
    characters.push(REFERRAL_ALPHABET[randomInt(REFERRAL_ALPHABET.length)]);
  }
  for (let index = characters.length - 1; index > 0; index -= 1) {
    const swapIndex = randomInt(index + 1);
    [characters[index], characters[swapIndex]] = [
      characters[swapIndex],
      characters[index],
    ];
  }
  return characters.join("");
}

function referralTargetAllowed(codeTargetRole, registeringRole) {
  return (codeTargetRole === "customer" || codeTargetRole === "owner") &&
    codeTargetRole === registeringRole;
}

function referralRewardSummary({
  programs = [],
  referrals = [],
  inviterUid = "",
  inviterRole = "",
  nowMillis = Date.now(),
} = {}) {
  const reward = {
    customerInviterRewardProin: 0,
    customerReferredRewardProin: 0,
    salonInviterRewardProin: 0,
    salonReferredRewardProin: 0,
    earnedCustomerReferralProin: 0,
    earnedSalonReferralProin: 0,
  };
  for (const program of programs) {
    const sourceType = String(program?.sourceType || "");
    const isCustomer = sourceType === "referral_customer";
    const isSalon = sourceType === "referral_salon";
    if ((!isCustomer && !isSalon) || program?.active !== true ||
        String(program?.referralInviterRole || "") !== inviterRole ||
        Number(program?.startsAtMillis || 0) > nowMillis ||
        Number(program?.endsAtMillis || 0) <= nowMillis) {
      continue;
    }
    const amount = Math.max(0, Math.trunc(Number(
      program?.rewardAmountProin || 0,
    )));
    if (amount <= 0) continue;
    const recipient = String(program?.rewardRecipient || "");
    if (recipient === "inviter") {
      reward[isCustomer ? "customerInviterRewardProin" :
        "salonInviterRewardProin"] += amount;
    } else if (recipient === "referred") {
      reward[isCustomer ? "customerReferredRewardProin" :
        "salonReferredRewardProin"] += amount;
    }
  }

  const uniqueReferrals = new Map();
  referrals.forEach((referral, index) => {
    const id = String(referral?.referralId || referral?.referredUid || index);
    uniqueReferrals.set(id, referral);
  });
  for (const referral of uniqueReferrals.values()) {
    const isSalon = referral?.referredRole === "owner";
    const awards = Array.isArray(referral?.proinAwards) ?
      referral.proinAwards : [];
    for (const award of awards) {
      const recipient = String(award?.recipient || "");
      const belongsToUser =
        (recipient === "inviter" && referral?.inviterUid === inviterUid) ||
        (recipient === "referred" && referral?.referredUid === inviterUid);
      if (!belongsToUser) continue;
      const amount = Math.max(0, Math.trunc(Number(award?.amountProin || 0)));
      reward[isSalon ? "earnedSalonReferralProin" :
        "earnedCustomerReferralProin"] += amount;
    }
  }
  return {
    ...reward,
    earnedReferralProin:
      reward.earnedCustomerReferralProin + reward.earnedSalonReferralProin,
  };
}

module.exports = {
  REFERRAL_CODE_PATTERN,
  generateReferralCode,
  normalizeReferralCode,
  referralRewardSummary,
  referralTargetAllowed,
};
