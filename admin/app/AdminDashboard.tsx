"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getApps, initializeApp } from "firebase/app";
import {
  User,
  getAuth,
  onAuthStateChanged,
  signInWithCustomToken,
  signOut,
} from "firebase/auth";
import { getFunctions, httpsCallable } from "firebase/functions";

type View = "overview" | "intelligence" | "arrivals" | "bookings" | "customers" | "salons" | "barbers" | "reviews" | "settlements" | "discounts" | "proin" | "reports" | "activity" | "guide";
type BookingStatus = "pending" | "confirmed" | "inProgress" | "completed" | "cancelled" | "rejected";

type Booking = {
  id: string;
  customerUid: string;
  salonId: string;
  barberId: string;
  customerName: string;
  customerPhone: string;
  serviceName: string;
  servicePrice: number;
  durationMinutes: number;
  status: BookingStatus;
  isInstant: boolean;
  startMillis: number;
  createdAtMillis: number;
  acceptedAtMillis?: number;
  startedAtMillis?: number;
  completedAtMillis?: number;
  cancelledAtMillis?: number;
  rejectedAtMillis?: number;
  arrivalMinutes: number;
  cancellationReason: string;
  cancelledBy: string;
  arrivalStatus?: "notStarted" | "leavingNow" | "onTheWay" | "runningLate" | "arrived";
  arrivalStatusUpdatedAtMillis?: number;
  arrivalSharingActive?: boolean;
  arrivalSharingExpiresAtMillis?: number;
};

type ArrivalSession = {
  bookingId: string;
  salonId: string;
  sharingActive: boolean;
  latitude: number;
  longitude: number;
  hasLocation: boolean;
  accuracyMeters: number;
  distanceMeters: number;
  estimatedArrivalMinutes: number;
  hasSalonPin: boolean;
  lastLocationAtMillis: number;
  expiresAtMillis: number;
};

type Salon = {
  id: string;
  name: string;
  ownerUid?: string;
  ownerName: string;
  address: string;
  directionsUrl?: string;
  phone: string;
  email: string;
  logoUrl?: string;
  photoUrls?: string[];
  paymentUpiId?: string;
  paymentQrCodeUrl?: string;
  distanceLabel?: string;
  openTime: string;
  closeTime: string;
  isOpen: boolean;
  instantBookingsEnabled: boolean;
  rating: number;
  reviewCount: number;
  serviceCount: number;
  adminSuspended?: boolean;
  approvalStatus?: "pending" | "approved" | "rejected";
  approvalRequestedAtMillis?: number;
  approvalReviewedAtMillis?: number;
  approvalReviewReason?: string;
  proinReferralApproved?: boolean;
  instantBookingsPausedDate?: string;
  updatedAtMillis?: number;
  services?: SalonService[];
};

type SalonService = {
  id: string;
  name: string;
  category: string;
  price: number;
  durationMinutes: number;
  isAvailable: boolean;
  instantBookingEnabled: boolean;
};

type Barber = {
  id: string;
  uid?: string;
  salonId: string;
  name: string;
  phone: string;
  email: string;
  speciality: string;
  experienceYears: number;
  resumeSummary?: string;
  serviceIds?: string[];
  serviceCount: number;
  isActive: boolean;
};

type Customer = {
  id: string;
  name: string;
  phone: string;
  email: string;
  gender: string;
  birthDate: string;
  preferredStyles: string[];
  photoUrl?: string;
  stylePhotoUrls?: string[];
  provider?: string;
  adminSuspended?: boolean;
  referralOnboardingCompleted?: boolean;
  registeredAtMillis?: number;
  updatedAtMillis?: number;
  salonRating: number;
  salonRatingCount: number;
};

type Review = {
  id: string;
  bookingId: string;
  customerUid: string;
  salonId: string;
  salonName: string;
  rating: number;
  note: string;
  createdAtMillis: number;
  direction: "salon" | "customer";
};

type JoinRequest = {
  id: string;
  salonId: string;
  barberName: string;
  barberPhone: string;
  barberEmail: string;
  speciality: string;
  experienceYears: number;
  status: string;
  requestedAtMillis: number;
};

type Settlement = {
  bookingId: string;
  salonId: string;
  customerUid: string;
  campaignId: string;
  originalAmount: number;
  discountAmount: number;
  customerCounterAmount: number;
  pritzePayoutAmount: number;
  salonTotalEarning: number;
  status: string;
  paymentReference: string;
  paymentMethod: string;
  paidAmount: number;
  outstandingAmount: number;
  createdAtMillis: number;
  paidAtMillis: number;
};

type SalonSettlementPayment = {
  paymentId: string;
  salonId: string;
  amountInr: number;
  paymentReference: string;
  paymentMethod: string;
  paidAtMillis: number;
  createdAtMillis: number;
  allocationCount: number;
};

type SalonWallet = {
  salonId: string;
  payableBalance: number;
  paidAmount: number;
  lifetimePritzeEarnings: number;
};

type DiscountCampaign = {
  campaignId: string;
  name: string;
  active: boolean;
  priority: number;
  discountType: "percent" | "fixed";
  discountPercent: number;
  fixedDiscountAmount: number;
  voucherOnly: boolean;
  visibleAtCheckout: boolean;
  fundingSource: "salon_promotion_credits" | "platform_vault" | string;
  voucherCodeHash: string;
  voucherMaskedCode: string;
  payoutMultiplier: number;
  salonPayoutPercent: number;
  salonPayoutPercentByBookingNumber: Record<string, number>;
  cashbackProinAmount: number;
  cashbackValidityDays: number;
  cashbackTotalBudgetProin: number;
  cashbackProgramId: string;
  journeyCountScope: "platform" | "salon";
  journeyMilestones: JourneyMilestone[];
  totalPayoutBudget: number;
  maximumUsesPerCustomer: number;
  maximumDiscountAmount: number;
  minimumServiceAmount: number;
  perSalonPayoutBudget: number;
  perCustomerPayoutBudget: number;
  startsAtMillis: number;
  endsAtMillis: number;
  salonIds: string[];
  excludedSalonIds: string[];
  customerUids: string[];
  serviceIds: string[];
  eligibleBookingNumbers: number[];
  minimumBookingNumber: number;
  maximumBookingNumber: number;
  newToSalonOnly: boolean;
  returningToSalonOnly: boolean;
  termsVersion: string;
  version: number;
};

type JourneyMilestone = {
  bookingNumber: number;
  rewardType: "discount" | "discount_proin" | "proin";
  discountType: "percent" | "fixed" | "none";
  discountPercent: number;
  fixedDiscountAmount: number;
  maximumDiscountAmount: number;
  cashbackProinAmount: number;
  cashbackValidityDays: number;
};

type DiscountUsage = {
  campaignId?: string;
  salonId?: string;
  customerUid?: string;
  reservedPayoutAmount: number;
  realizedPayoutAmount: number;
  releasedPayoutAmount: number;
  reservedDiscountAmount: number;
  realizedDiscountAmount: number;
  releasedDiscountAmount: number;
  reservedUses: number;
  realizedUses: number;
  releasedUses: number;
};

type DiscountVault = {
  approvedAmount: number;
  availableAmount: number;
  reservedAmount: number;
  spentAmount: number;
  salonCreditLimitAmount: number;
  salonDiscountBurnMultiplier: number;
  budgetVersion: number;
};

type DiscountAdministrationData = {
  generatedAtMillis: number;
  campaigns: DiscountCampaign[];
  campaignUsage: DiscountUsage[];
  salonUsage: (DiscountUsage & { usageId: string; salonId: string })[];
  customerUsage: (DiscountUsage & { usageId: string; customerUid: string })[];
  salonTotals: (DiscountUsage & { salonId: string })[];
  customerTotals: (DiscountUsage & { customerUid: string })[];
  platformTotals: DiscountUsage;
  vault: DiscountVault;
};

type ProinWallet = {
  walletId: string;
  walletType: string;
  accountId: string;
  availableProin: number;
  reservedProin: number;
  creditLimitProin?: number;
  spendableProin?: number;
  lifetimeGrantedProin: number;
  lifetimeRedeemedProin: number;
  lifetimeExpiredProin: number;
  lifetimeRevokedProin: number;
  nextExpiryAtMillis: number;
};

type ProinLot = {
  lotId: string;
  walletId: string;
  walletType: string;
  accountId: string;
  programId: string;
  sourceType: string;
  status: string;
  originalProin: number;
  availableProin: number;
  reservedProin: number;
  redeemedProin: number;
  expiredProin: number;
  revokedProin: number;
  earnedAtMillis: number;
  expiresAtMillis: number;
};

type ProinProgram = {
  programId: string;
  name: string;
  sourceType: string;
  walletType: string;
  qualificationEvent: string;
  rewardRecipient: string;
  referralTargetRole: string;
  referralInviterRole: string;
  active: boolean;
  rewardAmountProin: number;
  rewardValidityDays: number;
  totalBudgetProin: number;
  maximumTotalGrants: number;
  maximumGrantsPerAccount: number;
  minimumBookingAmount: number;
  maximumProinPerBooking: number;
  maximumRedemptionPercent: number;
  stackableWithDiscount: boolean;
  eligibleSalonIds: string[];
  eligibleServiceIds: string[];
  termsVersion: string;
  startsAtMillis: number;
  endsAtMillis: number;
  version: number;
  systemManaged?: boolean;
  linkedDiscountCampaignId?: string;
};

type ProinProgramUsage = {
  programId: string;
  grantCount: number;
  grantedProin: number;
  availableProin: number;
  reservedProin: number;
  redeemedProin: number;
  expiredProin: number;
  revokedProin: number;
};

type ProinCoupon = {
  codeHash: string;
  maskedCode: string;
  programId: string;
  active: boolean;
  claimStartsAtMillis: number;
  claimEndsAtMillis: number;
  maximumClaimsTotal: number;
  maximumClaimsPerAccount: number;
  eligibleCustomerUids: string[];
  eligibleSalonIds: string[];
  termsVersion: string;
  version: number;
};

type ProinCouponUsage = {
  codeHash: string;
  reservedClaims: number;
  claimedCount: number;
};

type ReferralCode = {
  code: string;
  ownerUid: string;
  inviterRole: string;
  targetRole: string;
  active: boolean;
  replacedByCode: string;
  replacedFromCode: string;
  createdAtMillis: number;
  updatedAtMillis: number;
};

type ReferralRecord = {
  referralId: string;
  referredUid: string;
  referredRole: string;
  referralCode: string;
  inviterUid: string;
  inviterRole: string;
  status: string;
  qualificationType: string;
  qualificationBookingId: string;
  qualificationSalonId: string;
  proinAwardStatus: string;
  proinAwardPending: boolean;
  createdAtMillis: number;
  qualifiedAtMillis: number;
};

type ReferralStats = {
  userId: string;
  pendingCustomerCount: number;
  qualifiedCustomerCount: number;
  pendingSalonCount: number;
  qualifiedSalonCount: number;
  updatedAtMillis: number;
};

type ProinFinance = {
  approvedBudgetInr: number;
  unallocatedBudgetInr: number;
  outstandingLiabilityInr: number;
  reservedLiabilityInr: number;
  redeemedPayableInr: number;
  settledExpenseInr: number;
  lifetimeGrantedProin: number;
  lifetimeRedeemedProin: number;
  lifetimeExpiredProin: number;
  lifetimeRevokedProin: number;
};

type ProinReimbursement = {
  bookingId: string;
  salonId: string;
  amountInr: number;
  status: "payable" | "settled" | string;
  paymentReference: string;
  paymentMethod: string;
  paidAtMillis: number;
  createdAtMillis: number;
};

type ProinReconciliationReport = {
  reportId: string;
  status: "balanced" | "review_required" | string;
  walletMismatchCount: number;
  financeBalanced: boolean;
  financeMatchesLots: boolean;
  createdAtMillis: number;
};

type ProinTruncatedList = "programs" | "coupons" | "salonWallets" | "customerWallets" | "lots" | "payableReimbursements" | "settledReimbursements" | "referralCodes" | "referrals";

type ProinAdminData = {
  generatedAtMillis: number;
  truncated: Partial<Record<ProinTruncatedList, boolean>>;
  programs: ProinProgram[];
  programUsage: ProinProgramUsage[];
  coupons: ProinCoupon[];
  couponUsage: ProinCouponUsage[];
  referralCodes: ReferralCode[];
  referrals: ReferralRecord[];
  referralStats: ReferralStats[];
  wallets: ProinWallet[];
  lots: ProinLot[];
  finance: ProinFinance;
  reimbursements: ProinReimbursement[];
  reconciliationReports: ProinReconciliationReport[];
};

type AdminNote = {
  id: string;
  targetType: "booking" | "customer" | "salon" | "barber";
  targetId: string;
  note: string;
  adminUid: string;
  createdAtMillis: number;
};

type AuditLog = {
  id: string;
  action: string;
  targetType: string;
  targetId: string;
  reason: string;
  adminUid: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  createdAtMillis: number;
};

type AutomationRule = {
  id: "instant_response" | "overdue_arrival" | "unassigned_booking" | "cancellation_spike" | "low_rating";
  enabled: boolean;
  threshold: number;
  updatedAtMillis: number;
};

type OperationalAlert = {
  id: string;
  type: string;
  severity: "critical" | "warning" | "info";
  status: "active" | "acknowledged" | "resolved";
  targetType: string;
  targetId: string;
  salonId: string;
  title: string;
  detail: string;
  recommendedAction: string;
  detectedAtMillis: number;
  acknowledgedAtMillis: number;
  occurrenceCount: number;
};

type DecisionInsight = {
  id: string;
  category: "workload" | "anomaly" | "finance";
  severity: "warning" | "info";
  title: string;
  detail: string;
  recommendation: string;
};

type AdminActionField = {
  key: string;
  label: string;
  placeholder?: string;
  type?: "text" | "number" | "textarea" | "datetime-local" | "date" | "url" | "email" | "tel" | "select" | "checkbox-list" | "journey-milestones";
  initialValue?: string;
  min?: number;
  max?: number;
  required?: boolean;
  valueKind?: "boolean" | "string-list" | "number-list" | "booking-payout-rules" | "journey-milestones";
  step?: number;
  options?: { label: string; value: string }[];
};

type AdminAction = {
  title: string;
  description: string;
  confirmLabel: string;
  callableName: string;
  payload: Record<string, unknown>;
  fields: AdminActionField[];
  tone?: "default" | "danger";
};

const sharedFieldHelp: Record<string, string> = {
  reason: "Why this change is being made. Write the approval, campaign instruction, support ticket or business reason. This is saved in Admin activity.",
  active: "Controls whether customers or salons can actually use this object. Keep it No while testing; switch to Yes only after budget, dates and limits are checked.",
  termsVersion: "Internal policy label for the offer rules, for example discount-v1 or proin-v1. Use a new label when business terms change.",
};

const discountFieldHelp: Record<string, string> = {
  campaignId: "Unique ID for this discount campaign. Use a short lowercase name like first_visit_aug_2026. Create it here; later you can find it in the Discount campaigns table.",
  name: "Human-readable campaign name shown to admins and receipts. Use a name your team can recognize later.",
  priority: "If more than one automatic discount matches, the higher priority wins. Use bigger numbers for campaigns you want to take preference.",
  journeyCountScope: "Platform counts every completed Pritze booking by the customer. Salon counts only completed bookings at the eligible salon.",
  journeyMilestones: "Add each booking number that earns a reward. Every row can give a discount, Proin, or both. Booking numbers do not need to be consecutive.",
  voucherOnly: "Choose Automatic when the app applies the best eligible discount without a code. Choose Voucher when the campaign has a protected code, either hidden or visible at checkout.",
  visibleAtCheckout: "Hidden typed-code coupon means customers only get the benefit when someone tells them the code and they type it. Visible checkout offer means eligible customers see one tappable row below the final price before booking.",
  fundingSource: "Choose Salon promotional credits when salon campaigns should consume that salon's Proin balance first and then the approved ₹1,000 credit line. Choose Platform discount vault when Pritze centrally funds the payout.",
  voucherCode: "The customer-entered code, such as SAVE10. Use only letters and numbers, include at least one letter, and keep the original safely because stored codes are protected.",
  discountType: "Choose Percentage for offers like 10% off, or Fixed for a fixed rupee amount such as ₹50 off. A price discount cannot be zero because it must reduce the customer’s payable amount. Use Proin operations for a Proin-only reward, or add Proin cashback here to combine both.",
  discountPercent: "Customer discount percentage. Fill this when Discount type is Percentage; for example 10 means 10% off.",
  fixedDiscountAmount: "Fixed rupee discount. Fill this when Discount type is Fixed; it is ignored for percentage campaigns.",
  salonPayoutPercent: "How much the salon receives as a percentage of the customer's discount. Example: 100 means a ₹10 discount pays the salon ₹10; 0 means the salon receives nothing for that coupon use.",
  salonPayoutPercentByBookingNumber: "Optional booking-by-booking override. Enter pairs such as 1:100, 2:0, 3:2. This pays 100% of the discount on a customer's first booking, nothing on their second, and 2% on their third. Other bookings use the default compensation percentage.",
  cashbackProinAmount: "Optional Proin cashback earned after the service is completed. It is not added to the current booking; it becomes available for a future booking.",
  cashbackValidityDays: "How many days the cashback Proin remains available after it is awarded. Use 30 for a one-month reward.",
  cashbackTotalBudgetProin: "Total Proin reserved for this campaign's cashback rewards. Example: 1,000 with a ₹10 cashback allows up to 100 rewards, subject to the other limits.",
  salonDiscountBurnMultiplier: "Global multiplier for every new salon-funded discount. Example: 2 means a ₹10 customer discount reserves and deducts 20 Proin from the salon. Existing bookings keep their original reserved amount.",
  totalPayoutBudget: "Maximum rupee amount this campaign can cost Pritze. Find available capacity in the Discount vault cards above the table.",
  perSalonPayoutBudget: "Optional rupee cap per salon. Use 0 when there should be no per-salon cap.",
  perCustomerPayoutBudget: "Optional rupee cap per customer. Use 0 when there should be no per-customer cap.",
  maximumUsesPerCustomer: "Maximum number of bookings one customer can use this campaign on.",
  maximumDiscountAmount: "The maximum rupee discount this coupon or offer can give on one booking. For example, set 200 to ensure a 30% coupon never reduces a bill by more than ₹200.",
  minimumServiceAmount: "Minimum service total required before this discount can apply. Use 0 if every amount is eligible.",
  startsAtMillis: "When the campaign becomes eligible. Use local date and time. Leave empty only when the campaign should start immediately.",
  endsAtMillis: "When the campaign expires. Use a real end date for tests so old offers do not remain active accidentally.",
  salonIds: "Select the salons that can use this campaign. Leaving every salon unchecked makes it available across all eligible salons. The internal salon ID is shown beside each name for reference.",
  excludedSalonIds: "Optional block-list of salon document IDs that should never receive this campaign.",
  customerUids: "Optional allow-list of customer Firebase UIDs. Find them in Customers or Firebase Auth/Firestore. Leave blank for all eligible customers.",
  serviceIds: "Optional allow-list of service IDs. Use only when the discount should apply to selected services.",
  eligibleBookingNumbers: "Exact customer booking numbers, comma separated. Enter 3 to show this offer only when a customer is making their third booking. Enter 1, 3 to target their first and third bookings.",
  minimumBookingNumber: "Lowest customer booking number allowed. Use 1 for first booking onwards.",
  maximumBookingNumber: "Highest customer booking number allowed. Use 0 when there is no upper limit.",
  newToSalonOnly: "Use Yes when the customer must be visiting this salon for the first time.",
  returningToSalonOnly: "Use Yes when only customers who have already completed a booking at this salon are eligible.",
  approvedAmount: "Total approved rupee budget available for all discount campaigns. It cannot be lower than money already reserved or spent.",
  salonCreditLimitAmount: "Maximum negative promotional Proin balance each salon may use for salon-funded discount campaigns. Default is 1000, which means a salon can spend down to -1000 Proin.",
};

const proinFieldHelp: Record<string, string> = {
  approvedBudgetInr: "Total real-money budget behind Proin rewards and salon reimbursements. It cannot be reduced below outstanding or already settled obligations.",
  programId: "Unique ID for this reward program. Use a lowercase name like customer_referrer_2026. Coupon codes link to this ID.",
  name: "Human-readable program name for admins, reports and audit trails.",
  sourceType: "Where the Proin comes from: referral, coupon, promotion or manual support grant.",
  walletType: "Choose Customer rewards for customer Proin, or Salon promotion credits for salon-side promotional credit.",
  qualificationEvent: "The event that earns the reward. Referrals usually wait for a completed booking; coupon programs use Coupon claimed.",
  rewardRecipient: "Who receives the reward: the claiming account, the referral inviter, or the referred account.",
  referralInviterRole: "Required only for referral programs. Customer referrals use Customer; salon referrals use Salon owner.",
  rewardAmountProin: "How much Proin is granted each time this program qualifies.",
  rewardValidityDays: "How many days the granted Proin stays usable before expiry.",
  totalBudgetProin: "Maximum Proin this program can grant in total. Keep test programs small first.",
  maximumTotalGrants: "Maximum number of reward grants across the whole program.",
  maximumGrantsPerAccount: "Maximum number of times one customer or salon can receive this program's reward. For referral-inviter programs, this also limits how many pending + qualified invites can use that account's referral code.",
  minimumBookingAmount: "Minimum booking value required for rewards or redemption. Use 0 when no minimum is needed.",
  maximumProinPerBooking: "Maximum Proin that can be used on one booking from this program.",
  maximumRedemptionPercent: "Maximum percentage of the payable booking value that Proin can cover. Example: 25 means at most 25%.",
  stackableWithDiscount: "Whether this Proin can be used together with another discount campaign on the same booking.",
  eligibleSalonIds: "Optional salon document IDs that this program applies to. Leave blank to allow all eligible salons.",
  eligibleServiceIds: "Optional service IDs that this program applies to. Leave blank to allow all eligible services.",
  code: "The coupon code users type, such as WELCOME50 or SALON100. Keep the original safely because the database stores only a protected hash and masked label.",
  programIdCoupon: "The coupon-source Proin program this code uses. Create a coupon program first, then select it here.",
  claimStartsAtMillis: "When this coupon can first be claimed.",
  claimEndsAtMillis: "When this coupon stops accepting claims. Use an expiry for every campaign.",
  maximumClaimsTotal: "Maximum number of total successful claims for this coupon code.",
  eligibleCustomerUids: "Optional customer UID allow-list. Leave blank when any eligible customer may claim.",
  eligibleSalonIdsCoupon: "Optional salon ID allow-list. Leave blank when any eligible salon may claim.",
  accountId: "The customer UID or salon ID receiving a manual Proin grant. Find it in Customers, Salons or Firebase.",
  sourceId: "Support case, campaign note or approval reference for a manual grant.",
  idempotencyKey: "Unique key that prevents accidental duplicate grants. Use something like support-case-123:customer-uid.",
  paymentMethod: "Choose how Pritze paid the salon: bank transfer, UPI, or cash. Cash still requires a receipt or ledger reference for the audit trail.",
  paymentReference: "For bank transfer or UPI, enter the completed transaction reference. For cash, enter the cash receipt or ledger reference after payment has been made.",
  paidAtMillis: "Date and time when the external reimbursement payment was completed.",
  amountProin: "For a manual grant, this is the Proin amount to add within the selected program's limit. For a revocation, it is the unused Proin amount to remove from the selected reward lot.",
  currentCode: "The referral code currently assigned to this customer or salon. This identifies the code being edited.",
  newCode: "The new 6-character referral code. It must include at least one letter and one number, and it cannot already be assigned to another account.",
};

const profileFieldHelp: Record<string, string> = {
  name: "The public customer or salon name shown in the app. Changes appear after the app refreshes.",
  ownerName: "The salon owner's public name shown with the salon listing.",
  phone: "Use +91 followed by exactly 10 digits. Phone ownership is checked so the same number cannot belong to a customer and salon owner.",
  email: "Contact email stored on the profile. This does not replace a Google sign-in identity.",
  gender: "Optional customer profile value. Leave blank when the customer has not supplied it.",
  birthDate: "Optional customer birth date. Future dates and dates before 1920 are rejected.",
  preferredStyles: "One preferred style per line, up to 12. These appear in the customer's editable profile.",
  photoUrl: "Optional secure https link to the customer's profile picture.",
  stylePhotoUrls: "Optional secure https links to preferred-style photos, one per line, up to 8.",
  address: "The full public salon address displayed to customers.",
  directionsUrl: "Optional secure Google Maps or directions link opened by the Directions button.",
  logoUrl: "Optional secure https link to the salon logo.",
  photoUrls: "Secure https salon photo links, one per line, up to 8. The first image is used as the cover.",
  distanceLabel: "Short customer-facing location hint such as College Road or Nearby.",
  openTime: "Opening time in a standard format such as 9:00 AM.",
  closeTime: "Closing time in a standard format such as 8:30 PM; it must be after opening time.",
  category: "Service category used to choose the matching service icon and organize the menu.",
  price: "Customer-facing service amount in rupees.",
  durationMinutes: "Expected service duration in minutes, from 5 to 480.",
  isAvailable: "Whether customers can currently schedule this service.",
  instantBookingEnabled: "Whether this service can be chosen in instant booking.",
  speciality: "The barber's main skills shown to the salon team.",
  experienceYears: "Completed years of professional experience.",
  resumeSummary: "Optional internal/public summary of the barber's experience, up to 1,000 characters.",
  serviceIds: "Service IDs this barber can perform, one per line. Find them under the salon service list.",
};

const salonFinanceFieldHelp: Record<string, string> = {
  creditLimitProin: "The maximum negative promotional Proin balance permitted for this one salon. For example, 2000 allows this salon to spend down to -2000 Proin.",
  amountProin: "The exact promotional Proin credit to add. The selected manual program supplies its expiry and maximum allowed reward.",
  sourceId: "A short internal note or source reference for this credit, such as a campaign top-up or support case.",
  idempotencyKey: "A unique reference that prevents the same promotional credit from being added twice.",
  amountInr: "The amount already paid to this salon outside Pritze. It cannot exceed the current pending settlement balance.",
  paymentMethod: "Choose the real-world payment method. Cash requires a cash receipt or ledger reference so the settlement remains auditable.",
  paymentReference: "Enter the completed bank/UPI transaction reference, or a cash receipt or ledger reference. Pritze does not initiate this transfer.",
  paidAtMillis: "When the external payment was completed. The payment is allocated against the oldest unsettled booking records first.",
};

function adminActionFieldHelp(action: AdminAction, field: AdminActionField) {
  if (sharedFieldHelp[field.key]) return sharedFieldHelp[field.key];
  if (["updateCustomerProfileAsAdmin", "updateSalonProfileAsAdmin", "updateSalonServiceAsAdmin", "updateBarberProfileAsAdmin"].includes(action.callableName)) {
    return profileFieldHelp[field.key] ?? "";
  }
  if (action.callableName === "upsertDiscountCampaignAsAdmin" || action.callableName === "setDiscountVaultBudgetAsAdmin") {
    return discountFieldHelp[field.key] ?? "";
  }
  if (["setSalonPromotionCreditLimitAsAdmin", "recordSalonSettlementPaymentAsAdmin"].includes(action.callableName)) {
    return salonFinanceFieldHelp[field.key] ?? "";
  }
  if (action.callableName === "upsertProinCouponAsAdmin") {
    if (field.key === "programId") return proinFieldHelp.programIdCoupon;
    if (field.key === "eligibleSalonIds") return proinFieldHelp.eligibleSalonIdsCoupon;
    return proinFieldHelp[field.key] ?? "";
  }
  if (action.callableName === "upsertProinProgramAsAdmin" || action.callableName === "setProinFinanceBudgetAsAdmin" || action.callableName === "grantProinAsAdmin" || action.callableName === "markProinReimbursementSettledAsAdmin" || action.callableName === "revokeProinAsAdmin" || action.callableName === "updateReferralCodeAsAdmin") {
    return proinFieldHelp[field.key] ?? "";
  }
  return "";
}

type AdminData = {
  generatedAtMillis: number;
  bookings: Booking[];
  salons: Salon[];
  barbers: Barber[];
  customers: Customer[];
  reviews: Review[];
  joinRequests: JoinRequest[];
  settlements: Settlement[];
  settlementPayments: SalonSettlementPayment[];
  wallets: SalonWallet[];
  notes: AdminNote[];
  auditLogs: AuditLog[];
  automationRules: AutomationRule[];
  operationalAlerts: OperationalAlert[];
  arrivalSessions: ArrivalSession[];
};

const firebaseConfig = {
  projectId: "trimtime-46539",
  appId: "1:3474382418:web:8a8edc880a258d9d8c498b",
  storageBucket: "trimtime-46539.firebasestorage.app",
  apiKey: "AIzaSyA5UaxhHMrHinDsz-XY1SK7KLpcwaV88_E",
  authDomain: "trimtime-46539.firebaseapp.com",
  messagingSenderId: "3474382418",
};

// Keep the representative server-rendered snapshot deterministic. Live data
// and the operational clock switch to the current time after hydration.
const now = Date.parse("2026-08-21T14:00:00.000Z");
const minute = 60_000;
const hour = 60 * minute;
const day = 24 * hour;

const sampleData: AdminData = {
  generatedAtMillis: now,
  arrivalSessions: [
    { bookingId: "BK-1042", salonId: "salon-1", sharingActive: true, latitude: 20.0042, longitude: 73.7897, hasLocation: true, accuracyMeters: 18, distanceMeters: 1350, estimatedArrivalMinutes: 6, hasSalonPin: true, lastLocationAtMillis: now - minute, expiresAtMillis: now + 39 * minute },
  ],
  settlements: [],
  settlementPayments: [],
  wallets: [],
  notes: [
    { id: "note-1", targetType: "booking", targetId: "BK-1042", note: "Customer requested a quiet appointment; salon informed.", adminUid: "admin-preview", createdAtMillis: now - 35 * minute },
  ],
  auditLogs: [
    { id: "audit-1", action: "salon.instantBookingsEnabled", targetType: "salon", targetId: "salon-3", reason: "Salon requested a temporary pause during staff shortage.", adminUid: "admin-preview", before: { instantBookingsEnabled: true }, after: { instantBookingsEnabled: false }, createdAtMillis: now - 2 * hour },
  ],
  automationRules: [
    { id: "instant_response", enabled: true, threshold: 2, updatedAtMillis: 0 },
    { id: "overdue_arrival", enabled: true, threshold: 10, updatedAtMillis: 0 },
    { id: "unassigned_booking", enabled: true, threshold: 5, updatedAtMillis: 0 },
    { id: "cancellation_spike", enabled: true, threshold: 30, updatedAtMillis: 0 },
    { id: "low_rating", enabled: true, threshold: 3.5, updatedAtMillis: 0 },
  ],
  operationalAlerts: [
    { id: "alert-1", type: "instant_response", severity: "critical", status: "active", targetType: "booking", targetId: "BK-1044", salonId: "salon-3", title: "Instant request needs a decision", detail: "Waiting 3 minutes.", recommendedAction: "Accept or reject the request after checking capacity.", detectedAtMillis: now - 2 * minute, acknowledgedAtMillis: 0, occurrenceCount: 1 },
    { id: "alert-2", type: "unassigned_booking", severity: "warning", status: "active", targetType: "booking", targetId: "BK-1044", salonId: "salon-3", title: "Booking has no assigned barber", detail: "The booking is active but no team member is attached.", recommendedAction: "Review the salon workload and assign an eligible barber.", detectedAtMillis: now - minute, acknowledgedAtMillis: 0, occurrenceCount: 1 },
  ],
  salons: [
    { id: "salon-1", ownerUid: "salon-owner-1", name: "The Groom Room", ownerName: "Aditya More", address: "College Road, Nashik", phone: "+91 98220 41020", email: "hello@groomroom.in", openTime: "09:00", closeTime: "20:00", isOpen: true, instantBookingsEnabled: true, rating: 4.8, reviewCount: 126, serviceCount: 12, services: [{ id: "haircut", name: "Classic haircut", category: "Hair", price: 450, durationMinutes: 35, isAvailable: true, instantBookingEnabled: true }, { id: "beard", name: "Beard styling", category: "Grooming", price: 350, durationMinutes: 25, isAvailable: true, instantBookingEnabled: true }] },
    { id: "salon-2", name: "Aura Salon", ownerName: "Sakshi Deshmukh", address: "Gangapur Road, Nashik", phone: "+91 97662 11883", email: "care@aurasalon.in", openTime: "10:00", closeTime: "21:00", isOpen: true, instantBookingsEnabled: true, rating: 4.7, reviewCount: 94, serviceCount: 16 },
    { id: "salon-3", name: "Studio Eleven", ownerName: "Nikhil Jadhav", address: "Indira Nagar, Nashik", phone: "+91 93721 50018", email: "studio11@example.in", openTime: "09:30", closeTime: "20:30", isOpen: true, instantBookingsEnabled: false, rating: 4.5, reviewCount: 68, serviceCount: 9 },
    { id: "salon-4", name: "Copper & Comb", ownerName: "Isha Kulkarni", address: "Canada Corner, Nashik", phone: "+91 90110 84021", email: "hello@coppercomb.in", openTime: "10:00", closeTime: "19:30", isOpen: false, instantBookingsEnabled: false, rating: 4.6, reviewCount: 51, serviceCount: 11 },
  ],
  barbers: [
    { id: "barber-1", salonId: "salon-1", name: "Rohan Pawar", phone: "+91 98501 22041", email: "rohan@example.in", speciality: "Hair & beard styling", experienceYears: 6, serviceCount: 7, isActive: true },
    { id: "barber-2", salonId: "salon-2", name: "Priya Salunke", phone: "+91 97644 11229", email: "priya@example.in", speciality: "Hair spa & colour", experienceYears: 5, serviceCount: 8, isActive: true },
    { id: "barber-3", salonId: "salon-2", name: "Neha Patil", phone: "+91 98231 09871", email: "neha@example.in", speciality: "Skin & facial care", experienceYears: 4, serviceCount: 6, isActive: true },
    { id: "barber-4", salonId: "salon-3", name: "Sahil Shinde", phone: "+91 99218 60311", email: "sahil@example.in", speciality: "Classic grooming", experienceYears: 3, serviceCount: 5, isActive: false },
  ],
  customers: [
    { id: "customer-1", name: "Aarav Patil", phone: "+91 98765 42110", email: "aarav@example.in", gender: "man", birthDate: "1996-04-18", preferredStyles: ["Low fade", "Beard trim"], salonRating: 4.8, salonRatingCount: 9 },
    { id: "customer-2", name: "Meera Shah", phone: "+91 98204 11338", email: "meera@example.in", gender: "woman", birthDate: "1998-11-02", preferredStyles: ["Layered cut", "Hair spa"], salonRating: 4.9, salonRatingCount: 6 },
    { id: "customer-3", name: "Kabir Joshi", phone: "+91 98901 44327", email: "kabir@example.in", gender: "man", birthDate: "1994-07-24", preferredStyles: ["Classic haircut"], salonRating: 4.3, salonRatingCount: 4 },
    { id: "customer-4", name: "Riya Kulkarni", phone: "+91 97654 16024", email: "riya@example.in", gender: "woman", birthDate: "2000-01-11", preferredStyles: ["Facial", "Threading"], salonRating: 4.7, salonRatingCount: 8 },
    { id: "customer-5", name: "Vedant More", phone: "+91 94219 77382", email: "vedant@example.in", gender: "man", birthDate: "1992-09-08", preferredStyles: ["Beard styling"], salonRating: 4.2, salonRatingCount: 3 },
  ],
  bookings: [
    { id: "BK-1042", customerUid: "customer-1", salonId: "salon-1", barberId: "barber-1", customerName: "Aarav Patil", customerPhone: "+91 98765 42110", serviceName: "Haircut + Beard", servicePrice: 650, durationMinutes: 55, status: "confirmed", isInstant: true, startMillis: now + 8 * minute, createdAtMillis: now - 10 * minute, acceptedAtMillis: now - 7 * minute, arrivalMinutes: 15, cancellationReason: "", cancelledBy: "", arrivalStatus: "onTheWay", arrivalStatusUpdatedAtMillis: now - minute, arrivalSharingActive: true, arrivalSharingExpiresAtMillis: now + 39 * minute },
    { id: "BK-1043", customerUid: "customer-2", salonId: "salon-2", barberId: "barber-2", customerName: "Meera Shah", customerPhone: "+91 98204 11338", serviceName: "Hair spa", servicePrice: 1200, durationMinutes: 60, status: "confirmed", isInstant: false, startMillis: now + 18 * minute, createdAtMillis: now - 2 * day, arrivalMinutes: 0, cancellationReason: "", cancelledBy: "" },
    { id: "BK-1044", customerUid: "customer-3", salonId: "salon-3", barberId: "", customerName: "Kabir Joshi", customerPhone: "+91 98901 44327", serviceName: "Classic haircut", servicePrice: 400, durationMinutes: 35, status: "pending", isInstant: true, startMillis: now + 12 * minute, createdAtMillis: now - 3 * minute, arrivalMinutes: 15, cancellationReason: "", cancelledBy: "" },
    { id: "BK-1040", customerUid: "customer-4", salonId: "salon-2", barberId: "barber-3", customerName: "Riya Kulkarni", customerPhone: "+91 97654 16024", serviceName: "Facial", servicePrice: 900, durationMinutes: 45, status: "inProgress", isInstant: false, startMillis: now - 20 * minute, createdAtMillis: now - 3 * day, startedAtMillis: now - 18 * minute, arrivalMinutes: 0, cancellationReason: "", cancelledBy: "" },
    { id: "BK-1039", customerUid: "customer-5", salonId: "salon-1", barberId: "barber-1", customerName: "Vedant More", customerPhone: "+91 94219 77382", serviceName: "Beard styling", servicePrice: 350, durationMinutes: 25, status: "completed", isInstant: false, startMillis: now - 2 * hour, createdAtMillis: now - 5 * day, completedAtMillis: now - 90 * minute, arrivalMinutes: 0, cancellationReason: "", cancelledBy: "" },
    { id: "BK-1036", customerUid: "customer-2", salonId: "salon-2", barberId: "barber-2", customerName: "Meera Shah", customerPhone: "+91 98204 11338", serviceName: "Hair colour", servicePrice: 2200, durationMinutes: 90, status: "completed", isInstant: false, startMillis: now - day, createdAtMillis: now - 8 * day, completedAtMillis: now - day + 95 * minute, arrivalMinutes: 0, cancellationReason: "", cancelledBy: "" },
    { id: "BK-1032", customerUid: "customer-3", salonId: "salon-3", barberId: "barber-4", customerName: "Kabir Joshi", customerPhone: "+91 98901 44327", serviceName: "Haircut", servicePrice: 450, durationMinutes: 35, status: "cancelled", isInstant: false, startMillis: now - 3 * day, createdAtMillis: now - 10 * day, cancelledAtMillis: now - 4 * day, arrivalMinutes: 0, cancellationReason: "Plans changed", cancelledBy: "customer" },
  ],
  reviews: [
    { id: "review-1", bookingId: "BK-1039", customerUid: "customer-5", salonId: "salon-1", salonName: "The Groom Room", rating: 5, note: "Excellent service and very punctual.", createdAtMillis: now - hour, direction: "salon" },
    { id: "review-2", bookingId: "BK-1036", customerUid: "customer-2", salonId: "salon-2", salonName: "Aura Salon", rating: 4, note: "Loved the colour. Waiting time could be shorter.", createdAtMillis: now - day, direction: "salon" },
    { id: "review-3", bookingId: "BK-1039", customerUid: "customer-5", salonId: "salon-1", salonName: "The Groom Room", rating: 5, note: "Arrived on time and was courteous.", createdAtMillis: now - 80 * minute, direction: "customer" },
  ],
  joinRequests: [
    { id: "join-1", salonId: "salon-1", barberName: "Aniket Wagh", barberPhone: "+91 93704 22189", barberEmail: "aniket@example.in", speciality: "Modern fades", experienceYears: 3, status: "pending", requestedAtMillis: now - 4 * hour },
    { id: "join-2", salonId: "salon-2", barberName: "Pooja Sonawane", barberPhone: "+91 97644 01928", barberEmail: "pooja@example.in", speciality: "Hair colour", experienceYears: 5, status: "approved", requestedAtMillis: now - 2 * day },
  ],
};

const sampleDiscountData: DiscountAdministrationData = {
  generatedAtMillis: now,
  campaigns: [
    { campaignId: "first_visit_2026", name: "First visit 10%", active: false, priority: 100, discountType: "percent", discountPercent: 10, fixedDiscountAmount: 0, voucherOnly: false, visibleAtCheckout: false, fundingSource: "salon_promotion_credits", voucherCodeHash: "", voucherMaskedCode: "", payoutMultiplier: 2, salonPayoutPercent: 200, salonPayoutPercentByBookingNumber: { "1": 200, "2": 0, "3": 2 }, cashbackProinAmount: 0, cashbackValidityDays: 30, cashbackTotalBudgetProin: 0, cashbackProgramId: "", journeyCountScope: "platform", journeyMilestones: [], totalPayoutBudget: 50000, maximumUsesPerCustomer: 1, maximumDiscountAmount: 250, minimumServiceAmount: 100, perSalonPayoutBudget: 5000, perCustomerPayoutBudget: 500, startsAtMillis: now - day, endsAtMillis: now + 30 * day, salonIds: [], excludedSalonIds: [], customerUids: [], serviceIds: [], eligibleBookingNumbers: [1], minimumBookingNumber: 1, maximumBookingNumber: 1, newToSalonOnly: false, returningToSalonOnly: false, termsVersion: "discount-v1", version: 1 },
  ],
  campaignUsage: [{ campaignId: "first_visit_2026", reservedPayoutAmount: 200, realizedPayoutAmount: 1200, releasedPayoutAmount: 100, reservedDiscountAmount: 100, realizedDiscountAmount: 600, releasedDiscountAmount: 50, reservedUses: 2, realizedUses: 12, releasedUses: 1 }],
  salonUsage: [],
  customerUsage: [],
  salonTotals: [{ salonId: "salon-1", reservedPayoutAmount: 100, realizedPayoutAmount: 800, releasedPayoutAmount: 0, reservedDiscountAmount: 50, realizedDiscountAmount: 400, releasedDiscountAmount: 0, reservedUses: 1, realizedUses: 8, releasedUses: 0 }],
  customerTotals: [{ customerUid: "customer-1", reservedPayoutAmount: 100, realizedPayoutAmount: 200, releasedPayoutAmount: 0, reservedDiscountAmount: 50, realizedDiscountAmount: 100, releasedDiscountAmount: 0, reservedUses: 1, realizedUses: 2, releasedUses: 0 }],
  platformTotals: { reservedPayoutAmount: 200, realizedPayoutAmount: 1200, releasedPayoutAmount: 100, reservedDiscountAmount: 100, realizedDiscountAmount: 600, releasedDiscountAmount: 50, reservedUses: 2, realizedUses: 12, releasedUses: 1 },
  vault: { approvedAmount: 100000, availableAmount: 98600, reservedAmount: 200, spentAmount: 1200, salonCreditLimitAmount: 1000, salonDiscountBurnMultiplier: 2, budgetVersion: 1 },
};

const sampleProinData: ProinAdminData = {
  generatedAtMillis: now,
  truncated: {},
  programs: [
    { programId: "customer_referral", name: "Customer referral reward", sourceType: "referral_customer", walletType: "customer_rewards", qualificationEvent: "first_completed_booking", rewardRecipient: "inviter", referralTargetRole: "customer", referralInviterRole: "customer", active: false, rewardAmountProin: 100, rewardValidityDays: 60, totalBudgetProin: 10000, maximumTotalGrants: 100, maximumGrantsPerAccount: 10, minimumBookingAmount: 0, maximumProinPerBooking: 100, maximumRedemptionPercent: 25, stackableWithDiscount: false, eligibleSalonIds: [], eligibleServiceIds: [], termsVersion: "referral-v1", startsAtMillis: now - day, endsAtMillis: now + 60 * day, version: 1 },
    { programId: "coupon_welcome", name: "Welcome coupon", sourceType: "coupon", walletType: "customer_rewards", qualificationEvent: "coupon_claimed", rewardRecipient: "account", referralTargetRole: "", referralInviterRole: "", active: false, rewardAmountProin: 50, rewardValidityDays: 30, totalBudgetProin: 5000, maximumTotalGrants: 100, maximumGrantsPerAccount: 1, minimumBookingAmount: 0, maximumProinPerBooking: 50, maximumRedemptionPercent: 25, stackableWithDiscount: false, eligibleSalonIds: [], eligibleServiceIds: [], termsVersion: "coupon-v1", startsAtMillis: now - day, endsAtMillis: now + 30 * day, version: 1 },
  ],
  programUsage: [
    { programId: "customer_referral", grantCount: 1, grantedProin: 120, availableProin: 100, reservedProin: 20, redeemedProin: 0, expiredProin: 0, revokedProin: 0 },
    { programId: "coupon_welcome", grantCount: 1, grantedProin: 105, availableProin: 80, reservedProin: 0, redeemedProin: 25, expiredProin: 0, revokedProin: 0 },
  ],
  coupons: [
    { codeHash: "preview-coupon", maskedCode: "WE••••50", programId: "coupon_welcome", active: false, claimStartsAtMillis: now - day, claimEndsAtMillis: now + 14 * day, maximumClaimsTotal: 100, maximumClaimsPerAccount: 1, eligibleCustomerUids: [], eligibleSalonIds: [], termsVersion: "coupon-v1", version: 1 },
  ],
  couponUsage: [{ codeHash: "preview-coupon", reservedClaims: 0, claimedCount: 1 }],
  referralCodes: [
    { code: "A7K2PX", ownerUid: "customer-1", inviterRole: "customer", targetRole: "customer", active: true, replacedByCode: "", replacedFromCode: "", createdAtMillis: now - 10 * day, updatedAtMillis: 0 },
    { code: "S5N8QZ", ownerUid: "salon-owner-1", inviterRole: "owner", targetRole: "customer", active: true, replacedByCode: "", replacedFromCode: "", createdAtMillis: now - 8 * day, updatedAtMillis: 0 },
    { code: "B4M6RT", ownerUid: "salon-owner-1", inviterRole: "owner", targetRole: "owner", active: false, replacedByCode: "C8P2LA", replacedFromCode: "", createdAtMillis: now - 8 * day, updatedAtMillis: now - day },
  ],
  referrals: [
    { referralId: "customer-2", referredUid: "customer-2", referredRole: "customer", referralCode: "A7K2PX", inviterUid: "customer-1", inviterRole: "customer", status: "qualified", qualificationType: "first_completed_booking", qualificationBookingId: "BK-1036", qualificationSalonId: "", proinAwardStatus: "awarded", proinAwardPending: false, createdAtMillis: now - 7 * day, qualifiedAtMillis: now - day },
  ],
  referralStats: [
    { userId: "customer-1", pendingCustomerCount: 1, qualifiedCustomerCount: 1, pendingSalonCount: 0, qualifiedSalonCount: 0, updatedAtMillis: now - day },
    { userId: "salon-owner-1", pendingCustomerCount: 0, qualifiedCustomerCount: 0, pendingSalonCount: 1, qualifiedSalonCount: 0, updatedAtMillis: now - day },
  ],
  finance: {
    approvedBudgetInr: 100000,
    unallocatedBudgetInr: 99755,
    outstandingLiabilityInr: 200,
    reservedLiabilityInr: 20,
    redeemedPayableInr: 25,
    settledExpenseInr: 0,
    lifetimeGrantedProin: 245,
    lifetimeRedeemedProin: 25,
    lifetimeExpiredProin: 0,
    lifetimeRevokedProin: 0,
  },
  wallets: [
    { walletId: "preview-wallet-1", walletType: "customer_rewards", accountId: "customer-1", availableProin: 120, reservedProin: 20, lifetimeGrantedProin: 140, lifetimeRedeemedProin: 0, lifetimeExpiredProin: 0, lifetimeRevokedProin: 0, nextExpiryAtMillis: now + 25 * day },
    { walletId: "preview-wallet-2", walletType: "customer_rewards", accountId: "customer-2", availableProin: 80, reservedProin: 0, lifetimeGrantedProin: 105, lifetimeRedeemedProin: 25, lifetimeExpiredProin: 0, lifetimeRevokedProin: 0, nextExpiryAtMillis: now + 18 * day },
  ],
  lots: [
    { lotId: "preview-lot-1", walletId: "preview-wallet-1", walletType: "customer_rewards", accountId: "customer-1", programId: "customer_referral", sourceType: "referral_customer", status: "active", originalProin: 120, availableProin: 100, reservedProin: 20, redeemedProin: 0, expiredProin: 0, revokedProin: 0, earnedAtMillis: now - 5 * day, expiresAtMillis: now + 25 * day },
    { lotId: "preview-lot-2", walletId: "preview-wallet-2", walletType: "customer_rewards", accountId: "customer-2", programId: "coupon_welcome", sourceType: "coupon", status: "active", originalProin: 105, availableProin: 80, reservedProin: 0, redeemedProin: 25, expiredProin: 0, revokedProin: 0, earnedAtMillis: now - 12 * day, expiresAtMillis: now + 18 * day },
  ],
  reimbursements: [
    { bookingId: "BK-PROIN-102", salonId: "salon-1", amountInr: 25, status: "payable", paymentReference: "", paymentMethod: "", paidAtMillis: 0, createdAtMillis: now - 2 * hour },
  ],
  reconciliationReports: [
    { reportId: "preview-report", status: "balanced", walletMismatchCount: 0, financeBalanced: true, financeMatchesLots: true, createdAtMillis: now - hour },
  ],
};

const navItems: { id: View; label: string; icon: string }[] = [
  { id: "overview", label: "Overview", icon: "⌂" },
  { id: "intelligence", label: "Intelligence", icon: "✦" },
  { id: "arrivals", label: "Live arrivals", icon: "⌖" },
  { id: "bookings", label: "Live bookings", icon: "▦" },
  { id: "customers", label: "Customers", icon: "◎" },
  { id: "salons", label: "Salons", icon: "◇" },
  { id: "barbers", label: "Barbers", icon: "♙" },
  { id: "reviews", label: "Reviews", icon: "☆" },
  { id: "settlements", label: "Settlements", icon: "₹" },
  { id: "discounts", label: "Discount control", icon: "%" },
  { id: "proin", label: "Proin operations", icon: "◉" },
  { id: "reports", label: "Reports", icon: "↗" },
  { id: "activity", label: "Admin activity", icon: "◷" },
  { id: "guide", label: "How to use", icon: "?" },
];

function getFirebaseServices() {
  const app = getApps()[0] ?? initializeApp(firebaseConfig);
  // Must match the backend region. setGlobalOptions in functions/index.js
  // pins every callable to asia-south1; the default us-central1 copies are
  // leftovers from before that move and run stale code.
  return { auth: getAuth(app), functions: getFunctions(app, "asia-south1") };
}

function initials(value: string) {
  return value.split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "?";
}

function titleCase(value: string) {
  if (value === "inProgress") return "In service";
  return value ? value[0].toUpperCase() + value.slice(1) : "Unknown";
}

function arrivalStatusText(value: Booking["arrivalStatus"]) {
  return ({ notStarted: "Not started", leavingNow: "Leaving now", onTheWay: "On the way", runningLate: "Running late", arrived: "Arrived" } as const)[value ?? "notStarted"];
}

function formatMoney(value: number) {
  return new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(value);
}

function formatProin(value: number) {
  return `${new Intl.NumberFormat("en-IN", { maximumFractionDigits: 0 }).format(value)} Proin`;
}

function formatSettlementPaymentMethod(value: string) {
  if (value === "upi") return "UPI";
  if (value === "cash") return "Cash";
  return "Bank transfer";
}

function dateTimeLocalValue(value: number) {
  const date = new Date(value);
  const local = new Date(value - date.getTimezoneOffset() * minute);
  return local.toISOString().slice(0, 16);
}

function draftId(prefix: string) {
  const stamp = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 14);
  return `${prefix}_${stamp}`;
}

function formatDateTime(value: number) {
  return new Intl.DateTimeFormat("en-IN", { day: "2-digit", month: "short", hour: "numeric", minute: "2-digit", timeZone: "Asia/Kolkata" }).format(value);
}

function formatTime(value: number) {
  return new Intl.DateTimeFormat("en-IN", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Kolkata" }).format(value);
}

function isToday(value: number) {
  const formatter = new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", timeZone: "Asia/Kolkata" });
  return formatter.format(value) === formatter.format(Date.now());
}

function arrivalText(booking: Booking, currentTime: number) {
  if (booking.status === "inProgress") return "In service";
  if (["completed", "cancelled", "rejected"].includes(booking.status)) return titleCase(booking.status);
  if (booking.status === "pending" && booking.isInstant) return `Waiting ${Math.max(1, Math.floor((currentTime - booking.createdAtMillis) / minute))} min`;
  const difference = booking.startMillis - currentTime;
  if (difference < -5 * minute) return `Overdue ${Math.max(1, Math.floor(Math.abs(difference) / minute))} min`;
  if (difference <= 0) return "Due now";
  if (difference < hour) return `In ${Math.ceil(difference / minute)} min`;
  return formatTime(booking.startMillis);
}

function sanitiseData(value: unknown): AdminData {
  const data = value as Partial<AdminData> | undefined;
  return {
    generatedAtMillis: Number(data?.generatedAtMillis) || Date.now(),
    bookings: Array.isArray(data?.bookings) ? data.bookings : [],
    salons: Array.isArray(data?.salons) ? data.salons : [],
    barbers: Array.isArray(data?.barbers) ? data.barbers : [],
    customers: Array.isArray(data?.customers) ? data.customers : [],
    reviews: Array.isArray(data?.reviews) ? data.reviews : [],
    joinRequests: Array.isArray(data?.joinRequests) ? data.joinRequests : [],
    settlements: Array.isArray(data?.settlements) ? data.settlements : [],
    settlementPayments: Array.isArray(data?.settlementPayments) ? data.settlementPayments : [],
    wallets: Array.isArray(data?.wallets) ? data.wallets : [],
    notes: Array.isArray(data?.notes) ? data.notes : [],
    auditLogs: Array.isArray(data?.auditLogs) ? data.auditLogs : [],
    automationRules: Array.isArray(data?.automationRules) ? data.automationRules : [],
    operationalAlerts: Array.isArray(data?.operationalAlerts) ? data.operationalAlerts : [],
    arrivalSessions: Array.isArray(data?.arrivalSessions) ? data.arrivalSessions : [],
  };
}

function sanitiseDiscountData(value: unknown): DiscountAdministrationData {
  const data = value as Partial<DiscountAdministrationData> | undefined;
  const vault = data?.vault as Partial<DiscountVault> | undefined;
  const platformTotals = data?.platformTotals as Partial<DiscountUsage> | undefined;
  const parsedSalonCreditLimitAmount = Number(vault?.salonCreditLimitAmount);
  const parsedSalonDiscountBurnMultiplier = Number(vault?.salonDiscountBurnMultiplier);
  const usage = (item?: Partial<DiscountUsage>): DiscountUsage => ({
    reservedPayoutAmount: Number(item?.reservedPayoutAmount) || 0,
    realizedPayoutAmount: Number(item?.realizedPayoutAmount) || 0,
    releasedPayoutAmount: Number(item?.releasedPayoutAmount) || 0,
    reservedDiscountAmount: Number(item?.reservedDiscountAmount) || 0,
    realizedDiscountAmount: Number(item?.realizedDiscountAmount) || 0,
    releasedDiscountAmount: Number(item?.releasedDiscountAmount) || 0,
    reservedUses: Number(item?.reservedUses) || 0,
    realizedUses: Number(item?.realizedUses) || 0,
    releasedUses: Number(item?.releasedUses) || 0,
  });
  return {
    generatedAtMillis: Number(data?.generatedAtMillis) || Date.now(),
    campaigns: Array.isArray(data?.campaigns) ? data.campaigns.map((campaign) => ({
      ...campaign,
      fundingSource: campaign.fundingSource || "salon_promotion_credits",
      salonPayoutPercent: Number.isFinite(Number(campaign.salonPayoutPercent)) ? Number(campaign.salonPayoutPercent) : (Number(campaign.payoutMultiplier) || 2) * 100,
      salonPayoutPercentByBookingNumber: normaliseBookingPayoutRules(campaign.salonPayoutPercentByBookingNumber),
      cashbackProinAmount: Number(campaign.cashbackProinAmount) || 0,
      cashbackValidityDays: Number(campaign.cashbackValidityDays) || 0,
      cashbackTotalBudgetProin: Number(campaign.cashbackTotalBudgetProin) || 0,
      cashbackProgramId: campaign.cashbackProgramId || "",
      journeyCountScope: campaign.journeyCountScope === "salon" ? "salon" : "platform",
      journeyMilestones: Array.isArray(campaign.journeyMilestones) ? campaign.journeyMilestones.map((milestone) => ({
        bookingNumber: Number(milestone.bookingNumber) || 0,
        rewardType: (milestone.rewardType === "discount_proin" ? "discount_proin" : milestone.rewardType === "proin" ? "proin" : "discount") as JourneyMilestone["rewardType"],
        discountType: (milestone.discountType === "fixed" ? "fixed" : milestone.discountType === "none" ? "none" : "percent") as JourneyMilestone["discountType"],
        discountPercent: Number(milestone.discountPercent) || 0,
        fixedDiscountAmount: Number(milestone.fixedDiscountAmount) || 0,
        maximumDiscountAmount: Number(milestone.maximumDiscountAmount) || 0,
        cashbackProinAmount: Number(milestone.cashbackProinAmount) || 0,
        cashbackValidityDays: Number(milestone.cashbackValidityDays) || 0,
      })).filter((milestone) => milestone.bookingNumber > 0) : [],
    })) : [],
    campaignUsage: Array.isArray(data?.campaignUsage) ? data.campaignUsage : [],
    salonUsage: Array.isArray(data?.salonUsage) ? data.salonUsage : [],
    customerUsage: Array.isArray(data?.customerUsage) ? data.customerUsage : [],
    salonTotals: Array.isArray(data?.salonTotals) ? data.salonTotals : [],
    customerTotals: Array.isArray(data?.customerTotals) ? data.customerTotals : [],
    platformTotals: usage(platformTotals),
    vault: {
      approvedAmount: Number(vault?.approvedAmount) || 0,
      availableAmount: Number(vault?.availableAmount) || 0,
      reservedAmount: Number(vault?.reservedAmount) || 0,
      spentAmount: Number(vault?.spentAmount) || 0,
      salonCreditLimitAmount: Number.isFinite(parsedSalonCreditLimitAmount) ? parsedSalonCreditLimitAmount : 1000,
      salonDiscountBurnMultiplier: Number.isFinite(parsedSalonDiscountBurnMultiplier) ? parsedSalonDiscountBurnMultiplier : 2,
      budgetVersion: Number(vault?.budgetVersion) || 0,
    },
  };
}

function normaliseBookingPayoutRules(value: unknown): Record<string, number> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .map(([bookingNumber, percent]) => [Number(bookingNumber), Number(percent)] as const)
      .filter(([bookingNumber, percent]) => Number.isSafeInteger(bookingNumber) && bookingNumber >= 1 && Number.isFinite(percent) && percent >= 0 && percent <= 1000)
      .sort(([left], [right]) => left - right)
      .map(([bookingNumber, percent]) => [String(bookingNumber), percent]),
  );
}

function bookingPayoutRulesText(rules: Record<string, number> | undefined): string {
  return Object.entries(rules ?? {})
    .map(([bookingNumber, percent]) => [Number(bookingNumber), Number(percent)] as const)
    .filter(([bookingNumber, percent]) => Number.isSafeInteger(bookingNumber) && Number.isFinite(percent))
    .sort(([left], [right]) => left - right)
    .map(([bookingNumber, percent]) => `${bookingNumber}:${percent}`)
    .join(", ");
}

function parseBookingPayoutRules(value: string): Record<string, number> {
  const result: Record<string, number> = {};
  const entries = value.split(/[\n,]/).map((item) => item.trim()).filter(Boolean);
  for (const entry of entries) {
    const match = entry.match(/^(\d+)\s*:\s*(\d+(?:\.\d+)?)%?$/);
    if (!match) throw new Error("Use booking compensation rules such as 1:100, 2:0, 3:2.");
    const bookingNumber = Number(match[1]);
    const percent = Number(match[2]);
    if (!Number.isSafeInteger(bookingNumber) || bookingNumber < 1 || bookingNumber > 100000 || !Number.isFinite(percent) || percent < 0 || percent > 1000) {
      throw new Error("Booking compensation rules support booking numbers 1–100000 and percentages 0–1000.");
    }
    result[String(bookingNumber)] = percent;
  }
  return result;
}

function sanitiseProinData(value: unknown): ProinAdminData {
  const data = value as Partial<ProinAdminData> | undefined;
  const finance = data?.finance as Partial<ProinFinance> | undefined;
  return {
    generatedAtMillis: Number(data?.generatedAtMillis) || Date.now(),
    truncated: data?.truncated && typeof data.truncated === "object" ? data.truncated : {},
    programs: Array.isArray(data?.programs) ? data.programs : [],
    programUsage: Array.isArray(data?.programUsage) ? data.programUsage : [],
    coupons: Array.isArray(data?.coupons) ? data.coupons.map((coupon) => ({
      ...coupon,
      eligibleCustomerUids: Array.isArray(coupon.eligibleCustomerUids) ? coupon.eligibleCustomerUids : [],
      eligibleSalonIds: Array.isArray(coupon.eligibleSalonIds) ? coupon.eligibleSalonIds : [],
    })) : [],
    couponUsage: Array.isArray(data?.couponUsage) ? data.couponUsage : [],
    referralCodes: Array.isArray(data?.referralCodes) ? data.referralCodes : [],
    referrals: Array.isArray(data?.referrals) ? data.referrals : [],
    referralStats: Array.isArray(data?.referralStats) ? data.referralStats : [],
    wallets: Array.isArray(data?.wallets) ? data.wallets : [],
    lots: Array.isArray(data?.lots) ? data.lots : [],
    reimbursements: Array.isArray(data?.reimbursements) ? data.reimbursements : [],
    reconciliationReports: Array.isArray(data?.reconciliationReports) ? data.reconciliationReports : [],
    finance: {
      approvedBudgetInr: Number(finance?.approvedBudgetInr) || 0,
      unallocatedBudgetInr: Number(finance?.unallocatedBudgetInr) || 0,
      outstandingLiabilityInr: Number(finance?.outstandingLiabilityInr) || 0,
      reservedLiabilityInr: Number(finance?.reservedLiabilityInr) || 0,
      redeemedPayableInr: Number(finance?.redeemedPayableInr) || 0,
      settledExpenseInr: Number(finance?.settledExpenseInr) || 0,
      lifetimeGrantedProin: Number(finance?.lifetimeGrantedProin) || 0,
      lifetimeRedeemedProin: Number(finance?.lifetimeRedeemedProin) || 0,
      lifetimeExpiredProin: Number(finance?.lifetimeExpiredProin) || 0,
      lifetimeRevokedProin: Number(finance?.lifetimeRevokedProin) || 0,
    },
  };
}

export default function AdminDashboard() {
  const [view, setView] = useState<View>("overview");
  const [data, setData] = useState<AdminData>(sampleData);
  const [discountData, setDiscountData] = useState<DiscountAdministrationData>(sampleDiscountData);
  const [proinData, setProinData] = useState<ProinAdminData>(sampleProinData);
  const [user, setUser] = useState<User | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [adminUserId, setAdminUserId] = useState("");
  const [adminPassword, setAdminPassword] = useState("");
  const [passwordVisible, setPasswordVisible] = useState(false);
  const [authSubmitting, setAuthSubmitting] = useState(false);
  const [authError, setAuthError] = useState("");
  const [loading, setLoading] = useState(false);
  const [isLive, setIsLive] = useState(false);
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [salonFilter, setSalonFilter] = useState("all");
  const [typeFilter, setTypeFilter] = useState("all");
  const [selectedBooking, setSelectedBooking] = useState<Booking | null>(null);
  const [currentTime, setCurrentTime] = useState(now);
  const [adminAction, setAdminAction] = useState<AdminAction | null>(null);
  const [adminActionValues, setAdminActionValues] = useState<Record<string, string>>({});
  const [adminActionError, setAdminActionError] = useState("");
  const [adminActionSubmitting, setAdminActionSubmitting] = useState(false);

  const loadLiveData = useCallback(async (activeUser: User) => {
    setLoading(true);
    setMessage("");
    try {
      await activeUser.getIdToken(true);
      const { functions } = getFirebaseServices();
      const [response, discountResponse, proinResponse] = await Promise.all([
        httpsCallable<undefined, AdminData>(functions, "getAdminPhaseOneData")(),
        httpsCallable<undefined, DiscountAdministrationData>(functions, "getDiscountAdministrationDataAsAdmin")(),
        httpsCallable<undefined, ProinAdminData>(functions, "getProinPhaseOneDataAsAdmin")(),
      ]);
      setData(sanitiseData(response.data));
      setDiscountData(sanitiseDiscountData(discountResponse.data));
      setProinData(sanitiseProinData(proinResponse.data));
      setIsLive(true);
    } catch (error) {
      const text = error instanceof Error ? error.message : "Live data could not be loaded.";
      setIsLive(false);
      setMessage(text.includes("permission-denied") || text.includes("administrator") ? "This team account is no longer authorized." : "Pritze data could not be loaded. Check the connection and try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const { auth } = getFirebaseServices();
    return onAuthStateChanged(auth, (activeUser) => {
      setUser(activeUser);
      setAuthReady(true);
      if (activeUser) void loadLiveData(activeUser);
      else {
        setIsLive(false);
        setMessage("");
      }
    });
  }, [loadLiveData]);

  useEffect(() => {
    const initialClock = window.setTimeout(() => setCurrentTime(Date.now()), 0);
    const clock = window.setInterval(() => setCurrentTime(Date.now()), 30_000);
    return () => {
      window.clearTimeout(initialClock);
      window.clearInterval(clock);
    };
  }, []);

  useEffect(() => {
    if (!user || !isLive) return;
    const refresh = window.setInterval(() => void loadLiveData(user), 30_000);
    return () => window.clearInterval(refresh);
  }, [isLive, loadLiveData, user]);

  useEffect(() => {
    const close = (event: KeyboardEvent) => event.key === "Escape" && setSelectedBooking(null);
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, []);

  const salonMap = useMemo(() => new Map(data.salons.map((salon) => [salon.id, salon])), [data.salons]);
  const barberMap = useMemo(() => new Map(data.barbers.map((barber) => [barber.id, barber])), [data.barbers]);
  const normalisedSearch = search.trim().toLowerCase();
  const filteredBookings = useMemo(() => data.bookings.filter((booking) => {
    const salon = salonMap.get(booking.salonId)?.name ?? "";
    const matchesSearch = !normalisedSearch || [booking.id, booking.customerName, booking.customerPhone, booking.serviceName, salon].some((value) => value.toLowerCase().includes(normalisedSearch));
    return matchesSearch && (statusFilter === "all" || booking.status === statusFilter) && (salonFilter === "all" || booking.salonId === salonFilter) && (typeFilter === "all" || (typeFilter === "instant") === booking.isInstant);
  }).sort((a, b) => b.startMillis - a.startMillis), [data.bookings, normalisedSearch, salonFilter, salonMap, statusFilter, typeFilter]);

  const todayBookings = data.bookings.filter((booking) => isToday(booking.startMillis));
  const arrivingSoon = data.bookings.filter((booking) => booking.status === "confirmed" && booking.startMillis >= currentTime && booking.startMillis <= currentTime + 30 * minute);
  const activeBookings = data.bookings.filter((booking) => booking.status === "inProgress");
  const attentionBookings = data.bookings.filter((booking) => (booking.status === "pending" && booking.isInstant) || (booking.status === "confirmed" && booking.startMillis < currentTime - 5 * minute));
  const activeOperationalAlerts = data.operationalAlerts.filter((alert) => alert.status === "active");
  const completedValue = data.bookings.filter((booking) => booking.status === "completed").reduce((sum, booking) => sum + booking.servicePrice, 0);
  const dateLabel = new Intl.DateTimeFormat("en-IN", { weekday: "long", day: "numeric", month: "long", timeZone: "Asia/Kolkata" }).format(currentTime).toUpperCase();

  async function signInAdmin(event: React.FormEvent) {
    event.preventDefault();
    setAuthSubmitting(true);
    setAuthError("");
    try {
      const { auth, functions } = getFirebaseServices();
      const response = await httpsCallable<
        { userId: string; password: string },
        { customToken: string; displayName: string }
      >(functions, "signInAdminWithPassword")({
        userId: adminUserId.trim(),
        password: adminPassword,
      });
      await signInWithCustomToken(auth, response.data.customToken);
      setAdminPassword("");
      setMessage("");
    } catch (error) {
      setAuthError(adminAuthError(error));
    } finally {
      setAuthSubmitting(false);
    }
  }

  function exportBookings() {
    const header = ["Booking ID", "Customer", "Phone", "Salon", "Barber", "Service", "Value", "Start", "Type", "Status"];
    const rows = filteredBookings.map((booking) => [booking.id, booking.customerName, booking.customerPhone, salonMap.get(booking.salonId)?.name ?? "", barberMap.get(booking.barberId)?.name ?? "Unassigned", booking.serviceName, booking.servicePrice, new Date(booking.startMillis).toISOString(), booking.isInstant ? "Instant" : "Scheduled", booking.status]);
    const csv = [header, ...rows].map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(",")).join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `pritze-bookings-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  function openAdminAction(action: AdminAction) {
    if (!user || !isLive) {
      setMessage("Connect the authorized administrator account before using Phase 2 controls.");
      return;
    }
    setAdminAction(action);
    setAdminActionValues(Object.fromEntries(action.fields.map((field) => [field.key, field.initialValue ?? ""])));
    setAdminActionError("");
  }

  async function submitAdminAction(event: React.FormEvent) {
    event.preventDefault();
    if (!adminAction || !user) return;
    setAdminActionSubmitting(true);
    setAdminActionError("");
    try {
      const { functions } = getFirebaseServices();
      const callable = httpsCallable<Record<string, unknown>, Record<string, unknown>>(functions, adminAction.callableName);
      const values = Object.fromEntries(Object.entries(adminActionValues).map(([key, value]) => {
        const field = adminAction.fields.find((item) => item.key === key);
        if (field?.valueKind === "boolean") return [key, value === "true"];
        if (field?.valueKind === "string-list") return [key, [...new Set(value.split(/[\n,]/).map((item) => item.trim()).filter(Boolean))]];
        if (field?.valueKind === "number-list") return [key, [...new Set(value.split(/[\n,]/).map(Number).filter((item) => Number.isSafeInteger(item) && item > 0))]];
        if (field?.valueKind === "booking-payout-rules") return [key, parseBookingPayoutRules(value)];
        if (field?.valueKind === "journey-milestones") return [key, JSON.parse(value)];
        if (field?.type === "datetime-local") return [key, value ? new Date(value).getTime() : 0];
        if (field?.type === "number") return [key, Number(value)];
        return [key, value.trim()];
      }));
      const payload = { ...adminAction.payload, ...values };
      if (adminAction.callableName === "revokeProinAsAdmin" && !payload.requestId) {
        payload.requestId = `web-${window.crypto.randomUUID()}`;
      }
      await callable(payload);
      await loadLiveData(user);
      setSelectedBooking(null);
      setAdminAction(null);
      setMessage("");
    } catch (error) {
      setAdminActionError(adminControlError(error));
    } finally {
      setAdminActionSubmitting(false);
    }
  }

  function openView(nextView: View) {
    setView(nextView);
    if (nextView !== "bookings") setStatusFilter("all");
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  if (!authReady || !user || !isLive) {
    return <AdminAccessPage
      authReady={authReady}
      user={user}
      userId={adminUserId}
      password={adminPassword}
      passwordVisible={passwordVisible}
      submitting={authSubmitting}
      loading={loading}
      error={authError || message}
      setUserId={setAdminUserId}
      setPassword={setAdminPassword}
      setPasswordVisible={setPasswordVisible}
      onSignIn={signInAdmin}
      onRetry={() => user && void loadLiveData(user)}
      onUseAnotherAccount={() => void signOut(getFirebaseServices().auth)}
    />;
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <button className="brand" onClick={() => openView("overview")}><span className="brand-mark">P</span><span><strong>Pritze</strong><small>Control Center</small></span></button>
        <nav className="sidebar-menu" aria-label="Primary navigation">
          {navItems.filter((item) => item.id !== "guide").map((item) => <button className={`nav-item ${view === item.id ? "active" : ""}`} key={item.id} onClick={() => openView(item.id)}><span>{item.icon}</span>{item.label}{item.id === "bookings" && attentionBookings.length > 0 ? <b>{attentionBookings.length}</b> : item.id === "intelligence" && activeOperationalAlerts.length > 0 ? <b>{activeOperationalAlerts.length}</b> : null}</button>)}
        </nav>
        <div className="sidebar-guide">
          <button className={`nav-item ${view === "guide" ? "active" : ""}`} onClick={() => openView("guide")} title="Guide to every Control Center feature"><span>?</span>How to use</button>
        </div>
        <div className="sidebar-footer"><span className="live-dot" /><div><strong>Live monitoring</strong><small>Auto-refreshes every 30 sec</small></div></div>
      </aside>

      <main>
        <header className="topbar">
          <label className="search"><span>⌕</span><input value={search} onChange={(event) => setSearch(event.target.value)} aria-label="Search" placeholder="Search booking, customer or salon" />{search ? <button onClick={() => setSearch("")} aria-label="Clear search">×</button> : null}</label>
          <div className="admin-user">
            {loading ? <span className="sync-label">Refreshing…</span> : null}
            <><button className="avatar" title="Sign out" onClick={() => signOut(getFirebaseServices().auth)}>{initials(user.displayName || "Admin")}</button><div><strong>{user.displayName || "Pritze Admin"}</strong><span>Platform administrator</span></div></>
          </div>
        </header>

        <div className="content">
          <section className="welcome-row">
            <div><p className="eyebrow">{dateLabel}</p><h1>{view === "overview" ? "Good morning, Admin" : navItems.find((item) => item.id === view)?.label}</h1><p>{view === "overview" ? "Here’s what needs your attention across Pritze today." : viewSubtitle(view)}</p></div>
            <button className="export-button" onClick={exportBookings}>⇩ Export bookings</button>
          </section>

          {view === "overview" && <Overview data={data} todayBookings={todayBookings} arrivingSoon={arrivingSoon} activeBookings={activeBookings} attentionBookings={attentionBookings} completedValue={completedValue} salonMap={salonMap} barberMap={barberMap} currentTime={currentTime} onOpenBooking={setSelectedBooking} onOpenView={openView} />}
          {view === "intelligence" && <IntelligenceView data={data} salonMap={salonMap} currentTime={currentTime} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} onOpenBooking={(bookingId) => { const booking = data.bookings.find((item) => item.id === bookingId); if (booking) setSelectedBooking(booking); }} />}
          {view === "arrivals" && <ArrivalsView data={data} salonMap={salonMap} currentTime={currentTime} onOpenBooking={(booking) => setSelectedBooking(booking)} />}
          {view === "bookings" && <BookingsView bookings={filteredBookings} salons={data.salons} salonMap={salonMap} barberMap={barberMap} currentTime={currentTime} statusFilter={statusFilter} salonFilter={salonFilter} typeFilter={typeFilter} setStatusFilter={setStatusFilter} setSalonFilter={setSalonFilter} setTypeFilter={setTypeFilter} onOpenBooking={setSelectedBooking} />}
          {view === "customers" && <CustomersView customers={data.customers} bookings={data.bookings} search={normalisedSearch} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} />}
          {view === "salons" && <><SalonApprovalRequests salons={data.salons} search={normalisedSearch} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} /><SalonsView salons={data.salons} bookings={data.bookings} barbers={data.barbers} settlements={data.settlements} settlementPayments={data.settlementPayments} wallets={data.wallets} proinWallets={proinData.wallets} proinPrograms={proinData.programs} salonCreditLimitAmount={discountData.vault.salonCreditLimitAmount} search={normalisedSearch} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} /><SalonCampaignCards salons={data.salons} data={discountData} search={normalisedSearch} onOpenDiscounts={() => openView("discounts")} /></>}
          {view === "barbers" && <BarbersView barbers={data.barbers} bookings={data.bookings} joinRequests={data.joinRequests} salonMap={salonMap} search={normalisedSearch} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} />}
          {view === "reviews" && <ReviewsView reviews={data.reviews} search={normalisedSearch} />}
          {view === "settlements" && <SettlementsView settlements={data.settlements} wallets={data.wallets} salonMap={salonMap} currentTime={currentTime} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} />}
          {view === "discounts" && <DiscountOperationsView data={discountData} customerMap={new Map(data.customers.map((customer) => [customer.id, customer]))} salonMap={salonMap} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} />}
          {view === "proin" && <ProinOperationsView data={proinData} customerMap={new Map(data.customers.map((customer) => [customer.id, customer]))} salonMap={salonMap} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} />}
          {view === "reports" && <ReportsView data={data} completedValue={completedValue} />}
          {view === "activity" && <ActivityView auditLogs={data.auditLogs} notes={data.notes} />}
          {view === "guide" && <GuideView onOpenView={openView} />}
        </div>
      </main>
      {selectedBooking ? <BookingDrawer booking={selectedBooking} salon={salonMap.get(selectedBooking.salonId)} barber={barberMap.get(selectedBooking.barberId)} barbers={data.barbers.filter((item) => item.salonId === selectedBooking.salonId && item.isActive)} notes={data.notes.filter((note) => note.targetType === "booking" && note.targetId === selectedBooking.id)} currentTime={currentTime} canOperate={Boolean(user && isLive)} onAdminAction={openAdminAction} onClose={() => setSelectedBooking(null)} /> : null}
      {adminAction ? <AdminActionDialog action={adminAction} values={adminActionValues} error={adminActionError} submitting={adminActionSubmitting} onChange={(key, value) => setAdminActionValues((current) => ({ ...current, [key]: value }))} onSubmit={submitAdminAction} onClose={() => setAdminAction(null)} /> : null}
    </div>
  );
}

function adminControlError(error: unknown) {
  const code = typeof error === "object" && error !== null && "code" in error
    ? String(error.code).toLowerCase()
    : "";
  const value = error instanceof Error ? error.message : "";
  const cleaned = value
    .replace(/^Firebase:\s*/i, "")
    .replace(/^.*?:\s*/, "")
    .replace(/\s*\([^)]*\)\s*$/, "")
    .trim();
  if (code.includes("unauthenticated")) return "Your administrator session has expired. Sign in again.";
  if (code.includes("permission-denied")) return "This team account is not allowed to perform that action.";
  if (code.includes("resource-exhausted")) return "The control center is busy. Wait a moment and try again.";
  if (code.includes("unavailable") || code.includes("internal") || !cleaned || /^internal$/i.test(cleaned)) {
    return "The server could not complete this action. Please try again. If it continues, refresh the page.";
  }
  return cleaned;
}

function adminAuthError(error: unknown) {
  const value = error instanceof Error ? error.message : "";
  if (value.includes("permission-denied")) return "The User ID or password is incorrect.";
  if (value.includes("resource-exhausted")) return "Too many attempts. Try again in 15 minutes.";
  if (value.includes("invalid-argument")) return "Enter your User ID and password.";
  return "Something went wrong. Check your connection and try again.";
}

function viewSubtitle(view: View) {
  const subtitles: Record<View, string> = {
    overview: "",
    intelligence: "Prioritized alerts, anomalies and workload recommendations with human-controlled automation.",
    arrivals: "Customer-reported journey status and explicitly shared foreground location for active bookings.",
    bookings: "Supervise expected arrivals and every booking stage in one place.",
    customers: "Edit customer profiles and access while reviewing visit history and ratings.",
    salons: "Edit salon listings, services, availability, promotional credit and external settlement from each salon card.",
    barbers: "Team availability, specialities and completed workload.",
    reviews: "Salon feedback and customer ratings linked to completed visits.",
    settlements: "Reconcile Pritze payouts against external salon payments.",
    discounts: "Create targeted offers, control the promotional vault and monitor burn by campaign, salon and customer.",
    proin: "Control unused promotional rewards and record externally completed Proin reimbursements.",
    reports: "Read-only decision support based on completed Firebase records.",
    activity: "Review every administrator decision and internal operational note.",
    guide: "Learn what each section does and follow safe, step-by-step operating instructions.",
  };
  return subtitles[view];
}

function GuideView({ onOpenView }: { onOpenView: (view: View) => void }) {
  const sections: { view: View; icon: string; name: string; description: string; action: string }[] = [
    { view: "overview", icon: "⌂", name: "Overview", description: "The daily starting point: bookings, open salons, active services and items needing attention.", action: "Open overview" },
    { view: "intelligence", icon: "✦", name: "Intelligence", description: "Prioritized operational alerts, anomalies and recommendations. Review the evidence before acknowledging an alert.", action: "Open intelligence" },
    { view: "arrivals", icon: "⌖", name: "Live arrivals", description: "Customer-reported journey status and consent-based location for active bookings. Location is shown only while sharing is active.", action: "View arrivals" },
    { view: "bookings", icon: "▦", name: "Live bookings", description: "Filter scheduled and instant bookings by salon, type and status; open a row to inspect or manage the booking.", action: "View bookings" },
    { view: "customers", icon: "◎", name: "Customers", description: "Edit customer identity, contact details, preferences, photos and account access while reviewing visit history.", action: "Manage customers" },
    { view: "salons", icon: "◇", name: "Salons", description: "Approve salons, manage their public listing and team, then handle their promotional credit and external settlements in one card.", action: "Manage salons" },
    { view: "barbers", icon: "♙", name: "Barbers", description: "Team availability, specialties, completed workload and salon join requests.", action: "View barbers" },
    { view: "reviews", icon: "☆", name: "Reviews", description: "Read salon feedback and customer ratings linked to completed visits.", action: "View reviews" },
    { view: "settlements", icon: "₹", name: "Settlements", description: "Record Pritze payouts only after the salon has actually been paid outside the app.", action: "View settlements" },
    { view: "discounts", icon: "%", name: "Discount control", description: "Create targeted discounts, set the real-money vault and monitor reserved and realized burn.", action: "Manage discounts" },
    { view: "proin", icon: "◉", name: "Proin operations", description: "Configure referral, coupon and promotional rewards, their expiry, budgets and reimbursement evidence.", action: "Manage Proin" },
    { view: "reports", icon: "↗", name: "Reports", description: "Read-only business summaries based on completed Firebase records.", action: "Open reports" },
    { view: "activity", icon: "◷", name: "Admin activity", description: "The audit trail for administrator decisions and internal operational notes.", action: "View activity" },
  ];

  return <div className="guide-page">
    <section className="guide-hero">
      <div>
        <p className="eyebrow">PRITZE TEAM HANDBOOK</p>
        <h2>Run the Control Center with confidence</h2>
        <p>This page explains what every area does, how to make controlled changes and how discounts, Proin and external salon payouts fit together.</p>
        <div className="guide-hero-actions">
          <button onClick={() => onOpenView("overview")}>Start with today’s overview</button>
          <button className="quiet" onClick={() => onOpenView("discounts")}>Set up a discount</button>
        </div>
      </div>
      <div className="guide-orientation">
        <span>5 min</span>
        <strong>First-time orientation</strong>
        <small>Read “How the site works”, then use the playbook for the action you need.</small>
      </div>
    </section>

    <section className="guide-basics" aria-label="How the website works">
      <article><span>1</span><div><strong>Find the right area</strong><p>Use the left menu to change sections. The top search finds bookings, customers or salons; Export bookings downloads the current booking data.</p></div></article>
      <article><span>2</span><div><strong>Inspect before changing</strong><p>Open the relevant row and confirm the person, salon, dates, status, limits and financial exposure. Live data refreshes every 30 seconds.</p></div></article>
      <article><span>3</span><div><strong>Explain every decision</strong><p>Protected actions ask for a reason. That reason and the signed-in User ID become part of Admin activity for traceability.</p></div></article>
    </section>

    <section className="guide-setup-flow" aria-label="First setup order for discounts coupons and Proin">
      <div className="guide-card-heading"><span>→</span><div><p className="eyebrow">FIRST SETUP ORDER</p><h2>Discount, coupon and Proin testing in the safest sequence</h2></div></div>
      <ol>
        <li><b>Step 1:</b> Open <em>Discount control</em> and click <em>Change finance controls</em>. Set the approved test budget and legacy salon burn fallback, then save with a reason.</li>
        <li><b>Step 2:</b> Click <em>Create automatic draft</em> or <em>Create voucher draft</em>. Review the prefilled fields and save. The draft is inactive.</li>
        <li><b>Step 3:</b> Reopen the saved discount draft, check dates, salon/service/customer limits and burn caps, then change <em>Campaign active</em> to Yes only when ready.</li>
        <li><b>Step 4:</b> Open <em>Proin operations</em>, click <em>Change budget</em>, then create the needed inactive programs: customer referral, salon referral, customer coupon program or salon coupon program.</li>
        <li><b>Step 5:</b> In <em>Referral codes</em>, review the customer and salon invite codes. Use <em>Edit</em> only when a code must be changed; old referral history stays attached to the old code.</li>
        <li><b>Step 6:</b> After a coupon program exists, click <em>Create WELCOME50 coupon</em> for customers or <em>Create SALON100 coupon</em> for salons. Save inactive first.</li>
        <li><b>Step 7:</b> Run <em>Run reconciliation</em>. If the latest reconciliation is balanced, reopen the program and coupon, activate them, then test from the app checkout/profile.</li>
      </ol>
      <p>Nothing from the starter buttons reaches customers until the relevant campaign, program or coupon is explicitly activated.</p>
    </section>

    <section className="guide-playbook account-guide" id="guide-accounts">
      <div className="guide-playbook-intro">
        <p className="eyebrow">ACCOUNT ADMINISTRATION</p>
        <h2>How to update a customer or salon</h2>
        <p>Customer and salon changes are live operational changes. Confirm the record ID and phone number, make only the requested edits, and write the support or business reason.</p>
        <button onClick={() => onOpenView("customers")}>Open Customers</button>
      </div>
      <div className="guide-steps compact">
        <article><b>01</b><div><strong>Find the exact record</strong><p>Use the top search with the customer name, phone, email, salon name, owner name or address. Confirm recent visits or salon statistics before editing.</p></div></article>
        <article><b>02</b><div><strong>Edit a customer profile</strong><p>In Customers, select <em>Edit</em>. You can update name, phone, contact email, gender, birth date, preferred styles, profile photo and style-photo links. A phone cannot be reused by a salon owner or another account.</p></div></article>
        <article><b>03</b><div><strong>Control customer access</strong><p>Select <em>Suspend</em> only when app access must be blocked. This disables Firebase sign-in. Select <em>Restore</em> to allow the customer to sign in again.</p></div></article>
        <article><b>04</b><div><strong>Review a new salon</strong><p>At the top of Salons, open a new approval request. Check the salon name, owner, phone, email and address, then select <em>Approve</em>. Until you approve it, the salon stays hidden from customers and cannot receive bookings.</p></div></article>
        <article><b>05</b><div><strong>Use the salon card as its control page</strong><p>Each Salon card shows its Salon ID, private payout details, opening controls, promotional credit balance, the salon-specific negative credit limit, pending settlement and settled history.</p></div></article>
        <article><b>06</b><div><strong>Manage the salon’s profile, services and team</strong><p>Select <em>Edit profile</em> for public details and opening hours. Open <em>Manage all services</em> to change prices, duration and instant availability. Open <em>Manage team</em> to update the salon’s barber details and availability without leaving Salons.</p></div></article>
        <article><b>07</b><div><strong>Target a campaign to the right salon</strong><p>In Discount control, choose salon names from <em>Eligible salons</em>; you no longer need to look up or type IDs. Use <em>3</em> in “Show only on these customer booking numbers” for a third-booking offer.</p></div></article>
        <article><b>08</b><div><strong>Add promotional credit when needed</strong><p>First create an active manual salon-credit Proin program in <em>Proin operations</em>. Then use <em>Add promotional credit</em> on the salon card, select that program and enter the Proin amount. This adds promotional spending balance; it does not pay cash or reduce a settlement.</p></div></article>
        <article><b>09</b><div><strong>Record a payment or settle the full balance</strong><p>After paying a salon outside Pritze, use <em>Record external payment</em> for a partial amount or <em>Settle full amount</em> to allocate the exact pending balance to the oldest unpaid booking records. Choose Bank transfer, UPI or Cash. Bank/UPI require the completed transaction reference; Cash requires the cash receipt or ledger reference. Enter the reason; the balance then reduces immediately.</p></div></article>
        <article><b>10</b><div><strong>Verify the audit trail</strong><p>Every approval, credit-limit change, credit grant and settlement requires a reason. Open <em>Admin activity</em> afterward to confirm who made the change, which record changed and why.</p></div></article>
      </div>
    </section>

    <section className="guide-heading">
      <div><p className="eyebrow">THE LEFT MENU</p><h2>What each section is for</h2></div>
      <p>Choose a card to go directly to that part of the Control Center.</p>
    </section>
    <section className="guide-section-grid">
      {sections.map((section) => <article key={section.view}>
        <span className="guide-section-icon">{section.icon}</span>
        <div><h3>{section.name}</h3><p>{section.description}</p></div>
        <button onClick={() => onOpenView(section.view)}>{section.action} <span>→</span></button>
      </article>)}
    </section>

    <section className="guide-playbook discount-guide" id="guide-discounts">
      <div className="guide-playbook-intro">
        <p className="eyebrow">PLAYBOOK 01</p>
        <h2>How to set a discount</h2>
        <p>A discount changes what the customer pays and creates a real Pritze payout liability to the salon. Create it inactive first, review the exposure, then activate it.</p>
        <button onClick={() => onOpenView("discounts")}>Open Discount control</button>
      </div>
      <div className="guide-steps">
        <article><b>01</b><div><strong>Set the finance controls</strong><p>Select <em>Change finance controls</em> and enter the maximum approved real-money exposure plus the legacy salon-funded burn fallback. New campaigns should set their own salon compensation percentage instead: 100% gives the salon ₹10 for a ₹10 customer discount, while 0% gives no salon compensation. Existing reserved bookings retain their original amount.</p></div></article>
        <article><b>02</b><div><strong>Choose automatic, hidden coupon or visible offer</strong><p>For a quick safe test, click <em>Create automatic draft</em>, <em>Create hidden coupon draft</em> or <em>Create visible checkout offer draft</em>. For a custom setup, select <em>New discount / voucher</em>. Set a maximum customer discount in rupees, then choose the salon compensation percentage. Use booking rules such as <em>1:100, 2:0, 3:2</em> when compensation should change by the customer&apos;s booking number. Hidden typed-code coupons can be verbally shared and work only when typed by the customer. Visible checkout offers appear as a small tappable row below the final price before the customer books.</p></div></article>
        <article><b>03</b><div><strong>Define the offer and payout</strong><p>Choose percentage off or a fixed rupee discount. Set the salon compensation percentage on each campaign; only older campaigns without that setting use the Finance controls fallback. Optionally add Proin cashback, its validity and cashback budget. The cashback is awarded after service completion for a future booking.</p></div></article>
        <article><b>04</b><div><strong>Build one multi-booking journey</strong><p>Select <em>New journey campaign</em>, choose whether booking numbers count across Pritze or only at one salon, then add reward rows. For example: booking 1 discount only, booking 2 discount + Proin, booking 3 Proin only, and booking 10 discount again. These milestone labels remain private to administrators.</p></div></article>
        <article><b>05</b><div><strong>Target all salons or one salon</strong><p>Select eligible salon names directly—leaving all unchecked targets every eligible salon. From <em>Salons</em>, select <em>Create journey campaign</em> on a salon card to start a campaign already restricted to that salon.</p></div></article>
        <article><b>06</b><div><strong>Review, version and activate</strong><p>Check dates, caps, Proin budget, maximum milestone rewards per customer and Terms version. Save it inactive first, test the rules, then reopen it and change Active to Yes.</p></div></article>
        <article><b>07</b><div><strong>Monitor the burn</strong><p>Watch Available, Reserved and Realized burn, plus Burn by salon and Burn by customer. Edit the campaign to pause it if exposure is higher than expected.</p></div></article>
      </div>
      <div className="guide-example">
        <div><span>Worked example</span><strong>₹100 service · 10% off · 2× payout</strong></div>
        <div className="guide-example-math"><p><small>Customer pays</small><b>₹90</b></p><i>+</i><p><small>Pritze owes salon</small><b>₹20</b></p><i>=</i><p><small>Salon receives</small><b>₹110</b></p></div>
        <p>The ₹10 customer discount multiplied by 2 creates ₹20 of Pritze payout exposure. The customer pays at the salon counter; Pritze settles its amount separately.</p>
      </div>
    </section>

    <section className="guide-playbook proin-guide" id="guide-proin">
      <div className="guide-playbook-intro">
        <p className="eyebrow">PLAYBOOK 02</p>
        <h2>How to set Proin, referrals and coupons</h2>
        <p>Proin is a promotional reward, not withdrawable cash. Programs control who earns it, how much they receive, where it can be used and when it expires.</p>
        <button onClick={() => onOpenView("proin")}>Open Proin operations</button>
      </div>
      <div className="guide-steps compact">
        <article><b>01</b><div><strong>Approve a finance budget</strong><p>Use <em>Change budget</em> to set the maximum financial provision for outstanding rewards and salon reimbursements.</p></div></article>
        <article><b>02</b><div><strong>Create paired referral rewards</strong><p>For “both people earn”, create two referral programs for the same inviter role: one with <em>Referral inviter</em> and one with <em>Referred account</em>. Customer referrals can be customer→customer or salon→customer; salon referrals are salon→salon. A salon earns or triggers referral Proin only after <em>Approve referral rewards</em> is used on its salon card.</p></div></article>
        <article><b>03</b><div><strong>Set expiry and limits</strong><p>Define reward validity, program dates, total budget, grant limits, minimum booking value, maximum Proin per booking, redemption % and discount stacking. In referral-inviter programs, <em>Max rewards / invites per account</em> also limits how many pending + qualified invites can use one account’s referral code.</p></div></article>
        <article><b>04</b><div><strong>Add eligibility</strong><p>Optionally restrict salon IDs or service IDs. For referrals, select the inviter role and whether the inviter or referred account receives the reward. Change reward amount and invite cap by editing the program and saving a new version.</p></div></article>
        <article><b>05</b><div><strong>View or edit referral codes</strong><p>Use the <em>Referral codes</em> table to see every customer and salon invite code, who owns it, what type of invite it creates and how many referrals are linked. Edit can change the 6-character code or turn it inactive. Duplicate codes are rejected, and previous referral relationships keep the old code for audit.</p></div></article>
        <article><b>06</b><div><strong>Create a Proin coupon when needed</strong><p>First save a coupon-source program. Then choose <em>New coupon</em>, or use the starter buttons <em>Create WELCOME50 coupon</em> and <em>Create SALON100 coupon</em>. Link the program, set claim dates, total claims and optional customer or salon IDs. Customers enter their code at checkout/profile; salons enter their code from Promotional credits. Store the original code securely—the database returns only a masked version.</p></div></article>
        <article><b>07</b><div><strong>Reconcile, activate and monitor</strong><p>Run reconciliation before activation. Review wallets, expiring lots and reimbursements. Record a reimbursement as paid only after the external transfer has completed.</p></div></article>
      </div>
    </section>

    <section className="guide-two-column">
      <article className="panel guide-routine">
        <div className="guide-card-heading"><span>✓</span><div><p className="eyebrow">DAILY ROUTINE</p><h2>A safe operating order</h2></div></div>
        <ol>
          <li><b>Overview:</b> check urgent and active bookings.</li>
          <li><b>Intelligence:</b> review unacknowledged alerts and their evidence.</li>
          <li><b>Live bookings:</b> investigate pending, late or disputed bookings.</li>
          <li><b>Settlements:</b> record only verified external salon payments.</li>
          <li><b>Discount and Proin:</b> compare reserved, spent and payable exposure with approved budgets.</li>
          <li><b>Admin activity:</b> confirm sensitive actions have the correct reason and operator.</li>
        </ol>
      </article>
      <article className="panel guide-safety">
        <div className="guide-card-heading"><span>!</span><div><p className="eyebrow">IMPORTANT</p><h2>Controls that protect Pritze</h2></div></div>
        <ul>
          <li>Never share one User ID between team members; separate IDs make the audit trail useful.</li>
          <li>Save new campaigns and programs inactive first.</li>
          <li>Check dates, eligibility and budget caps before activating.</li>
        <li>Do not mark a settlement or reimbursement paid without the matching bank reference, UPI reference, or cash receipt/ledger reference.</li>
          <li>Use customer arrival location only for its active booking and only while consent-based sharing is enabled.</li>
          <li>Use internal notes for operational context, never for passwords or full coupon codes.</li>
        </ul>
      </article>
    </section>

    <section className="guide-help-footer">
      <div><span>?</span><p><strong>Not sure what to do?</strong><small>Do not guess on a financial or account action. Inspect the record, preserve the current state and ask the authorized Pritze administrator.</small></p></div>
      <button onClick={() => onOpenView("activity")}>Check Admin activity</button>
    </section>
  </div>;
}

function MetricCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: string }) {
  return <article className={`metric-card ${tone}`}><div className="metric-top"><span>{label}</span><i /></div><strong>{value}</strong><small>{detail}</small></article>;
}

type BookingMaps = { salonMap: Map<string, Salon>; barberMap: Map<string, Barber>; currentTime: number; onOpenBooking: (booking: Booking) => void };
type AdminControlProps = { canOperate: boolean; onAdminAction: (action: AdminAction) => void };

const reasonField: AdminActionField = { key: "reason", label: "Reason for this decision", type: "textarea", placeholder: "Explain why this intervention is required" };

function noteAction(targetType: AdminNote["targetType"], targetId: string, label: string): AdminAction {
  return {
    title: `Add note to ${label}`,
    description: "Internal notes are visible only to platform administrators and become part of the operational record.",
    confirmLabel: "Save internal note",
    callableName: "addAdminNote",
    payload: { targetType, targetId },
    fields: [{ key: "note", label: "Internal note", type: "textarea", placeholder: "Add context for the next administrator" }],
  };
}

function Overview({ data, todayBookings, arrivingSoon, activeBookings, attentionBookings, completedValue, salonMap, barberMap, currentTime, onOpenBooking, onOpenView }: { data: AdminData; todayBookings: Booking[]; arrivingSoon: Booking[]; activeBookings: Booking[]; attentionBookings: Booking[]; completedValue: number; onOpenView: (view: View) => void } & BookingMaps) {
  const liveBookings = [...data.bookings].filter((booking) => ["pending", "confirmed", "inProgress"].includes(booking.status)).sort((a, b) => a.startMillis - b.startMillis).slice(0, 6);
  return <>
    <section className="metric-grid" aria-label="Today’s metrics">
      <MetricCard label="Today’s bookings" value={String(todayBookings.length)} detail={`${data.salons.filter((salon) => salon.isOpen).length} salons currently open`} tone="gold" />
      <MetricCard label="Arriving in 30 min" value={String(arrivingSoon.length)} detail={`${arrivingSoon.filter((booking) => booking.isInstant).length} instant bookings`} tone="blue" />
      <MetricCard label="In service" value={String(activeBookings.length)} detail={`Across ${new Set(activeBookings.map((booking) => booking.salonId)).size} salons`} tone="green" />
      <MetricCard label="Needs attention" value={String(attentionBookings.length)} detail={attentionBookings.length ? "Review the live queue" : "Everything is on track"} tone="red" />
    </section>
    <section className="attention-card"><div className="attention-icon">!</div><div><strong>{attentionBookings.length ? `${attentionBookings.length} items need attention` : "No urgent items"}</strong><p>{attentionBookings.length ? "Pending instant requests and overdue arrivals are waiting for review." : "No instant requests or overdue arrivals require intervention."}</p></div><button onClick={() => onOpenView("bookings")}>Review now <span>→</span></button></section>
    <section className="overview-split">
      <div className="panel live-panel"><PanelHeader title="Live bookings" subtitle="Customers arriving soon and services in progress." action="View all" onAction={() => onOpenView("bookings")} live /><BookingTable bookings={liveBookings} salonMap={salonMap} barberMap={barberMap} currentTime={currentTime} onOpenBooking={onOpenBooking} /></div>
      <aside className="panel pulse-panel"><PanelHeader title="Network pulse" subtitle="Today across Pritze" /><div className="pulse-list"><Pulse label="Open salons" value={`${data.salons.filter((salon) => salon.isOpen).length}/${data.salons.length}`} /><Pulse label="Active barbers" value={`${data.barbers.filter((barber) => barber.isActive).length}/${data.barbers.length}`} /><Pulse label="Completed-service value" value={formatMoney(completedValue)} /><Pulse label="Average salon rating" value={`${average(data.salons.map((salon) => salon.rating)).toFixed(1)} ★`} /></div></aside>
    </section>
  </>;
}

function PanelHeader({ title, subtitle, action, onAction, live }: { title: string; subtitle: string; action?: string; onAction?: () => void; live?: boolean }) {
  return <div className="panel-header"><div><div className="section-title"><h2>{title}</h2>{live ? <span><i /> Live</span> : null}</div><p>{subtitle}</p></div>{action ? <button onClick={onAction}>{action} →</button> : null}</div>;
}

function Pulse({ label, value }: { label: string; value: string }) {
  return <div className="pulse-row"><span>{label}</span><strong>{value}</strong></div>;
}

function BookingTable({ bookings, salonMap, barberMap, currentTime, onOpenBooking }: { bookings: Booking[] } & BookingMaps) {
  if (!bookings.length) return <EmptyState title="No bookings found" detail="Try changing the filters or search." />;
  return <div className="booking-table"><div className="table-row table-head"><span>Customer</span><span>Salon & barber</span><span>Expected arrival</span><span>Status</span><span /></div>{bookings.map((booking) => <div className="table-row" key={booking.id}>
    <div className="customer-cell"><div className="customer-avatar">{initials(booking.customerName)}</div><div><strong>{booking.customerName}</strong><span>{booking.serviceName || "Service"} · {booking.id}</span></div></div>
    <div className="salon-cell"><strong>{salonMap.get(booking.salonId)?.name ?? "Unknown salon"}</strong><span>{barberMap.get(booking.barberId)?.name ?? "Unassigned"}</span></div>
    <div className={`arrival-cell ${arrivalText(booking, currentTime).startsWith("Overdue") ? "overdue" : ""}`}><strong>{arrivalText(booking, currentTime)}</strong><span>{booking.isInstant ? "Instant" : formatDateTime(booking.startMillis)}</span></div>
    <div><span className={`status ${booking.status}`}>{titleCase(booking.status)}</span></div>
    <button className="row-button" onClick={() => onOpenBooking(booking)} aria-label={`Open ${booking.customerName} booking`}>›</button>
  </div>)}</div>;
}

function BookingsView({ bookings, salons, salonMap, barberMap, currentTime, statusFilter, salonFilter, typeFilter, setStatusFilter, setSalonFilter, setTypeFilter, onOpenBooking }: { bookings: Booking[]; salons: Salon[]; statusFilter: string; salonFilter: string; typeFilter: string; setStatusFilter: (value: string) => void; setSalonFilter: (value: string) => void; setTypeFilter: (value: string) => void } & BookingMaps) {
  return <section className="panel main-panel"><div className="filter-bar"><label>Status<select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}><option value="all">All statuses</option><option value="pending">Pending</option><option value="confirmed">Confirmed</option><option value="inProgress">In service</option><option value="completed">Completed</option><option value="cancelled">Cancelled</option><option value="rejected">Rejected</option></select></label><label>Salon<select value={salonFilter} onChange={(event) => setSalonFilter(event.target.value)}><option value="all">All salons</option>{salons.map((salon) => <option key={salon.id} value={salon.id}>{salon.name}</option>)}</select></label><label>Booking type<select value={typeFilter} onChange={(event) => setTypeFilter(event.target.value)}><option value="all">Instant & scheduled</option><option value="instant">Instant</option><option value="scheduled">Scheduled</option></select></label><span className="result-count">{bookings.length} results</span></div><BookingTable bookings={bookings} salonMap={salonMap} barberMap={barberMap} currentTime={currentTime} onOpenBooking={onOpenBooking} /></section>;
}

function ArrivalsView({ data, salonMap, currentTime, onOpenBooking }: { data: AdminData; salonMap: Map<string, Salon>; currentTime: number; onOpenBooking: (booking: Booking) => void }) {
  const sessionMap = new Map(data.arrivalSessions.map((session) => [session.bookingId, session]));
  const visible = data.bookings
    .filter((booking) => ["confirmed", "inProgress"].includes(booking.status))
    .filter((booking) => (booking.arrivalStatus && booking.arrivalStatus !== "notStarted") || sessionMap.has(booking.id))
    .sort((left, right) => left.startMillis - right.startMillis);
  const activeSharing = data.arrivalSessions.filter((session) => session.sharingActive && session.expiresAtMillis > currentTime);
  const late = visible.filter((booking) => booking.arrivalStatus === "runningLate" || booking.startMillis < currentTime - 5 * minute);
  const arrived = visible.filter((booking) => booking.arrivalStatus === "arrived");

  return <>
    <section className="arrival-privacy">
      <span>⌖</span>
      <div><strong>Consent-based arrival monitoring</strong><p>Only the customer’s latest foreground location is shown. Sharing expires automatically and no journey history is retained.</p></div>
    </section>
    <section className="report-grid arrival-metrics">
      <MetricCard label="Sharing now" value={String(activeSharing.length)} detail="Explicit customer opt-ins" tone="green" />
      <MetricCard label="Running late" value={String(late.length)} detail="Reported or overdue arrivals" tone="red" />
      <MetricCard label="Arrived" value={String(arrived.length)} detail="Ready for salon check-in" tone="gold" />
    </section>
    <section className="panel main-panel arrivals-panel">
      <PanelHeader title="Customer journey status" subtitle="ETA appears only when the salon has a valid saved map pin." live={activeSharing.length > 0} />
      {visible.length ? <div className="arrival-list">{visible.map((booking) => {
        const session = sessionMap.get(booking.id);
        const fresh = Boolean(session?.lastLocationAtMillis && currentTime - session.lastLocationAtMillis <= 5 * minute);
        const mapUrl = session?.hasLocation ? `https://www.google.com/maps?q=${session.latitude},${session.longitude}` : "";
        return <article key={booking.id} className={booking.arrivalStatus === "runningLate" ? "late" : ""}>
          <div className="arrival-person"><div className="customer-avatar">{initials(booking.customerName)}</div><div><strong>{booking.customerName}</strong><span>{booking.id} · {salonMap.get(booking.salonId)?.name ?? "Unknown salon"}</span><small>{formatDateTime(booking.startMillis)}</small></div></div>
          <div className="arrival-journey"><span>Journey status</span><strong>{arrivalStatusText(booking.arrivalStatus)}</strong><small>{booking.arrivalStatusUpdatedAtMillis ? `Updated ${formatDateTime(booking.arrivalStatusUpdatedAtMillis)}` : "Customer has not shared a time"}</small></div>
          <div className="arrival-eta"><span>Estimated arrival</span><strong>{session?.hasSalonPin && session.estimatedArrivalMinutes ? `${session.estimatedArrivalMinutes} min` : "Unavailable"}</strong><small>{session?.hasSalonPin && session.distanceMeters ? `${(session.distanceMeters / 1000).toFixed(1)} km from salon` : "Salon pin required"}</small></div>
          <div className="arrival-location"><span className={`location-state ${session?.sharingActive && fresh ? "live" : ""}`}>{session?.sharingActive && fresh ? "● Live location" : session?.sharingActive ? "Location stale" : "Status only"}</span><small>{session?.lastLocationAtMillis ? `Last update ${formatDateTime(session.lastLocationAtMillis)}` : "No location shared"}</small>{mapUrl && session?.sharingActive ? <a href={mapUrl} target="_blank" rel="noreferrer">Open map ↗</a> : null}</div>
          <button className="row-button" onClick={() => onOpenBooking(booking)} aria-label={`Open ${booking.customerName} arrival`}>›</button>
        </article>;
      })}</div> : <EmptyState title="No customer journey updates" detail="Confirmed customers can share an arrival status without sharing location." />}
    </section>
  </>;
}

function editableIndianPhone(value: string) {
  const digits = value.replace(/\D/g, "");
  const local = digits.length > 10 && digits.startsWith("91") ? digits.slice(2) : digits;
  return local.length === 10 ? `+91${local}` : value;
}

function customerProfileAction(customer: Customer): AdminAction {
  return {
    title: `Edit ${customer.name}`,
    description: "Update the customer profile shown throughout Pritze. Sign-in provider identities remain protected, and every saved change is audited.",
    confirmLabel: "Save customer",
    callableName: "updateCustomerProfileAsAdmin",
    payload: { customerUid: customer.id },
    fields: [
      { key: "name", label: "Customer name", initialValue: customer.name },
      { key: "phone", label: "Phone number", type: "tel", initialValue: editableIndianPhone(customer.phone) },
      { key: "email", label: "Contact email", type: "email", initialValue: customer.email, required: false },
      { key: "gender", label: "Gender", type: "select", initialValue: customer.gender, required: false, options: [{ label: "Woman", value: "woman" }, { label: "Man", value: "man" }, { label: "Non-binary", value: "non-binary" }, { label: "Prefer not to say", value: "prefer-not-to-say" }] },
      { key: "birthDate", label: "Birth date", type: "date", initialValue: customer.birthDate, required: false },
      { key: "preferredStyles", label: "Preferred styles", type: "textarea", valueKind: "string-list", initialValue: customer.preferredStyles.join("\n"), required: false },
      { key: "photoUrl", label: "Profile photo URL", type: "url", initialValue: customer.photoUrl ?? "", required: false },
      { key: "stylePhotoUrls", label: "Preferred-style photo URLs", type: "textarea", valueKind: "string-list", initialValue: (customer.stylePhotoUrls ?? []).join("\n"), required: false },
      reasonField,
    ],
  };
}

function salonProfileAction(salon: Salon): AdminAction {
  return {
    title: `Edit ${salon.name}`,
    description: "Update the salon public listing, contact details, media and operating hours. The owner login identity remains protected.",
    confirmLabel: "Save salon",
    callableName: "updateSalonProfileAsAdmin",
    payload: { salonId: salon.id },
    fields: [
      { key: "name", label: "Salon name", initialValue: salon.name },
      { key: "ownerName", label: "Owner name", initialValue: salon.ownerName },
      { key: "address", label: "Address", type: "textarea", initialValue: salon.address },
      { key: "directionsUrl", label: "Directions URL", type: "url", initialValue: salon.directionsUrl ?? "", required: false },
      { key: "phone", label: "Salon phone", type: "tel", initialValue: editableIndianPhone(salon.phone) },
      { key: "email", label: "Contact email", type: "email", initialValue: salon.email, required: false },
      { key: "logoUrl", label: "Logo URL", type: "url", initialValue: salon.logoUrl ?? "", required: false },
      { key: "photoUrls", label: "Salon photo URLs", type: "textarea", valueKind: "string-list", initialValue: (salon.photoUrls ?? []).join("\n"), required: false },
      { key: "distanceLabel", label: "Location label", initialValue: salon.distanceLabel ?? "Nearby" },
      { key: "openTime", label: "Opening time", initialValue: salon.openTime, placeholder: "9:00 AM" },
      { key: "closeTime", label: "Closing time", initialValue: salon.closeTime, placeholder: "8:30 PM" },
      reasonField,
    ],
  };
}

function salonServiceAction(salon: Salon, service: SalonService): AdminAction {
  return {
    title: `Edit ${service.name}`,
    description: `Update this service for ${salon.name}. Price, duration and availability are reflected in customer booking flows after refresh.`,
    confirmLabel: "Save service",
    callableName: "updateSalonServiceAsAdmin",
    payload: { salonId: salon.id, serviceId: service.id },
    fields: [
      { key: "name", label: "Service name", initialValue: service.name },
      { key: "category", label: "Category", initialValue: service.category || "Grooming" },
      { key: "price", label: "Price (₹)", type: "number", initialValue: String(service.price), min: 0, max: 100000 },
      { key: "durationMinutes", label: "Duration (minutes)", type: "number", initialValue: String(service.durationMinutes), min: 5, max: 480 },
      { key: "isAvailable", label: "Available to customers", type: "select", valueKind: "boolean", initialValue: String(service.isAvailable), options: [{ label: "Yes", value: "true" }, { label: "No", value: "false" }] },
      { key: "instantBookingEnabled", label: "Allow instant booking", type: "select", valueKind: "boolean", initialValue: String(service.instantBookingEnabled), options: [{ label: "Yes", value: "true" }, { label: "No", value: "false" }] },
      reasonField,
    ],
  };
}

function CustomersView({ customers, bookings, search, canOperate, onAdminAction }: { customers: Customer[]; bookings: Booking[]; search: string } & AdminControlProps) {
  const visible = customers.filter((customer) => !search || [customer.name, customer.phone, customer.email].some((value) => value.toLowerCase().includes(search)));
  return <section className="panel main-panel"><div className="data-table customer-data phase-two-data"><div className="data-head"><span>Customer</span><span>Visits</span><span>Completion</span><span>Salon rating</span><span>Preferences</span><span>Control</span></div>{visible.map((customer) => {
    const visits = bookings.filter((booking) => booking.customerUid === customer.id);
    const completed = visits.filter((booking) => booking.status === "completed").length;
    const accountAction: AdminAction = { title: `${customer.adminSuspended ? "Restore" : "Suspend"} ${customer.name}`, description: customer.adminSuspended ? "Restore this customer's Firebase sign-in and app access." : "Block this customer's Firebase sign-in until an administrator restores the account.", confirmLabel: customer.adminSuspended ? "Restore account" : "Suspend account", callableName: "updateCustomerControlAsAdmin", payload: { customerUid: customer.id, adminSuspended: !customer.adminSuspended }, fields: [reasonField], tone: customer.adminSuspended ? "default" : "danger" };
    return <div className={`data-row ${customer.adminSuspended ? "account-suspended" : ""}`} key={customer.id}><div className="profile-cell"><div className="customer-avatar">{initials(customer.name)}</div><div><strong>{customer.name}</strong><span>{customer.phone}</span><small>{customer.adminSuspended ? "Account suspended" : customer.email || "No email"}</small></div></div><strong>{visits.length}</strong><span>{visits.length ? Math.round(completed / visits.length * 100) : 0}%</span><span className="rating">{customer.salonRating ? customer.salonRating.toFixed(1) : "—"} ★ <small>({customer.salonRatingCount})</small></span><div className="tags">{customer.preferredStyles.slice(0, 2).map((style) => <span key={style}>{style}</span>)}</div><div className="row-controls"><button disabled={!canOperate} onClick={() => onAdminAction(customerProfileAction(customer))}>Edit</button><button disabled={!canOperate} className={customer.adminSuspended ? "" : "danger-link"} onClick={() => onAdminAction(accountAction)}>{customer.adminSuspended ? "Restore" : "Suspend"}</button><button disabled={!canOperate} onClick={() => onAdminAction(noteAction("customer", customer.id, customer.name))}>Note</button></div></div>;
  })}</div>{!visible.length ? <EmptyState title="No customers found" detail="Try another name, phone number or email." /> : null}</section>;
}

function SalonApprovalRequests({ salons, search, canOperate, onAdminAction }: { salons: Salon[]; search: string } & AdminControlProps) {
  const pending = salons.filter((salon) => salon.approvalStatus === "pending" && (!search || [salon.name, salon.ownerName, salon.address, salon.phone, salon.email].some((value) => value.toLowerCase().includes(search))));
  if (!pending.length) return null;
  const review = (salon: Salon, decision: "approved" | "rejected"): AdminAction => ({
    title: `${decision === "approved" ? "Approve" : "Reject"} ${salon.name}`,
    description: decision === "approved" ? "This publishes the salon to customers and enables it to receive bookings when it is open." : "This keeps the salon hidden from customers and pauses its bookings. The owner will be notified.",
    confirmLabel: decision === "approved" ? "Approve salon" : "Reject salon",
    callableName: "reviewSalonOnboardingAsAdmin",
    payload: {salonId: salon.id, decision},
    fields: [reasonField],
    tone: decision === "approved" ? "default" : "danger",
  });
  return <section className="panel salon-approval-panel">
    <PanelHeader title={`New salon approval requests (${pending.length})`} subtitle="These salons are saved by their owners but are hidden from customers until you approve them." />
    <div className="salon-approval-list">{pending.map((salon) => <article key={salon.id}>
      <div className="salon-monogram">{initials(salon.name)}</div>
      <div><strong>{salon.name}</strong><span>{salon.ownerName} · {salon.phone}</span><small>{salon.address} · {salon.email || "No email"}</small></div>
      <time>{salon.approvalRequestedAtMillis ? formatDateTime(salon.approvalRequestedAtMillis) : "New request"}</time>
      <div className="row-controls"><button disabled={!canOperate} onClick={() => onAdminAction(review(salon, "approved"))}>Approve</button><button disabled={!canOperate} className="danger-link" onClick={() => onAdminAction(review(salon, "rejected"))}>Reject</button></div>
    </article>)}</div>
  </section>;
}

function journeyCampaignAction(salonMap: Map<string, Salon>, campaign?: DiscountCampaign, targetSalon?: Salon): AdminAction {
  const start = campaign?.startsAtMillis || Date.now();
  const end = campaign?.endsAtMillis || Date.now() + 30 * day;
  const defaultMilestones: JourneyMilestone[] = [
    { bookingNumber: 1, rewardType: "discount", discountType: "percent", discountPercent: 10, fixedDiscountAmount: 0, maximumDiscountAmount: 100, cashbackProinAmount: 0, cashbackValidityDays: 0 },
    { bookingNumber: 2, rewardType: "discount_proin", discountType: "fixed", discountPercent: 0, fixedDiscountAmount: 50, maximumDiscountAmount: 50, cashbackProinAmount: 20, cashbackValidityDays: 30 },
    { bookingNumber: 3, rewardType: "proin", discountType: "none", discountPercent: 0, fixedDiscountAmount: 0, maximumDiscountAmount: 0, cashbackProinAmount: 40, cashbackValidityDays: 30 },
  ];
  const milestones = campaign?.journeyMilestones?.length ? campaign.journeyMilestones : defaultMilestones;
  const selectedSalonIds = campaign?.salonIds ?? (targetSalon ? [targetSalon.id] : []);
  return {
    title: campaign ? `Edit ${campaign.name}` : targetSalon ? `Create journey for ${targetSalon.name}` : "Create booking journey campaign",
    description: "Configure different rewards at exact completed-booking numbers inside one campaign. Customers see only the ordinary discount or Proin result; milestone labels remain private to the Control Center.",
    confirmLabel: campaign ? "Save new journey version" : "Create inactive journey",
    callableName: "upsertDiscountCampaignAsAdmin",
    payload: campaign ? { campaignId: campaign.campaignId, expectedVoucherCodeHash: campaign.voucherCodeHash } : {},
    fields: [
      ...(campaign ? [] : [{ key: "campaignId", label: "Campaign ID", initialValue: draftId(targetSalon ? `journey_${targetSalon.id.slice(0, 16)}` : "booking_journey") } as AdminActionField]),
      { key: "name", label: "Campaign name", initialValue: campaign?.name ?? (targetSalon ? `${targetSalon.name} booking journey` : "Customer booking journey") },
      { key: "active", label: "Campaign active", type: "select", valueKind: "boolean", initialValue: String(campaign?.active ?? false), options: [{ label: "No", value: "false" }, { label: "Yes", value: "true" }] },
      { key: "priority", label: "Priority (higher wins)", type: "number", min: 0, initialValue: String(campaign?.priority ?? 100) },
      { key: "journeyCountScope", label: "Booking count scope", type: "select", initialValue: campaign?.journeyCountScope ?? (targetSalon ? "salon" : "platform"), options: [{ label: "All completed Pritze bookings", value: "platform" }, { label: "Completed bookings at this salon", value: "salon" }] },
      { key: "journeyMilestones", label: "Booking reward milestones", type: "journey-milestones", valueKind: "journey-milestones", initialValue: JSON.stringify(milestones) },
      { key: "fundingSource", label: "Campaign funding source", type: "select", initialValue: campaign?.fundingSource ?? "salon_promotion_credits", options: [{ label: "Salon promotional credits", value: "salon_promotion_credits" }, { label: "Platform discount vault", value: "platform_vault" }] },
      { key: "salonPayoutPercent", label: "Salon compensation (% of customer discount)", type: "number", min: 0, max: 1000, step: 0.01, initialValue: String(campaign?.salonPayoutPercent ?? 100) },
      { key: "salonPayoutPercentByBookingNumber", label: "Compensation by customer booking number (optional)", type: "textarea", valueKind: "booking-payout-rules", placeholder: "1:100, 2:0, 10:50", required: false, initialValue: bookingPayoutRulesText(campaign?.salonPayoutPercentByBookingNumber) },
      { key: "cashbackTotalBudgetProin", label: "Total Proin reward budget", type: "number", min: 0, initialValue: String(campaign?.cashbackTotalBudgetProin ?? 10000) },
      { key: "totalPayoutBudget", label: "Total salon-compensation budget (₹)", type: "number", min: 0, initialValue: String(campaign?.totalPayoutBudget ?? 10000) },
      { key: "perSalonPayoutBudget", label: "Per-salon payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: String(campaign?.perSalonPayoutBudget ?? 0) },
      { key: "perCustomerPayoutBudget", label: "Per-customer payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: String(campaign?.perCustomerPayoutBudget ?? 0) },
      { key: "maximumUsesPerCustomer", label: "Maximum milestone rewards per customer", type: "number", min: milestones.length, initialValue: String(Math.max(campaign?.maximumUsesPerCustomer ?? milestones.length, milestones.length)) },
      { key: "minimumServiceAmount", label: "Minimum service total (₹)", type: "number", min: 0, initialValue: String(campaign?.minimumServiceAmount ?? 0) },
      { key: "startsAtMillis", label: "Campaign starts", type: "datetime-local", initialValue: dateTimeLocalValue(start), required: false },
      { key: "endsAtMillis", label: "Campaign ends", type: "datetime-local", initialValue: dateTimeLocalValue(end), required: false },
      { key: "salonIds", label: "Eligible salons (leave all unchecked for every salon)", type: "checkbox-list", valueKind: "string-list", required: false, initialValue: selectedSalonIds.join("\n"), options: [...salonMap.values()].sort((left, right) => left.name.localeCompare(right.name)).map((salon) => ({ label: `${salon.name} — ${salon.id}`, value: salon.id })) },
      { key: "excludedSalonIds", label: "Excluded salon IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.excludedSalonIds.join(", ") ?? "" },
      { key: "customerUids", label: "Eligible customer UIDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.customerUids.join(", ") ?? "" },
      { key: "serviceIds", label: "Eligible service IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.serviceIds.join(", ") ?? "" },
      { key: "newToSalonOnly", label: "Only customers new to the salon", type: "select", valueKind: "boolean", initialValue: String(campaign?.newToSalonOnly ?? false), options: [{ label: "No", value: "false" }, { label: "Yes", value: "true" }] },
      { key: "returningToSalonOnly", label: "Only returning salon customers", type: "select", valueKind: "boolean", initialValue: String(campaign?.returningToSalonOnly ?? false), options: [{ label: "No", value: "false" }, { label: "Yes", value: "true" }] },
      { key: "termsVersion", label: "Terms version", initialValue: campaign?.termsVersion ?? "journey-v1" },
      reasonField,
    ],
  };
}

function SalonsView({ salons, bookings, barbers, settlements, settlementPayments, wallets, proinWallets, proinPrograms, salonCreditLimitAmount, search, canOperate, onAdminAction }: { salons: Salon[]; bookings: Booking[]; barbers: Barber[]; settlements: Settlement[]; settlementPayments: SalonSettlementPayment[]; wallets: SalonWallet[]; proinWallets: ProinWallet[]; proinPrograms: ProinProgram[]; salonCreditLimitAmount: number; search: string } & AdminControlProps) {
  const visible = salons.filter((salon) => !search || [salon.name, salon.ownerName, salon.address].some((value) => value.toLowerCase().includes(search)));
  const salonMap = new Map(salons.map((salon) => [salon.id, salon]));
  const manualSalonPrograms = proinPrograms.filter((program) => program.sourceType === "manual" && program.walletType === "salon_promotion_credits");

  function copySalonId(salon: Salon) {
    void navigator.clipboard?.writeText(salon.id);
  }

  return <div className="salon-grid">{visible.map((salon) => {
    const salonBookings = bookings.filter((booking) => booking.salonId === salon.id);
    const completed = salonBookings.filter((booking) => booking.status === "completed");
    const salonBarbers = barbers.filter((barber) => barber.salonId === salon.id);
    const settlementWallet = wallets.find((wallet) => wallet.salonId === salon.id);
    const salonSettlements = settlements.filter((settlement) => settlement.salonId === salon.id);
    const pendingFromRecords = salonSettlements.filter((settlement) => settlement.status !== "paid").reduce((sum, settlement) => sum + (Number.isFinite(settlement.outstandingAmount) ? settlement.outstandingAmount : Math.max(0, settlement.pritzePayoutAmount - settlement.paidAmount)), 0);
    const pendingSettlement = settlementWallet ? settlementWallet.payableBalance : pendingFromRecords;
    const promotionWallet = proinWallets.find((wallet) => wallet.walletType === "salon_promotion_credits" && wallet.accountId === salon.id);
    const creditLimit = promotionWallet?.creditLimitProin ?? salonCreditLimitAmount;
    const availableProin = promotionWallet?.availableProin ?? 0;
    const spendableProin = promotionWallet?.spendableProin ?? Math.max(0, availableProin + creditLimit);
    const paymentHistory = settlementPayments.filter((payment) => payment.salonId === salon.id).sort((left, right) => right.paidAtMillis - left.paidAtMillis).slice(0, 5);
    const salonControl = (control: string, value: boolean, label: string, danger = false): AdminAction => ({ title: `${label}: ${salon.name}`, description: "This changes salon availability for customers and is recorded in the administrator audit log.", confirmLabel: label, callableName: "updateSalonControlAsAdmin", payload: { salonId: salon.id, control, value }, fields: [reasonField], tone: danger ? "danger" : "default" });
    const creditLimitAction: AdminAction = { title: `Change ${salon.name}'s promotional credit limit`, description: "This is this salon's own maximum negative promotional Proin balance. It limits future salon-funded campaign burn and does not change another salon's limit.", confirmLabel: "Save credit limit", callableName: "setSalonPromotionCreditLimitAsAdmin", payload: { salonId: salon.id }, fields: [{ key: "creditLimitProin", label: "Promotional credit limit (Proin)", type: "number", min: 0, initialValue: String(creditLimit) }, reasonField] };
    const addCreditAction: AdminAction = { title: `Add promotional credit to ${salon.name}`, description: "Add a recorded Proin credit to this salon. The chosen manual program controls validity and its maximum reward. This does not pay cash to the salon.", confirmLabel: "Add promotional credit", callableName: "grantProinAsAdmin", payload: { accountId: salon.id, walletType: "salon_promotion_credits" }, fields: [{ key: "programId", label: "Manual salon credit program", type: "select", options: manualSalonPrograms.map((program) => ({ label: program.name, value: program.programId })) }, { key: "amountProin", label: "Credit to add (Proin)", type: "number", min: 1 }, { key: "sourceId", label: "Credit note or source ID", placeholder: "promotion-top-up-sep" }, { key: "idempotencyKey", label: "Unique reference", placeholder: "salon-credit-sep-001" }, reasonField] };
    const referralApprovalAction: AdminAction = { title: `${salon.proinReferralApproved ? "Stop" : "Approve"} referral rewards for ${salon.name}`, description: salon.proinReferralApproved ? "Referral Proin that involves this salon will wait until it is approved again. Rewards already granted are not changed." : "Allows referral Proin that involves this salon: rewards it earns as an inviter, and the salon referral that brought it in once it completes its first booking. This is separate from listing approval and is recorded in the administrator audit log.", confirmLabel: salon.proinReferralApproved ? "Stop referral rewards" : "Approve referral rewards", callableName: "updateSalonControlAsAdmin", payload: { salonId: salon.id, control: "proinReferralApproved", value: !salon.proinReferralApproved }, fields: [reasonField] };
    const settlementAction = (amountInr: number, settleAll = false): AdminAction => ({ title: `${settleAll ? "Settle full pending amount for" : "Record payment to"} ${salon.name}`, description: `Record a payment that was already made outside Pritze. ${settleAll ? "The full current pending balance will be allocated to the oldest outstanding booking records and reduced to zero." : "You may record any amount up to the current pending balance."} Choose Bank transfer, UPI, or Cash and retain its reference for the audit trail.`, confirmLabel: settleAll ? "Record full settlement" : "Record payment", callableName: "recordSalonSettlementPaymentAsAdmin", payload: { salonId: salon.id }, fields: [{ key: "amountInr", label: "Amount paid outside Pritze (₹)", type: "number", min: 0.01, step: 0.01, initialValue: String(Math.max(0, Math.round(amountInr * 100) / 100)) }, { key: "paymentMethod", label: "Payment method", type: "select", initialValue: "bank_transfer", options: [{ label: "Bank transfer", value: "bank_transfer" }, { label: "UPI", value: "upi" }, { label: "Cash", value: "cash" }] }, { key: "paymentReference", label: "Transaction, receipt or ledger reference", placeholder: "For cash, enter the cash receipt or ledger reference" }, { key: "paidAtMillis", label: "Payment completed at", type: "datetime-local", initialValue: dateTimeLocalValue(Date.now()) }, reasonField] });

    return <article className={`salon-card phase-two-card ${salon.adminSuspended ? "suspended" : ""}`} key={salon.id}>
      <div className="salon-card-top"><div className="salon-monogram">{initials(salon.name)}</div><span className={`open-state ${salon.adminSuspended ? "closed" : salon.isOpen ? "open" : "closed"}`}>{salon.adminSuspended ? "Suspended" : salon.isOpen ? "Open" : "Closed"}</span></div>
      <h2>{salon.name}</h2><p>{salon.address}</p>
      <div className="salon-id-row"><span>Salon ID</span><code>{salon.id}</code><button type="button" onClick={() => copySalonId(salon)}>Copy ID</button></div>
      <div className="salon-owner"><span>Owner</span><strong>{salon.ownerName}</strong></div>
      <div className="salon-stats"><div><strong>{salon.rating.toFixed(1)} ★</strong><span>{salon.reviewCount} reviews</span></div><div><strong>{salonBarbers.filter((barber) => barber.isActive).length}</strong><span>active barbers</span></div><div><strong>{completed.length}</strong><span>completed</span></div></div>
      <div className="salon-card-foot"><span>{salon.openTime}–{salon.closeTime}</span><span>{salon.instantBookingsEnabled ? "Instant on" : "Instant paused"}</span></div>
      <div className="salon-private-payment"><span>Private payout details</span><strong>{salon.paymentUpiId || "UPI ID not added"}</strong>{salon.paymentQrCodeUrl ? <a href={salon.paymentQrCodeUrl} target="_blank" rel="noreferrer">View payment QR</a> : <small>QR code not added</small>}</div>
      <section className="salon-finance-panel" aria-label={`${salon.name} finance`}><div className="salon-finance-heading"><div><span>Salon finance</span><small>External settlement and promotional credit</small></div><strong>{formatMoney(pendingSettlement)} pending</strong></div><div className="salon-finance-metrics"><div><span>Pending settlement</span><strong>{formatMoney(pendingSettlement)}</strong><small>{salonSettlements.filter((item) => item.status !== "paid").length} open booking records</small></div><div><span>Settled externally</span><strong>{formatMoney(settlementWallet?.paidAmount ?? 0)}</strong><small>Recorded payments</small></div><div><span>Promotional balance</span><strong>{formatProin(availableProin)}</strong><small>{formatProin(spendableProin)} available to spend</small></div><div><span>Salon credit limit</span><strong>{formatProin(creditLimit)}</strong><small>Maximum negative balance</small></div></div><div className="salon-finance-actions"><button disabled={!canOperate} onClick={() => onAdminAction(creditLimitAction)}>Change credit limit</button><button disabled={!canOperate || !manualSalonPrograms.length} onClick={() => onAdminAction(addCreditAction)}>Add promotional credit</button><button disabled={!canOperate} onClick={() => onAdminAction(referralApprovalAction)}>{salon.proinReferralApproved ? "Stop referral rewards" : "Approve referral rewards"}</button><button disabled={!canOperate || pendingSettlement <= 0} onClick={() => onAdminAction(settlementAction(pendingSettlement))}>Record external payment</button><button disabled={!canOperate || pendingSettlement <= 0} className="primary-control" onClick={() => onAdminAction(settlementAction(pendingSettlement, true))}>Settle full amount</button></div>{!manualSalonPrograms.length ? <small className="finance-hint">Create one manual salon-credit Proin program before adding a promotional credit.</small> : null}{!salon.proinReferralApproved ? <small className="finance-hint">Referral rewards are not approved for this salon, so referral Proin that involves it will wait.</small> : null}{pendingSettlement <= 0 ? <small className="finance-hint">Settlement actions unlock only when this salon has a pending Pritze payout.</small> : null}{paymentHistory.length ? <details className="salon-payment-history"><summary>Recent settlement history ({paymentHistory.length})</summary><div>{paymentHistory.map((payment) => <p key={payment.paymentId}><strong>{formatMoney(payment.amountInr)}</strong><span>{formatSettlementPaymentMethod(payment.paymentMethod)} · {payment.paymentReference} · {formatDateTime(payment.paidAtMillis)} · {payment.allocationCount} booking{payment.allocationCount === 1 ? "" : "s"}</span></p>)}</div></details> : <small className="finance-hint">No external settlement has been recorded for this salon yet.</small>}</section>
      <div className="control-cluster"><button disabled={!canOperate} className="primary-control" onClick={() => onAdminAction(salonProfileAction(salon))}>Edit profile</button><button disabled={!canOperate} onClick={() => onAdminAction(journeyCampaignAction(salonMap, undefined, salon))}>Create journey campaign</button><button disabled={!canOperate || salon.adminSuspended} onClick={() => onAdminAction(salonControl("isOpen", !salon.isOpen, salon.isOpen ? "Close salon" : "Open salon"))}>{salon.isOpen ? "Close" : "Open"}</button><button disabled={!canOperate || salon.adminSuspended} onClick={() => onAdminAction(salonControl("instantBookingsEnabled", !salon.instantBookingsEnabled, salon.instantBookingsEnabled ? "Pause instant bookings" : "Resume instant bookings"))}>{salon.instantBookingsEnabled ? "Pause instant" : "Resume instant"}</button><button disabled={!canOperate} className={salon.adminSuspended ? "" : "danger-link"} onClick={() => onAdminAction(salonControl("adminSuspended", !salon.adminSuspended, salon.adminSuspended ? "Restore salon" : "Suspend salon", !salon.adminSuspended))}>{salon.adminSuspended ? "Restore" : "Suspend"}</button><button disabled={!canOperate} onClick={() => onAdminAction(noteAction("salon", salon.id, salon.name))}>Note</button></div>
      {salon.services?.length ? <details className="service-controls"><summary>Manage all {salon.services.length} services</summary><div className="service-control-list">{salon.services.map((service) => <div key={service.id}><span>{service.name}<small>{formatMoney(service.price)} · {service.durationMinutes} min · {service.isAvailable ? "Available" : "Hidden"}</small></span><button disabled={!canOperate || salon.adminSuspended} onClick={() => onAdminAction(salonServiceAction(salon, service))}>Edit</button></div>)}</div></details> : null}
      <details className="service-controls team-controls"><summary>Manage team ({salonBarbers.length})</summary><div className="service-control-list">{salonBarbers.map((barber) => <div key={barber.id}><span>{barber.name}<small>{barber.speciality || "Team member"} · {barber.isActive ? "Active" : "Inactive"}</small></span><button disabled={!canOperate} onClick={() => onAdminAction(barberProfileAction(barber))}>Edit</button></div>)}{!salonBarbers.length ? <small>No team members added yet.</small> : null}</div></details>
    </article>;
  })}</div>;
}

function barberProfileAction(barber: Barber): AdminAction {
  return {
    title: `Edit ${barber.name}`,
    description: "Update this salon team member's contact details, skills, experience, service assignments and availability.",
    confirmLabel: "Save team member",
    callableName: "updateBarberProfileAsAdmin",
    payload: { barberId: barber.id },
    fields: [
      { key: "name", label: "Team member name", initialValue: barber.name },
      { key: "phone", label: "Phone number", type: "tel", initialValue: barber.phone, required: false },
      { key: "email", label: "Email", type: "email", initialValue: barber.email, required: false },
      { key: "speciality", label: "Speciality", initialValue: barber.speciality, required: false },
      { key: "experienceYears", label: "Experience (years)", type: "number", initialValue: String(barber.experienceYears), min: 0, max: 80 },
      { key: "resumeSummary", label: "Experience summary", type: "textarea", initialValue: barber.resumeSummary ?? "", required: false },
      { key: "serviceIds", label: "Assigned service IDs", type: "textarea", valueKind: "string-list", initialValue: (barber.serviceIds ?? []).join("\n"), required: false },
      { key: "isActive", label: "Active for bookings", type: "select", valueKind: "boolean", initialValue: String(barber.isActive), options: [{ label: "Yes", value: "true" }, { label: "No", value: "false" }] },
      reasonField,
    ],
  };
}

function campaignAppliesToSalon(campaign: DiscountCampaign, salonId: string): boolean {
  if (campaign.excludedSalonIds.includes(salonId)) return false;
  return campaign.salonIds.length === 0 || campaign.salonIds.includes(salonId);
}

type DiscountCampaignDisplayState = {
  key: "enabled" | "inactive" | "scheduled" | "ended" | "exhausted" | "blocked";
  label: string;
  detail: string;
};

function discountCampaignDisplayState(campaign: DiscountCampaign, usage: DiscountUsage | undefined, vault: DiscountVault, nowMillis: number): DiscountCampaignDisplayState {
  if (!campaign.active) return { key: "inactive", label: "Inactive", detail: "Disabled by an administrator" };
  if (campaign.startsAtMillis > 0 && campaign.startsAtMillis > nowMillis) return { key: "scheduled", label: "Scheduled", detail: "Enabled, but its start time has not arrived" };
  if (campaign.endsAtMillis > 0 && campaign.endsAtMillis <= nowMillis) return { key: "ended", label: "Ended", detail: "The end time passed; customers cannot use it" };
  const committed = (usage?.reservedPayoutAmount ?? 0) + (usage?.realizedPayoutAmount ?? 0);
  const canRequirePayout = campaign.salonPayoutPercent > 0 || Object.values(campaign.salonPayoutPercentByBookingNumber).some((percent) => percent > 0);
  if (canRequirePayout && committed >= campaign.totalPayoutBudget) return { key: "exhausted", label: "Budget exhausted", detail: "Reserved and completed payouts reached the campaign cap" };
  if (canRequirePayout && vault.availableAmount <= 0) return { key: "blocked", label: "Funding unavailable", detail: "The shared discount vault has no available funding" };
  return { key: "enabled", label: "Enabled", detail: "Customer, salon, service and use limits are checked at checkout" };
}

function SalonCampaignCards({ salons, data, search, onOpenDiscounts }: { salons: Salon[]; data: DiscountAdministrationData; search: string; onOpenDiscounts: () => void }) {
  const visibleSalons = salons.filter((salon) => !search || [salon.name, salon.ownerName, salon.address].some((value) => value.toLowerCase().includes(search)));
  const usageMap = new Map(data.campaignUsage.map((usage) => [usage.campaignId, usage]));
  const enabledCampaigns = data.campaigns.filter((campaign) => discountCampaignDisplayState(campaign, usageMap.get(campaign.campaignId), data.vault, data.generatedAtMillis).key === "enabled");

  return <section className="salon-campaign-section">
    <PanelHeader title="Campaigns enabled at each salon" subtitle="These campaigns are globally funded and inside their date window. Customer, service and use limits are still checked at checkout." />
    <div className="salon-campaign-grid">
      {visibleSalons.map((salon) => {
        const applicable = enabledCampaigns.filter((campaign) => campaignAppliesToSalon(campaign, salon.id));
        return <details className="salon-campaign-card" key={salon.id}>
          <summary><span className="salon-monogram">{initials(salon.name)}</span><span><strong>{salon.name}</strong><small>{applicable.length ? `${applicable.length} enabled ${applicable.length === 1 ? "campaign" : "campaigns"}` : "No enabled campaigns"}</small></span><b>View</b></summary>
          <div className="salon-campaign-list">
            {applicable.map((campaign) => {
              const bookingRules = bookingPayoutRulesText(campaign.salonPayoutPercentByBookingNumber);
              const offer = campaign.journeyMilestones.length ? `${campaign.journeyMilestones.length} private booking milestones` : campaign.discountType === "percent" ? `${campaign.discountPercent}% off` : `${formatMoney(campaign.fixedDiscountAmount)} off`;
              const cap = campaign.journeyMilestones.length ? campaign.journeyMilestones.map((milestone) => `#${milestone.bookingNumber}: ${milestone.rewardType.replace("_", " + ")}`).join(" · ") : campaign.maximumDiscountAmount > 0 ? `Maximum customer discount ${formatMoney(campaign.maximumDiscountAmount)}` : "No maximum customer discount";
              return <article key={campaign.campaignId}>
                <div><strong>{campaign.name}</strong><span className={campaign.voucherOnly ? "campaign-chip voucher" : "campaign-chip"}>{campaign.voucherOnly ? "Coupon" : "Automatic"}</span></div>
                <p>{offer} · {cap}</p>
                <small>Salon compensation: {campaign.salonPayoutPercent}% of the customer&apos;s discount{bookingRules ? ` · booking rules ${bookingRules}` : ""}</small>
              </article>;
            })}
            {!applicable.length ? <p className="campaign-empty">No funded campaign is currently inside its date window for this salon.</p> : null}
          </div>
          <button className="row-button" onClick={onOpenDiscounts}>Manage campaigns</button>
        </details>;
      })}
    </div>
    {!visibleSalons.length ? <EmptyState title="No salons found" detail="Try another salon name or clear the search." /> : null}
  </section>;
}

function BarbersView({ barbers, bookings, joinRequests, salonMap, search, canOperate, onAdminAction }: { barbers: Barber[]; bookings: Booking[]; joinRequests: JoinRequest[]; salonMap: Map<string, Salon>; search: string } & AdminControlProps) {
  const visible = barbers.filter((barber) => !search || [barber.name, barber.speciality, salonMap.get(barber.salonId)?.name ?? ""].some((value) => value.toLowerCase().includes(search)));
  const pendingRequests = joinRequests.filter((request) => request.status === "pending" && (!search || [request.barberName, request.speciality, salonMap.get(request.salonId)?.name ?? ""].some((value) => value.toLowerCase().includes(search))));
  return <><section className="panel main-panel"><div className="data-table barber-data phase-two-data"><div className="data-head"><span>Team member</span><span>Salon</span><span>Speciality</span><span>Workload</span><span>Status</span><span>Control</span></div>{visible.map((barber) => {
    const assigned = bookings.filter((booking) => booking.barberId === barber.id);
    const statusAction: AdminAction = { title: `${barber.isActive ? "Deactivate" : "Activate"} ${barber.name}`, description: "This changes whether the team member can receive future booking assignments.", confirmLabel: barber.isActive ? "Deactivate barber" : "Activate barber", callableName: "updateBarberStatusAsAdmin", payload: { barberId: barber.id, isActive: !barber.isActive }, fields: [reasonField], tone: barber.isActive ? "danger" : "default" };
    return <div className="data-row" key={barber.id}><div className="profile-cell"><div className="customer-avatar barber-avatar">{initials(barber.name)}</div><div><strong>{barber.name}</strong><span>{barber.phone}</span><small>{barber.experienceYears} years experience</small></div></div><strong>{salonMap.get(barber.salonId)?.name ?? "Unknown"}</strong><span>{barber.speciality}</span><span>{assigned.filter((booking) => isToday(booking.startMillis)).length} today · {assigned.filter((booking) => booking.status === "completed").length} completed</span><span className={`open-state ${barber.isActive ? "open" : "closed"}`}>{barber.isActive ? "Active" : "Inactive"}</span><div className="row-controls"><button disabled={!canOperate} onClick={() => onAdminAction(barberProfileAction(barber))}>Edit</button><button disabled={!canOperate} onClick={() => onAdminAction(statusAction)}>{barber.isActive ? "Deactivate" : "Activate"}</button><button disabled={!canOperate} onClick={() => onAdminAction(noteAction("barber", barber.id, barber.name))}>Note</button></div></div>;
  })}</div></section><section className="panel join-panel"><PanelHeader title="Pending join requests" subtitle="Phase 2 decisions require a reason and are recorded in the audit log." /><div className="join-list">{pendingRequests.length ? pendingRequests.map((request) => <div className="join-row phase-two-join" key={request.id}><div className="profile-cell"><div className="customer-avatar barber-avatar">{initials(request.barberName)}</div><div><strong>{request.barberName}</strong><span>{request.barberPhone}</span></div></div><div><span>Requested salon</span><strong>{salonMap.get(request.salonId)?.name ?? "Unknown"}</strong></div><div><span>Speciality</span><strong>{request.speciality || "Grooming"}</strong></div><time>{formatDateTime(request.requestedAtMillis)}</time><div className="row-controls"><button disabled={!canOperate} onClick={() => onAdminAction({ title: `Approve ${request.barberName}`, description: "Approval creates an active team record for the requested salon.", confirmLabel: "Approve request", callableName: "resolveJoinRequestAsAdmin", payload: { requestId: request.id, status: "approved" }, fields: [reasonField] })}>Approve</button><button disabled={!canOperate} className="danger-link" onClick={() => onAdminAction({ title: `Reject ${request.barberName}`, description: "The applicant will be notified that the request was not approved.", confirmLabel: "Reject request", callableName: "resolveJoinRequestAsAdmin", payload: { requestId: request.id, status: "rejected" }, fields: [reasonField], tone: "danger" })}>Reject</button></div></div>) : <EmptyState title="No pending requests" detail="New barber join requests will appear here." />}</div></section></>;
}

function ReviewsView({ reviews, search }: { reviews: Review[]; search: string }) {
  const visible = [...reviews].filter((review) => !search || [review.salonName, review.note].some((value) => value.toLowerCase().includes(search))).sort((a, b) => b.createdAtMillis - a.createdAtMillis);
  return <div className="review-grid">{visible.map((review) => <article className="review-card" key={review.id}><div className="review-top"><span className={`review-direction ${review.direction}`}>{review.direction === "salon" ? "Customer → Salon" : "Salon → Customer"}</span><span className="rating">{"★".repeat(review.rating)}<i>{"★".repeat(5 - review.rating)}</i></span></div><blockquote>“{review.note || "No written feedback."}”</blockquote><div className="review-foot"><div><strong>{review.salonName}</strong><span>Booking {review.bookingId}</span></div><time>{formatDateTime(review.createdAtMillis)}</time></div></article>)}</div>;
}

const automationRuleCopy: Record<AutomationRule["id"], { label: string; description: string; unit: string }> = {
  instant_response: { label: "Instant response monitor", description: "Flag instant requests that remain pending.", unit: "minutes" },
  overdue_arrival: { label: "Overdue arrival monitor", description: "Flag confirmed bookings after their expected time.", unit: "minutes" },
  unassigned_booking: { label: "Assignment monitor", description: "Detect active bookings without a barber.", unit: "minutes" },
  cancellation_spike: { label: "Cancellation anomaly", description: "Flag salons whose terminal bookings exceed this rate.", unit: "%" },
  low_rating: { label: "Quality threshold", description: "Flag salons below this average rating.", unit: "stars" },
};

function IntelligenceView({ data, salonMap, currentTime, canOperate, onAdminAction, onOpenBooking }: { data: AdminData; salonMap: Map<string, Salon>; currentTime: number; onOpenBooking: (bookingId: string) => void } & AdminControlProps) {
  const severityRank: Record<OperationalAlert["severity"], number> = { critical: 0, warning: 1, info: 2 };
  const alerts = [...data.operationalAlerts].filter((alert) => alert.status !== "resolved").sort((a, b) => severityRank[a.severity] - severityRank[b.severity] || b.detectedAtMillis - a.detectedAtMillis);
  const insights = buildDecisionInsights(data, currentTime, salonMap);
  const activeCount = alerts.filter((alert) => alert.status === "active").length;
  const enabledRules = data.automationRules.filter((rule) => rule.enabled).length;
  return <><section className="intelligence-hero"><div><span className="eyebrow">PHASE 3 · DECISION SUPPORT</span><h2>Operational intelligence</h2><p>Deterministic signals from current Firebase records. Automation creates alerts only; administrators remain responsible for every operational change.</p></div><button disabled={!canOperate} onClick={() => onAdminAction({ title: "Run intelligence scan", description: "This refreshes operational alerts from current bookings and salons. It will not change any booking, salon or staff record.", confirmLabel: "Run scan now", callableName: "runAdminIntelligenceScan", payload: {}, fields: [reasonField] })}>✦ Scan now</button></section><section className="metric-grid intelligence-metrics"><MetricCard label="Active alerts" value={String(activeCount)} detail={`${alerts.filter((item) => item.severity === "critical" && item.status === "active").length} critical`} tone="red" /><MetricCard label="Decision insights" value={String(insights.length)} detail="Workload, anomaly and finance signals" tone="blue" /><MetricCard label="Enabled monitors" value={`${enabledRules}/${data.automationRules.length}`} detail="Alert-only automation" tone="green" /><MetricCard label="Auto-actions" value="0" detail="Human approval remains required" tone="gold" /></section><section className="intelligence-layout"><div className="panel alert-panel"><PanelHeader title="Operational alerts" subtitle="Automatically detected exceptions requiring review." />{alerts.length ? <div className="operational-alerts">{alerts.map((alert) => <article className={`${alert.severity} ${alert.status}`} key={alert.id}><div className="alert-severity"><i />{titleCase(alert.severity)}</div><h3>{alert.title}</h3><p>{alert.detail}</p><div className="recommended-action"><span>Recommended next step</span><strong>{alert.recommendedAction}</strong></div><div className="alert-foot"><span>{salonMap.get(alert.salonId)?.name ?? titleCase(alert.targetType)} · {alert.targetId}</span><time>{formatDateTime(alert.detectedAtMillis)}</time></div><div className="row-controls">{alert.targetType === "booking" ? <button onClick={() => onOpenBooking(alert.targetId)}>Review booking</button> : null}{alert.status === "active" ? <button disabled={!canOperate} onClick={() => onAdminAction({ title: `Acknowledge: ${alert.title}`, description: "Acknowledgement records that an administrator reviewed this signal. The underlying operational record will not be changed.", confirmLabel: "Acknowledge alert", callableName: "acknowledgeAdminOperationalAlert", payload: { alertId: alert.id }, fields: [reasonField] })}>Acknowledge</button> : <span className="acknowledged-label">Acknowledged</span>}</div></article>)}</div> : <EmptyState title="No active alerts" detail="The latest intelligence scan found no configured exceptions." />}</div><aside className="panel insight-panel"><PanelHeader title="Decision recommendations" subtitle="Advisory signals—never automatic actions." />{insights.length ? <div className="insight-list">{insights.map((insight) => <article key={insight.id}><span className={`insight-category ${insight.category}`}>{titleCase(insight.category)}</span><h3>{insight.title}</h3><p>{insight.detail}</p><strong>{insight.recommendation}</strong></article>)}</div> : <EmptyState title="No recommendations" detail="Workload and anomaly signals will appear as activity grows." />}</aside></section><section className="panel automation-panel"><PanelHeader title="Controlled automation" subtitle="Configure alert thresholds. These rules never mutate bookings or salon operations." /><div className="automation-grid">{data.automationRules.map((rule) => { const copy = automationRuleCopy[rule.id]; return <article key={rule.id}><div className="automation-top"><span className={rule.enabled ? "enabled" : "disabled"}>{rule.enabled ? "Monitoring" : "Paused"}</span><button disabled={!canOperate} onClick={() => onAdminAction({ title: `${rule.enabled ? "Pause" : "Enable"} ${copy.label}`, description: `${copy.description} This changes alert generation only.`, confirmLabel: rule.enabled ? "Pause monitor" : "Enable monitor", callableName: "updateAdminAutomationRule", payload: { ruleId: rule.id, enabled: !rule.enabled, threshold: rule.threshold }, fields: [reasonField], tone: rule.enabled ? "danger" : "default" })}>{rule.enabled ? "Pause" : "Enable"}</button></div><h3>{copy.label}</h3><p>{copy.description}</p><div className="threshold-row"><span>Threshold</span><strong>{rule.threshold} {copy.unit}</strong><button disabled={!canOperate} onClick={() => onAdminAction({ title: `Change ${copy.label} threshold`, description: `Current threshold: ${rule.threshold} ${copy.unit}.`, confirmLabel: "Update threshold", callableName: "updateAdminAutomationRule", payload: { ruleId: rule.id, enabled: rule.enabled }, fields: [{ key: "threshold", label: `New threshold (${copy.unit})`, type: "text", placeholder: String(rule.threshold) }, reasonField] })}>Adjust</button></div></article>; })}</div></section></>;
}

function buildDecisionInsights(data: AdminData, currentTime: number, salonMap: Map<string, Salon>): DecisionInsight[] {
  const insights: DecisionInsight[] = [];
  for (const salon of data.salons) {
    const activeBarbers = data.barbers.filter((barber) => barber.salonId === salon.id && barber.isActive);
    const workloads = activeBarbers.map((barber) => ({ barber, count: data.bookings.filter((booking) => booking.barberId === barber.id && isToday(booking.startMillis) && !["cancelled", "rejected"].includes(booking.status)).length })).sort((a, b) => b.count - a.count);
    if (workloads.length >= 2 && workloads[0].count - workloads[workloads.length - 1].count >= 2) {
      insights.push({ id: `workload-${salon.id}`, category: "workload", severity: "info", title: `Workload imbalance at ${salon.name}`, detail: `${workloads[0].barber.name} has ${workloads[0].count} bookings today while ${workloads[workloads.length - 1].barber.name} has ${workloads[workloads.length - 1].count}.`, recommendation: "Review skills and availability before reassigning future appointments." });
    }
    const terminal = data.bookings.filter((booking) => booking.salonId === salon.id && ["completed", "cancelled", "rejected"].includes(booking.status));
    const cancelled = terminal.filter((booking) => ["cancelled", "rejected"].includes(booking.status));
    if (terminal.length >= 3 && cancelled.length / terminal.length >= .34) {
      insights.push({ id: `cancellation-${salon.id}`, category: "anomaly", severity: "warning", title: `Cancellation pattern at ${salon.name}`, detail: `${Math.round(cancelled.length / terminal.length * 100)}% of terminal bookings were cancelled or rejected.`, recommendation: "Compare reasons, busy hours and staffing before changing availability." });
    }
  }
  for (const booking of data.bookings.filter((item) => item.status === "inProgress" && item.startedAtMillis)) {
    const expectedEnd = (booking.startedAtMillis ?? 0) + booking.durationMinutes * minute;
    if (currentTime > expectedEnd + 15 * minute) insights.push({ id: `overrun-${booking.id}`, category: "anomaly", severity: "warning", title: `Service duration overrun for ${booking.id}`, detail: `${booking.customerName}'s service is more than 15 minutes beyond its expected duration.`, recommendation: "Check with the salon before completing or cancelling the booking." });
  }
  for (const wallet of data.wallets) {
    const payable = data.settlements.filter((item) => item.salonId === wallet.salonId && item.status === "payable").reduce((sum, item) => sum + item.pritzePayoutAmount, 0);
    if (Math.abs(payable - wallet.payableBalance) >= 1) insights.push({ id: `finance-${wallet.salonId}`, category: "finance", severity: "warning", title: `Settlement balance mismatch at ${salonMap.get(wallet.salonId)?.name ?? "a salon"}`, detail: `Wallet shows ${formatMoney(wallet.payableBalance)} payable while loaded settlements total ${formatMoney(payable)}.`, recommendation: "Reconcile records before confirming any external transfer." });
  }
  return insights.slice(0, 12);
}

function SettlementsView({ settlements, wallets, salonMap, currentTime, canOperate, onAdminAction }: { settlements: Settlement[]; wallets: SalonWallet[]; salonMap: Map<string, Salon>; currentTime: number } & AdminControlProps) {
  const payable = [...settlements].filter((item) => item.status === "payable").sort((a, b) => b.createdAtMillis - a.createdAtMillis);
  const partiallyPaid = [...settlements].filter((item) => item.status === "partially_paid").sort((a, b) => b.createdAtMillis - a.createdAtMillis);
  const paid = [...settlements].filter((item) => item.status === "paid").sort((a, b) => b.paidAtMillis - a.paidAtMillis);
  const outstanding = [...payable, ...partiallyPaid];

  function markPaidAction(settlement: Settlement): AdminAction {
    return {
      title: `Record full payment for ${settlement.bookingId}`,
      description: `Record the external payment of ${formatMoney(settlement.outstandingAmount || settlement.pritzePayoutAmount)} to ${salonMap.get(settlement.salonId)?.name ?? "the salon"}. Choose the real payment method and keep an audit reference.`,
      confirmLabel: "Record payment",
      callableName: "markSalonSettlementPaid",
      payload: {bookingId: settlement.bookingId},
      fields: [
        {key: "paymentMethod", label: "Payment method", type: "select", initialValue: "bank_transfer", options: [{label: "Bank transfer", value: "bank_transfer"}, {label: "UPI", value: "upi"}, {label: "Cash", value: "cash"}]},
        {key: "paymentReference", label: "Transaction, receipt or ledger reference", placeholder: "For cash, enter the cash receipt or ledger reference"},
        {key: "paidAtMillis", label: "Payment completed at", type: "datetime-local", initialValue: dateTimeLocalValue(currentTime)},
        reasonField,
      ],
    };
  }

  return <>
    <section className="report-grid">
      <MetricCard label="Payable now" value={formatMoney(wallets.reduce((sum, wallet) => sum + wallet.payableBalance, 0))} detail={`${outstanding.length} open booking settlements`} tone="red" />
      <MetricCard label="Paid externally" value={formatMoney(wallets.reduce((sum, wallet) => sum + wallet.paidAmount, 0))} detail={`${paid.length} reconciled settlements`} tone="green" />
      <MetricCard label="Lifetime Pritze earnings" value={formatMoney(wallets.reduce((sum, wallet) => sum + wallet.lifetimePritzeEarnings, 0))} detail="Across loaded salon wallets" tone="gold" />
    </section>
    <section className="panel main-panel">
      <PanelHeader title="Outstanding settlements" subtitle="Confirm only after the external payment has actually been made. Choose Bank transfer, UPI or Cash and retain its reference." />
      <div className="data-table customer-data">
        <div className="data-head"><span>Salon / booking</span><span>Counter paid</span><span>Pritze payout</span><span>Salon total</span><span>Action</span></div>
        {outstanding.map((item) => <div className="data-row" key={item.bookingId}><div><strong>{salonMap.get(item.salonId)?.name ?? "Unknown salon"}</strong><small>{item.bookingId}{item.status === "partially_paid" ? " · Partially paid" : ""}</small></div><span>{formatMoney(item.customerCounterAmount)}</span><strong>{formatMoney(item.outstandingAmount || item.pritzePayoutAmount)}</strong><span>{formatMoney(item.salonTotalEarning)}</span><button className="row-button" disabled={!canOperate || item.status === "partially_paid"} onClick={() => onAdminAction(markPaidAction(item))}>{item.status === "partially_paid" ? "Use salon card" : "Record payment"}</button></div>)}
      </div>
      {!outstanding.length ? <EmptyState title="Nothing payable" detail="Completed discounted bookings will appear here." /> : null}
    </section>
    <section className="panel main-panel">
      <PanelHeader title="Paid history" subtitle="External payment references are retained for reconciliation." />
      <div className="join-list">{paid.slice(0, 100).map((item) => <div className="join-row" key={item.bookingId}><div><strong>{salonMap.get(item.salonId)?.name ?? "Unknown salon"}</strong><span>{item.bookingId}</span></div><div><span>Pritze payout</span><strong>{formatMoney(item.pritzePayoutAmount)}</strong></div><div><span>{formatSettlementPaymentMethod(item.paymentMethod)} reference</span><strong>{item.paymentReference}</strong></div><time>{formatDateTime(item.paidAtMillis)}</time></div>)}</div>
    </section>
  </>;
}

function DiscountOperationsView({ data, customerMap, salonMap, canOperate, onAdminAction }: { data: DiscountAdministrationData; customerMap: Map<string, Customer>; salonMap: Map<string, Salon> } & AdminControlProps) {
  const usageMap = new Map(data.campaignUsage.map((item) => [item.campaignId ?? "", item]));
  const salonBurn = [...data.salonTotals].sort((a, b) => (b.realizedPayoutAmount + b.reservedPayoutAmount) - (a.realizedPayoutAmount + a.reservedPayoutAmount));
  const customerBurn = [...data.customerTotals].sort((a, b) => (b.realizedPayoutAmount + b.reservedPayoutAmount) - (a.realizedPayoutAmount + a.reservedPayoutAmount));
  const booleanOptions = [{ label: "No", value: "false" }, { label: "Yes", value: "true" }];

  function campaignAction(campaign?: DiscountCampaign): AdminAction {
    const start = campaign?.startsAtMillis || Date.now();
    const end = campaign?.endsAtMillis || Date.now() + 30 * day;
    return {
      title: campaign ? `Edit ${campaign.name}` : "Create discount or voucher",
      description: "Create an automatic offer or require a customer-entered voucher code. Cap its maximum rupee discount, then set the salon's compensation as a percentage of that discount for every booking or specific customer booking numbers.",
      confirmLabel: campaign ? "Save new version" : "Create inactive campaign",
      callableName: "upsertDiscountCampaignAsAdmin",
      payload: campaign ? { campaignId: campaign.campaignId, expectedVoucherCodeHash: campaign.voucherCodeHash } : {},
      fields: [
        ...(campaign ? [] : [{ key: "campaignId", label: "Campaign ID", placeholder: "first_visit_aug_2026" } as AdminActionField]),
        { key: "name", label: "Campaign name", initialValue: campaign?.name ?? "" },
        { key: "active", label: "Campaign active", type: "select", valueKind: "boolean", initialValue: String(campaign?.active ?? false), options: booleanOptions },
        { key: "priority", label: "Priority (higher wins)", type: "number", min: 0, initialValue: String(campaign?.priority ?? 0) },
        { key: "voucherOnly", label: "Discount delivery type", type: "select", valueKind: "boolean", initialValue: String(campaign?.voucherOnly ?? false), options: [{ label: "Automatic discount (no code)", value: "false" }, { label: "Coupon / voucher campaign", value: "true" }] },
        { key: "visibleAtCheckout", label: "Coupon visibility in app", type: "select", valueKind: "boolean", initialValue: String(campaign?.visibleAtCheckout ?? false), options: [{ label: "Hidden typed-code coupon", value: "false" }, { label: "Visible checkout offer", value: "true" }] },
        { key: "fundingSource", label: "Campaign funding source", type: "select", initialValue: campaign?.fundingSource ?? "salon_promotion_credits", options: [{ label: "Salon promotional credits", value: "salon_promotion_credits" }, { label: "Platform discount vault", value: "platform_vault" }] },
        { key: "voucherCode", label: campaign?.voucherOnly ? "New voucher code (leave blank to keep current)" : "Voucher code (required only for code campaigns)", placeholder: "SAVE", required: false },
        { key: "discountType", label: "Discount type", type: "select", initialValue: campaign?.discountType ?? "percent", options: [{ label: "Percentage off", value: "percent" }, { label: "Fixed rupee amount", value: "fixed" }] },
        { key: "discountPercent", label: "Customer discount (%)", type: "number", min: 0.01, max: 100, step: 0.01, initialValue: String(campaign?.discountPercent ?? 10) },
        { key: "fixedDiscountAmount", label: "Fixed discount (₹, used only for fixed type)", type: "number", min: 1, initialValue: String(campaign?.fixedDiscountAmount || 100) },
        { key: "salonPayoutPercent", label: "Salon compensation (% of customer discount)", type: "number", min: 0, max: 1000, step: 0.01, initialValue: String(campaign?.salonPayoutPercent ?? 200) },
        { key: "salonPayoutPercentByBookingNumber", label: "Compensation by customer booking number (optional)", type: "textarea", valueKind: "booking-payout-rules", placeholder: "1:100, 2:0, 3:2", required: false, initialValue: bookingPayoutRulesText(campaign?.salonPayoutPercentByBookingNumber) },
        { key: "cashbackProinAmount", label: "Proin cashback after completion", type: "number", min: 0, initialValue: String(campaign?.cashbackProinAmount ?? 0) },
        { key: "cashbackValidityDays", label: "Cashback validity (days)", type: "number", min: 0, max: 730, initialValue: String(campaign?.cashbackValidityDays ?? 30) },
        { key: "cashbackTotalBudgetProin", label: "Cashback budget (Proin)", type: "number", min: 0, initialValue: String(campaign?.cashbackTotalBudgetProin ?? 0) },
        { key: "totalPayoutBudget", label: "Campaign salon-compensation budget (₹, 0 only if compensation is 0%)", type: "number", min: 0, initialValue: String(campaign?.totalPayoutBudget ?? 10000) },
        { key: "perSalonPayoutBudget", label: "Per-salon payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: String(campaign?.perSalonPayoutBudget ?? 0) },
        { key: "perCustomerPayoutBudget", label: "Per-customer payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: String(campaign?.perCustomerPayoutBudget ?? 0) },
        { key: "maximumUsesPerCustomer", label: "Maximum uses per customer", type: "number", min: 1, initialValue: String(campaign?.maximumUsesPerCustomer ?? 1) },
        { key: "maximumDiscountAmount", label: "Maximum customer discount this coupon can give (₹, 0 = no cap)", type: "number", min: 0, initialValue: String(campaign?.maximumDiscountAmount ?? 0) },
        { key: "minimumServiceAmount", label: "Minimum service total (₹)", type: "number", min: 0, initialValue: String(campaign?.minimumServiceAmount ?? 0) },
        { key: "startsAtMillis", label: "Campaign starts", type: "datetime-local", initialValue: dateTimeLocalValue(start), required: false },
        { key: "endsAtMillis", label: "Campaign ends", type: "datetime-local", initialValue: dateTimeLocalValue(end), required: false },
        { key: "salonIds", label: "Eligible salons (leave all unchecked for every salon)", type: "checkbox-list", valueKind: "string-list", required: false, initialValue: campaign?.salonIds.join("\n") ?? "", options: [...salonMap.values()].sort((left, right) => left.name.localeCompare(right.name)).map((salon) => ({ label: `${salon.name} — ${salon.id}`, value: salon.id })) },
        { key: "excludedSalonIds", label: "Excluded salon IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.excludedSalonIds.join(", ") ?? "" },
        { key: "customerUids", label: "Eligible customer UIDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.customerUids.join(", ") ?? "" },
        { key: "serviceIds", label: "Eligible service IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: campaign?.serviceIds.join(", ") ?? "" },
        { key: "eligibleBookingNumbers", label: "Show only on these customer booking numbers (enter 3 for third booking)", type: "textarea", valueKind: "number-list", placeholder: "3", required: false, initialValue: campaign?.eligibleBookingNumbers.join(", ") ?? "" },
        { key: "minimumBookingNumber", label: "First customer booking number eligible", type: "number", min: 1, initialValue: String(campaign?.minimumBookingNumber ?? 1) },
        { key: "maximumBookingNumber", label: "Last customer booking number eligible (0 = no maximum)", type: "number", min: 0, initialValue: String(campaign?.maximumBookingNumber ?? 0) },
        { key: "newToSalonOnly", label: "Only customers new to the salon", type: "select", valueKind: "boolean", initialValue: String(campaign?.newToSalonOnly ?? false), options: booleanOptions },
        { key: "returningToSalonOnly", label: "Only returning salon customers", type: "select", valueKind: "boolean", initialValue: String(campaign?.returningToSalonOnly ?? false), options: booleanOptions },
        { key: "termsVersion", label: "Terms version", initialValue: campaign?.termsVersion ?? "discount-v1" },
        reasonField,
      ],
    };
  }

  const vaultAction: AdminAction = {
    title: "Change discount finance controls",
      description: "Set the maximum real-money exposure and each salon's credit line. The global multiplier remains only as a fallback for older campaigns; new campaigns set salon compensation directly.",
    confirmLabel: "Save finance controls",
    callableName: "setDiscountVaultBudgetAsAdmin",
    payload: {},
    fields: [
      { key: "approvedAmount", label: "Approved discount vault (₹)", type: "number", min: 0, initialValue: String(data.vault.approvedAmount) },
      { key: "salonCreditLimitAmount", label: "Salon credit line per salon (Proin)", type: "number", min: 0, initialValue: String(data.vault.salonCreditLimitAmount) },
      { key: "salonDiscountBurnMultiplier", label: "Salon discount burn multiplier", type: "number", min: 1, max: 10, step: 0.01, initialValue: String(data.vault.salonDiscountBurnMultiplier) },
      reasonField,
    ],
  };

  function starterDiscountAction(kind: "automatic" | "hiddenVoucher" | "visibleVoucher"): AdminAction {
    const isVoucher = kind !== "automatic";
    const isVisible = kind === "visibleVoucher";
    const start = Date.now();
    const prefix = isVisible ? "visible_save10_test" : isVoucher ? "hidden_save10_test" : "first_booking_10_test";
    return {
      title: isVisible ? "Create starter visible checkout offer" : isVoucher ? "Create starter hidden coupon" : "Create starter automatic discount",
      description: isVisible
        ? "Creates an inactive visible checkout offer draft. After review and activation, eligible customers see it below the final price and tap Apply before booking."
        : isVoucher
        ? "Creates an inactive hidden coupon draft for testing typed checkout codes. Customers will not see it in the app; share the code verbally or by campaign message after activation."
        : "Creates an inactive first-booking discount draft. Review the dates, audience and burn caps before activating.",
      confirmLabel: isVisible ? "Create visible offer draft" : isVoucher ? "Create hidden coupon draft" : "Create discount draft",
      callableName: "upsertDiscountCampaignAsAdmin",
      payload: {},
      fields: [
        { key: "campaignId", label: "Campaign ID", initialValue: draftId(prefix) },
        { key: "name", label: "Campaign name", initialValue: isVisible ? "Test visible SAVE10 offer" : isVoucher ? "Test hidden SAVE10 coupon" : "Test first booking 10%" },
        { key: "active", label: "Campaign active", type: "select", valueKind: "boolean", initialValue: "false", options: booleanOptions },
        { key: "priority", label: "Priority (higher wins)", type: "number", min: 0, initialValue: isVisible ? "30" : isVoucher ? "20" : "10" },
        { key: "voucherOnly", label: "Discount delivery type", type: "select", valueKind: "boolean", initialValue: String(isVoucher), options: [{ label: "Automatic discount (no code)", value: "false" }, { label: "Coupon / voucher campaign", value: "true" }] },
        { key: "visibleAtCheckout", label: "Coupon visibility in app", type: "select", valueKind: "boolean", initialValue: String(isVisible), options: [{ label: "Hidden typed-code coupon", value: "false" }, { label: "Visible checkout offer", value: "true" }] },
        { key: "fundingSource", label: "Campaign funding source", type: "select", initialValue: "salon_promotion_credits", options: [{ label: "Salon promotional credits", value: "salon_promotion_credits" }, { label: "Platform discount vault", value: "platform_vault" }] },
        { key: "voucherCode", label: "Voucher code", placeholder: "SAVE10", initialValue: isVoucher ? isVisible ? "VISIBLE10" : "SAVE10" : "", required: isVoucher },
        { key: "discountType", label: "Discount type", type: "select", initialValue: "percent", options: [{ label: "Percentage off", value: "percent" }, { label: "Fixed rupee amount", value: "fixed" }] },
        { key: "discountPercent", label: "Customer discount (%)", type: "number", min: 0.01, max: 100, step: 0.01, initialValue: "10" },
        { key: "fixedDiscountAmount", label: "Fixed discount (₹, used only for fixed type)", type: "number", min: 1, initialValue: "100" },
        { key: "salonPayoutPercent", label: "Salon compensation (% of customer discount)", type: "number", min: 0, max: 1000, step: 0.01, initialValue: "100" },
        { key: "salonPayoutPercentByBookingNumber", label: "Compensation by customer booking number (optional)", type: "textarea", valueKind: "booking-payout-rules", placeholder: "1:100, 2:0, 3:2", required: false, initialValue: "" },
        { key: "cashbackProinAmount", label: "Proin cashback after completion", type: "number", min: 0, initialValue: "0" },
        { key: "cashbackValidityDays", label: "Cashback validity (days)", type: "number", min: 0, max: 730, initialValue: "30" },
        { key: "cashbackTotalBudgetProin", label: "Cashback budget (Proin)", type: "number", min: 0, initialValue: "0" },
        { key: "totalPayoutBudget", label: "Campaign salon-compensation budget (₹, 0 only if compensation is 0%)", type: "number", min: 0, initialValue: "1000" },
        { key: "perSalonPayoutBudget", label: "Per-salon payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: "300" },
        { key: "perCustomerPayoutBudget", label: "Per-customer payout cap (₹, 0 = no cap)", type: "number", min: 0, initialValue: "100" },
        { key: "maximumUsesPerCustomer", label: "Maximum uses per customer", type: "number", min: 1, initialValue: "1" },
        { key: "maximumDiscountAmount", label: "Maximum customer discount this coupon can give (₹, 0 = no cap)", type: "number", min: 0, initialValue: "100" },
        { key: "minimumServiceAmount", label: "Minimum service total (₹)", type: "number", min: 0, initialValue: "100" },
        { key: "startsAtMillis", label: "Campaign starts", type: "datetime-local", initialValue: dateTimeLocalValue(start), required: false },
        { key: "endsAtMillis", label: "Campaign ends", type: "datetime-local", initialValue: dateTimeLocalValue(start + 14 * day), required: false },
        { key: "salonIds", label: "Eligible salon IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "excludedSalonIds", label: "Excluded salon IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "customerUids", label: "Eligible customer UIDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "serviceIds", label: "Eligible service IDs (optional)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "eligibleBookingNumbers", label: "Exact booking numbers (optional, comma separated)", type: "textarea", valueKind: "number-list", required: false, initialValue: isVoucher ? "" : "1" },
        { key: "minimumBookingNumber", label: "Minimum completed booking number", type: "number", min: 1, initialValue: "1" },
        { key: "maximumBookingNumber", label: "Maximum booking number (0 = no maximum)", type: "number", min: 0, initialValue: isVoucher ? "0" : "1" },
        { key: "newToSalonOnly", label: "Only customers new to the salon", type: "select", valueKind: "boolean", initialValue: "false", options: booleanOptions },
        { key: "returningToSalonOnly", label: "Only returning salon customers", type: "select", valueKind: "boolean", initialValue: "false", options: booleanOptions },
        { key: "termsVersion", label: "Terms version", initialValue: "test-discount-v1" },
        { ...reasonField, initialValue: isVisible ? "Create inactive visible checkout offer draft for controlled app testing." : isVoucher ? "Create inactive hidden coupon draft for controlled app testing." : "Create inactive automatic discount draft for controlled app testing." },
      ],
    };
  }

  return <>
    <section className="discount-hero">
      <div><p className="eyebrow">REAL-MONEY PROMOTION CONTROL</p><h2>Discount operations</h2><p>Configure which customer sees which discount, cap every burn path and monitor the amount Pritze owes salons. Salon-funded campaigns can use each salon promotional Proin balance down to the approved credit line.</p></div>
      <div className="discount-vault-state"><span>₹</span><div><small>Discount vault v{data.vault.budgetVersion}</small><strong>{formatMoney(data.vault.availableAmount)} available</strong><time>{formatMoney(data.vault.reservedAmount + data.vault.spentAmount)} committed</time></div></div>
    </section>

    <section className="metric-grid discount-metrics" aria-label="Discount financial position">
      <MetricCard label="Approved vault" value={formatMoney(data.vault.approvedAmount)} detail="Maximum approved exposure" tone="gold" />
      <MetricCard label="Available" value={formatMoney(data.vault.availableAmount)} detail="Uncommitted campaign funding" tone="green" />
      <MetricCard label="Reserved" value={formatMoney(data.vault.reservedAmount)} detail={`${data.platformTotals.reservedUses} active booking uses`} tone="blue" />
      <MetricCard label="Realized burn" value={formatMoney(data.vault.spentAmount)} detail={`${data.platformTotals.realizedUses} completed uses`} tone="red" />
      <MetricCard label="Salon credit line" value={formatProin(data.vault.salonCreditLimitAmount)} detail="Allowed negative balance per salon" tone="gold" />
      <MetricCard label="Legacy salon fallback" value={`${data.vault.salonDiscountBurnMultiplier}×`} detail="Used only by older campaigns without a compensation percentage" tone="red" />
    </section>

    <section className="discount-command-panel">
      <div><p className="eyebrow">CONFIGURATION & CONTROL</p><strong>Manage discount eligibility and burn</strong><span>Campaign edits are versioned. Budgets can never be reduced below reserved and realized payout.</span></div>
      <div className="discount-command-buttons"><button disabled={!canOperate} onClick={() => onAdminAction(campaignAction())}>New discount / voucher</button><button disabled={!canOperate} onClick={() => onAdminAction(journeyCampaignAction(salonMap))}>New journey campaign</button><button className="quiet" disabled={!canOperate} onClick={() => onAdminAction(vaultAction)}>Change finance controls</button></div>
    </section>

    <section className="starter-panel discount-starter" aria-label="Discount starter setup">
      <div><p className="eyebrow">SAFE STARTER SETUP</p><strong>Create drafts you can inspect before activating</strong><span>These buttons prefill small, inactive test campaigns. They do not show discounts to customers until you edit the draft and switch Active to Yes.</span></div>
      <div className="starter-grid">
        <article><b>01</b><strong>Automatic 10% first-booking draft</strong><p>Use this to test automatic discounts, first-booking targeting, burn caps and the receipt breakdown.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterDiscountAction("automatic"))}>Create automatic draft</button></article>
        <article><b>02</b><strong>SAVE10 hidden coupon draft</strong><p>Use this when you want to verbally share a code. It stays invisible in the app but works when typed at checkout.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterDiscountAction("hiddenVoucher"))}>Create hidden coupon draft</button></article>
        <article><b>03</b><strong>VISIBLE10 checkout offer draft</strong><p>Use this when eligible customers should see one small Apply row below the final price before booking.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterDiscountAction("visibleVoucher"))}>Create visible offer draft</button></article>
      </div>
    </section>

    <section className="panel main-panel discount-panel">
      <PanelHeader title="Discount campaigns" subtitle="Set the coupon cap, customer eligibility and the salon compensation percentage together." />
      <div className="data-table discount-campaign-table">
        <div className="data-head"><span>Campaign</span><span>Offer / payout</span><span>Burn</span><span>Audience / window</span><span>Action</span></div>
        {[...data.campaigns].sort((a, b) => Number(b.active) - Number(a.active) || b.priority - a.priority).map((campaign) => {
          const usage = usageMap.get(campaign.campaignId);
          const committed = (usage?.reservedPayoutAmount ?? 0) + (usage?.realizedPayoutAmount ?? 0);
          const displayState = discountCampaignDisplayState(campaign, usage, data.vault, data.generatedAtMillis);
          const audience = campaign.salonIds.length ? `${campaign.salonIds.length} salons` : campaign.customerUids.length ? `${campaign.customerUids.length} customers` : "All eligible salons";
          const journey = campaign.journeyMilestones.length > 0;
          const offer = journey ? `${campaign.journeyMilestones.length} booking rewards` : campaign.discountType === "fixed" ? `${formatMoney(campaign.fixedDiscountAmount)} off` : `${campaign.discountPercent}% off`;
          const delivery = campaign.voucherOnly ? `${campaign.visibleAtCheckout ? "Visible checkout offer" : "Hidden typed-code coupon"} · ${campaign.voucherMaskedCode || "code protected"}` : "Automatic offer";
          const funding = campaign.fundingSource === "platform_vault" ? "Platform vault" : "Salon credits";
          const compensation = `${campaign.salonPayoutPercent}% of customer discount`;
          const bookingRules = bookingPayoutRulesText(campaign.salonPayoutPercentByBookingNumber);
          const cashback = campaign.cashbackProinAmount > 0 ? ` · up to ${campaign.cashbackProinAmount} Proin after completion` : "";
          const milestoneSummary = journey ? campaign.journeyMilestones.map((milestone) => `#${milestone.bookingNumber} ${milestone.rewardType === "discount_proin" ? "discount + Proin" : milestone.rewardType}`).join(" · ") : "";
          return <div className="data-row" key={campaign.campaignId}><div><strong>{campaign.name}</strong><small>{journey ? "Private journey logic" : delivery} · {campaign.campaignId} · priority {campaign.priority} · v{campaign.version}</small></div><div><strong>{offer}</strong><small>{milestoneSummary || compensation}{bookingRules ? ` · booking rules ${bookingRules}` : ""} · {funding}{cashback}</small></div><div><strong>{formatMoney(committed)} / {formatMoney(campaign.totalPayoutBudget)}</strong><small>{formatMoney(usage?.reservedPayoutAmount ?? 0)} reserved · {usage?.realizedUses ?? 0} completed</small></div><div><span className={`proin-state ${displayState.key === "enabled" ? "active" : displayState.key}`}>{displayState.label}</span><small>{displayState.detail} · {audience} · {campaign.startsAtMillis ? formatDateTime(campaign.startsAtMillis) : "No start"} – {campaign.endsAtMillis ? formatDateTime(campaign.endsAtMillis) : "No expiry"}</small></div><button className="control-button" disabled={!canOperate} onClick={() => onAdminAction(journey ? journeyCampaignAction(salonMap, campaign) : campaignAction(campaign))}>Edit</button></div>;
        })}
      </div>
      {!data.campaigns.length ? <EmptyState title="No discount campaigns" detail="Create an inactive, capped campaign before showing any customer discount." /> : null}
    </section>

    <section className="discount-burn-grid">
      <article className="panel"><PanelHeader title="Burn by salon" subtitle="Reserved plus realized Pritze payout exposure" /><div className="discount-burn-list">{salonBurn.slice(0, 100).map((item) => <div key={item.salonId}><div><strong>{salonMap.get(item.salonId)?.name ?? item.salonId}</strong><span>{item.realizedUses} completed · {item.reservedUses} reserved</span></div><div><b>{formatMoney(item.realizedPayoutAmount + item.reservedPayoutAmount)}</b><small>{formatMoney(item.realizedDiscountAmount)} customer discount realized</small></div></div>)}</div>{!salonBurn.length ? <EmptyState title="No salon burn" detail="Salon-level totals appear after the first eligible booking." /> : null}</article>
      <article className="panel"><PanelHeader title="Burn by customer" subtitle="Customer-specific exposure and usage" /><div className="discount-burn-list">{customerBurn.slice(0, 100).map((item) => <div key={item.customerUid}><div><strong>{customerMap.get(item.customerUid)?.name ?? item.customerUid}</strong><span>{item.realizedUses} completed · {item.reservedUses} reserved</span></div><div><b>{formatMoney(item.realizedPayoutAmount + item.reservedPayoutAmount)}</b><small>{formatMoney(item.realizedDiscountAmount)} discount received</small></div></div>)}</div>{!customerBurn.length ? <EmptyState title="No customer burn" detail="Customer-level totals appear after the first eligible booking." /> : null}</article>
    </section>
  </>;
}

function ProinOperationsView({ data, customerMap, salonMap, canOperate, onAdminAction }: { data: ProinAdminData; customerMap: Map<string, Customer>; salonMap: Map<string, Salon> } & AdminControlProps) {
  const currentTime = data.generatedAtMillis || now;
  const finance = data.finance;
  const payable = [...data.reimbursements].filter((item) => item.status === "payable").sort((a, b) => b.createdAtMillis - a.createdAtMillis);
  const settled = [...data.reimbursements].filter((item) => item.status === "settled").sort((a, b) => b.paidAtMillis - a.paidAtMillis);
  const revocableLots = [...data.lots].filter((lot) => lot.status === "active" && lot.availableProin > 0 && lot.expiresAtMillis > currentTime).sort((a, b) => a.expiresAtMillis - b.expiresAtMillis);
  const customerWallets = [...data.wallets].filter((wallet) => wallet.walletType === "customer_rewards").sort((a, b) => b.availableProin - a.availableProin);
  const salonWallets = [...data.wallets].filter((wallet) => wallet.walletType === "salon_promotion_credits").sort((a, b) => a.availableProin - b.availableProin);
  const latestReport = [...data.reconciliationReports].sort((a, b) => b.createdAtMillis - a.createdAtMillis)[0];
  const isBalanced = latestReport?.status === "balanced" && latestReport.financeBalanced && latestReport.financeMatchesLots;
  const usageMap = new Map(data.programUsage.map((item) => [item.programId, item]));
  const couponUsageMap = new Map(data.couponUsage.map((item) => [item.codeHash, item]));
  const manualPrograms = data.programs.filter((program) => program.sourceType === "manual");
  const couponPrograms = data.programs.filter((program) => program.sourceType === "coupon");
  const customerCouponProgram = couponPrograms.find((program) => program.walletType === "customer_rewards");
  const salonCouponProgram = couponPrograms.find((program) => program.walletType === "salon_promotion_credits");
  const ownerSalonMap = new Map([...salonMap.values()].filter((salon) => salon.ownerUid).map((salon) => [salon.ownerUid ?? "", salon]));
  const referralStatsMap = new Map(data.referralStats.map((item) => [item.userId, item]));
  const cut = data.truncated;
  const referralCountByCode = data.referrals.reduce((map, referral) => {
    const code = referral.referralCode || "";
    if (code) map.set(code, (map.get(code) ?? 0) + 1);
    return map;
  }, new Map<string, number>());

  function referralOwnerLabel(uid: string) {
    const customer = customerMap.get(uid);
    if (customer) return `${customer.name} · customer`;
    const salon = ownerSalonMap.get(uid);
    if (salon) return `${salon.name} · ${salon.ownerName || "owner"}`;
    return uid || "Unknown account";
  }

  function referralPurposeLabel(code: ReferralCode) {
    if (code.inviterRole === "customer" && code.targetRole === "customer") return "Customer invites customer";
    if (code.inviterRole === "owner" && code.targetRole === "customer") return "Salon invites customer";
    if (code.inviterRole === "owner" && code.targetRole === "owner") return "Salon invites salon";
    return `${titleCase(code.inviterRole)} → ${titleCase(code.targetRole)}`;
  }

  function referralUsageLabel(code: ReferralCode) {
    const stats = referralStatsMap.get(code.ownerUid);
    const linkedCount = referralCountByCode.get(code.code) ?? 0;
    if (!stats) return `${linkedCount} linked`;
    const pending = code.targetRole === "owner" ? stats.pendingSalonCount : stats.pendingCustomerCount;
    const qualified = code.targetRole === "owner" ? stats.qualifiedSalonCount : stats.qualifiedCustomerCount;
    return `${pending} pending · ${qualified} qualified · ${linkedCount} linked`;
  }

  function referralCodeAction(code: ReferralCode): AdminAction {
    return {
      title: `Edit referral code ${code.code}`,
      description: `Change the future-use code for ${referralOwnerLabel(code.ownerUid)}. Existing referral history keeps the old code for audit.`,
      confirmLabel: "Save referral code",
      callableName: "updateReferralCodeAsAdmin",
      payload: { currentCode: code.code },
      fields: [
        { key: "newCode", label: "New referral code", initialValue: code.code, placeholder: "A7K2PX" },
        { key: "active", label: "Code active", type: "select", valueKind: "boolean", initialValue: String(code.active && !code.replacedByCode), options: [{ label: "Yes", value: "true" }, { label: "No", value: "false" }] },
        reasonField,
      ],
    };
  }

  function programAction(program?: ProinProgram): AdminAction {
    const start = program?.startsAtMillis || Date.now();
    const end = program?.endsAtMillis || Date.now() + 30 * day;
    const booleanOptions = [{ label: "No", value: "false" }, { label: "Yes", value: "true" }];
    return {
      title: program ? `Edit ${program.name}` : "Create Proin program",
      description: "Programs control referral, coupon, promotion or manual reward amounts, qualification, validity, expiry and redemption limits. Save inactive first, reconcile, then activate only after approval.",
      confirmLabel: program ? "Save new version" : "Create inactive program",
      callableName: "upsertProinProgramAsAdmin",
      payload: program ? { programId: program.programId } : {},
      fields: [
        ...(program ? [] : [{ key: "programId", label: "Program ID", placeholder: "customer_referrer_2026" } as AdminActionField]),
        { key: "name", label: "Program name", initialValue: program?.name ?? "" },
        { key: "sourceType", label: "Reward source", type: "select", initialValue: program?.sourceType ?? "", options: [
          { label: "Customer referral", value: "referral_customer" }, { label: "Salon referral", value: "referral_salon" }, { label: "Coupon", value: "coupon" }, { label: "Promotion", value: "promotion" }, { label: "Manual support grant", value: "manual" },
        ] },
        { key: "walletType", label: "Recipient wallet", type: "select", initialValue: program?.walletType ?? "", options: [{ label: "Customer rewards", value: "customer_rewards" }, { label: "Salon promotion credits", value: "salon_promotion_credits" }] },
        { key: "qualificationEvent", label: "Qualification event", type: "select", initialValue: program?.qualificationEvent ?? "", options: [
          { label: "First completed booking", value: "first_completed_booking" }, { label: "Salon approved + first completed booking", value: "salon_approved_and_first_completed_booking" }, { label: "Coupon claimed", value: "coupon_claimed" }, { label: "Campaign award", value: "campaign_award" }, { label: "Manual approval", value: "manual_approval" },
        ] },
        { key: "rewardRecipient", label: "Reward recipient", type: "select", initialValue: program?.rewardRecipient ?? "account", options: [{ label: "Account (coupon/promotion/manual)", value: "account" }, { label: "Referral inviter", value: "inviter" }, { label: "Referred account", value: "referred" }] },
        { key: "referralInviterRole", label: "Referral inviter role", type: "select", initialValue: program?.referralInviterRole ?? "", required: false, options: [{ label: "Customer", value: "customer" }, { label: "Salon owner", value: "owner" }] },
        { key: "active", label: "Program active", type: "select", valueKind: "boolean", initialValue: String(program?.active ?? false), options: booleanOptions },
        { key: "rewardAmountProin", label: "Reward amount (Proin)", type: "number", min: 1, initialValue: String(program?.rewardAmountProin ?? 100) },
        { key: "rewardValidityDays", label: "Reward validity (days)", type: "number", min: 1, max: 730, initialValue: String(program?.rewardValidityDays ?? 30) },
        { key: "totalBudgetProin", label: "Program budget (Proin)", type: "number", min: 1, initialValue: String(program?.totalBudgetProin ?? 10000) },
        { key: "maximumTotalGrants", label: "Maximum total grants", type: "number", min: 1, initialValue: String(program?.maximumTotalGrants ?? 100) },
        { key: "maximumGrantsPerAccount", label: "Max rewards / invites per account", type: "number", min: 1, initialValue: String(program?.maximumGrantsPerAccount ?? 1) },
        { key: "minimumBookingAmount", label: "Minimum booking amount (₹)", type: "number", min: 0, initialValue: String(program?.minimumBookingAmount ?? 0) },
        { key: "maximumProinPerBooking", label: "Maximum Proin per booking", type: "number", min: 0, initialValue: String(program?.maximumProinPerBooking ?? 100) },
        { key: "maximumRedemptionPercent", label: "Maximum redemption percent", type: "number", min: 0, max: 100, initialValue: String(program?.maximumRedemptionPercent ?? 25) },
        { key: "stackableWithDiscount", label: "Stackable with discount", type: "select", valueKind: "boolean", initialValue: String(program?.stackableWithDiscount ?? false), options: booleanOptions },
        { key: "startsAtMillis", label: "Program starts", type: "datetime-local", initialValue: dateTimeLocalValue(start) },
        { key: "endsAtMillis", label: "Program ends", type: "datetime-local", initialValue: dateTimeLocalValue(end) },
        { key: "eligibleSalonIds", label: "Eligible salon IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: program?.eligibleSalonIds.join(", ") ?? "" },
        { key: "eligibleServiceIds", label: "Eligible service IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: program?.eligibleServiceIds.join(", ") ?? "" },
        { key: "termsVersion", label: "Terms version", initialValue: program?.termsVersion ?? "proin-v1" },
        reasonField,
      ],
    };
  }

  function couponAction(coupon?: ProinCoupon): AdminAction {
    return {
      title: coupon ? `Edit coupon ${coupon.maskedCode}` : "Create Proin coupon",
      description: coupon ? "Enter the original full coupon code to save a new version. Pritze stores only its hash and masked label, so the plain code cannot be recovered from the database." : "Create the linked inactive coupon program first. The coupon controls claim dates and audience; the linked program controls reward value and reward expiry.",
      confirmLabel: coupon ? "Save coupon version" : "Create inactive coupon",
      callableName: "upsertProinCouponAsAdmin",
      payload: coupon ? { expectedCodeHash: coupon.codeHash } : {},
      fields: [
        { key: "code", label: coupon ? "Original full coupon code" : "Coupon code", placeholder: "WELCOME50" },
        { key: "programId", label: "Linked coupon program", type: "select", initialValue: coupon?.programId ?? "", options: couponPrograms.map((program) => ({ label: program.name, value: program.programId })) },
        { key: "active", label: "Coupon active", type: "select", valueKind: "boolean", initialValue: String(coupon?.active ?? false), options: [{ label: "No", value: "false" }, { label: "Yes", value: "true" }] },
        { key: "claimStartsAtMillis", label: "Claims start", type: "datetime-local", initialValue: dateTimeLocalValue(coupon?.claimStartsAtMillis || Date.now()) },
        { key: "claimEndsAtMillis", label: "Claims end", type: "datetime-local", initialValue: dateTimeLocalValue(coupon?.claimEndsAtMillis || Date.now() + 14 * day) },
        { key: "maximumClaimsTotal", label: "Maximum total claims", type: "number", min: 1, initialValue: String(coupon?.maximumClaimsTotal ?? 100) },
        { key: "eligibleCustomerUids", label: "Eligible customer UIDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: coupon?.eligibleCustomerUids.join(", ") ?? "" },
        { key: "eligibleSalonIds", label: "Eligible salon IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: coupon?.eligibleSalonIds.join(", ") ?? "" },
        { key: "termsVersion", label: "Coupon terms version", initialValue: coupon?.termsVersion ?? "coupon-v1" },
        reasonField,
      ],
    };
  }

  const budgetAction: AdminAction = {
    title: "Change approved Proin budget",
    description: "Set the maximum promotional budget. It cannot be reduced below outstanding customer rewards, payable salon reimbursements and settled expense.",
    confirmLabel: "Save approved budget",
    callableName: "setProinFinanceBudgetAsAdmin",
    payload: {},
    fields: [{ key: "approvedBudgetInr", label: "Approved budget (₹)", type: "number", min: 0, initialValue: String(finance.approvedBudgetInr) }, reasonField],
  };

  const manualGrantAction: AdminAction = {
    title: "Grant Proin manually",
    description: "Use only for an approved pilot or support correction. The selected program must be a manual-approval program, and the unique idempotency key prevents duplicate grants.",
    confirmLabel: "Grant Proin",
    callableName: "grantProinAsAdmin",
    payload: {},
    fields: [
      { key: "programId", label: "Manual program", type: "select", options: manualPrograms.map((program) => ({ label: program.name, value: program.programId })) },
      { key: "walletType", label: "Recipient wallet", type: "select", options: [{ label: "Customer rewards", value: "customer_rewards" }, { label: "Salon promotion credits", value: "salon_promotion_credits" }] },
      { key: "accountId", label: "Customer UID or salon ID" },
      { key: "sourceId", label: "Support case or source ID" },
      { key: "idempotencyKey", label: "Unique idempotency key", placeholder: "support-case-123:customer-uid" },
      reasonField,
    ],
  };

  function settlementAction(item: ProinReimbursement): AdminAction {
    return {
      title: `Record reimbursement for ${item.bookingId}`,
      description: `Confirm only after Pritze has paid ${formatMoney(item.amountInr)} to ${salonMap.get(item.salonId)?.name ?? "the salon"} outside the app. This records evidence; it does not initiate a bank or UPI transfer.`,
      confirmLabel: "Record as paid",
      callableName: "markProinReimbursementSettledAsAdmin",
      payload: { bookingId: item.bookingId },
      fields: [
        { key: "paymentMethod", label: "Payment method", type: "select", initialValue: "bank_transfer", options: [{ label: "Bank transfer", value: "bank_transfer" }, { label: "UPI", value: "upi" }, { label: "Cash", value: "cash" }] },
        { key: "paymentReference", label: "Transaction, receipt or ledger reference", placeholder: "For cash, enter the cash receipt or ledger reference" },
        { key: "paidAtMillis", label: "Payment completed at", type: "datetime-local", initialValue: dateTimeLocalValue(data.generatedAtMillis || now) },
        reasonField,
      ],
    };
  }

  function lotOwnerName(lot: ProinLot) {
    const isSalonCredit = lot.walletType === "salon_promotion_credits";
    return (isSalonCredit ? salonMap.get(lot.accountId)?.name : customerMap.get(lot.accountId)?.name) ?? lot.accountId;
  }

  function revocationAction(lot: ProinLot): AdminAction {
    const isSalonCredit = lot.walletType === "salon_promotion_credits";
    return {
      title: `Adjust ${lotOwnerName(lot)}'s ${isSalonCredit ? "promotional credit" : "Proin"}`,
      description: `Remove up to ${formatProin(lot.availableProin)} that is still unused in this reward lot. Reserved, redeemed and expired Proin cannot be changed. ${isSalonCredit ? "The salon's balance drops by the same amount and cannot go past its credit line." : "The customer will be notified."}`,
      confirmLabel: "Revoke unused Proin",
      callableName: "revokeProinAsAdmin",
      payload: { lotId: lot.lotId },
      fields: [
        { key: "amountProin", label: "Unused Proin to revoke", type: "number", initialValue: String(lot.availableProin), min: 1, max: lot.availableProin },
        reasonField,
      ],
      tone: "danger",
    };
  }

  const reconciliationAction: AdminAction = {
    title: "Run Proin reconciliation",
    description: "Compare reward lots, customer wallets, booking reservations, reimbursements and external payment evidence before further financial operations.",
    confirmLabel: "Run reconciliation",
    callableName: "runProinReconciliationAsAdmin",
    payload: {},
    fields: [reasonField],
  };

  function starterProgramAction(kind: "customerReferral" | "customerReferralReceiver" | "ownerCustomerReferral" | "ownerCustomerReferralReceiver" | "salonReferral" | "salonReferralReceiver" | "customerCoupon" | "salonCoupon"): AdminAction {
    const booleanOptions = [{ label: "No", value: "false" }, { label: "Yes", value: "true" }];
    const start = Date.now();
    const presets = {
      customerReferral: {
        programId: draftId("customer_referral_inviter_40"),
        name: "Customer invites customer - inviter reward",
        sourceType: "referral_customer",
        walletType: "customer_rewards",
        qualificationEvent: "first_completed_booking",
        rewardRecipient: "inviter",
        referralInviterRole: "customer",
        rewardAmountProin: "40",
        rewardValidityDays: "60",
        totalBudgetProin: "4000",
        maximumTotalGrants: "100",
        maximumGrantsPerAccount: "25",
        termsVersion: "customer-referral-v1",
        title: "Customer → customer inviter reward",
        description: "Creates an inactive program where a customer earns Proin for every referred customer who completes the qualifying booking.",
      },
      customerReferralReceiver: {
        programId: draftId("customer_referral_referred_40"),
        name: "Customer invites customer - referred reward",
        sourceType: "referral_customer",
        walletType: "customer_rewards",
        qualificationEvent: "first_completed_booking",
        rewardRecipient: "referred",
        referralInviterRole: "customer",
        rewardAmountProin: "40",
        rewardValidityDays: "60",
        totalBudgetProin: "4000",
        maximumTotalGrants: "100",
        maximumGrantsPerAccount: "1",
        termsVersion: "customer-referral-v1",
        title: "Customer → customer receiver reward",
        description: "Creates an inactive program where the new referred customer also earns Proin after completing the qualifying booking.",
      },
      ownerCustomerReferral: {
        programId: draftId("salon_invites_customer_inviter_40"),
        name: "Salon invites customer - salon reward",
        sourceType: "referral_customer",
        walletType: "salon_promotion_credits",
        qualificationEvent: "first_completed_booking",
        rewardRecipient: "inviter",
        referralInviterRole: "owner",
        rewardAmountProin: "40",
        rewardValidityDays: "60",
        totalBudgetProin: "4000",
        maximumTotalGrants: "100",
        maximumGrantsPerAccount: "25",
        termsVersion: "owner-customer-referral-v1",
        title: "Salon → customer salon reward",
        description: "Creates an inactive program where a salon earns promotional Proin when its referred customer completes the qualifying booking.",
      },
      ownerCustomerReferralReceiver: {
        programId: draftId("salon_invites_customer_referred_40"),
        name: "Salon invites customer - customer reward",
        sourceType: "referral_customer",
        walletType: "customer_rewards",
        qualificationEvent: "first_completed_booking",
        rewardRecipient: "referred",
        referralInviterRole: "owner",
        rewardAmountProin: "40",
        rewardValidityDays: "60",
        totalBudgetProin: "4000",
        maximumTotalGrants: "100",
        maximumGrantsPerAccount: "1",
        termsVersion: "owner-customer-referral-v1",
        title: "Salon → customer receiver reward",
        description: "Creates an inactive program where the referred customer earns Proin after completing the qualifying booking.",
      },
      salonReferral: {
        programId: draftId("salon_referral_inviter_500"),
        name: "Salon invites salon - inviter reward",
        sourceType: "referral_salon",
        walletType: "salon_promotion_credits",
        qualificationEvent: "salon_approved_and_first_completed_booking",
        rewardRecipient: "inviter",
        referralInviterRole: "owner",
        rewardAmountProin: "500",
        rewardValidityDays: "90",
        totalBudgetProin: "10000",
        maximumTotalGrants: "20",
        maximumGrantsPerAccount: "10",
        termsVersion: "salon-referral-v1",
        title: "Salon → salon inviter reward",
        description: "Creates an inactive program where the inviting salon earns promotional Proin after the referred salon is approved and completes its first booking.",
      },
      salonReferralReceiver: {
        programId: draftId("salon_referral_referred_500"),
        name: "Salon invites salon - referred reward",
        sourceType: "referral_salon",
        walletType: "salon_promotion_credits",
        qualificationEvent: "salon_approved_and_first_completed_booking",
        rewardRecipient: "referred",
        referralInviterRole: "owner",
        rewardAmountProin: "500",
        rewardValidityDays: "90",
        totalBudgetProin: "10000",
        maximumTotalGrants: "20",
        maximumGrantsPerAccount: "1",
        termsVersion: "salon-referral-v1",
        title: "Salon → salon receiver reward",
        description: "Creates an inactive program where the referred salon also earns promotional Proin after approval and its first completed booking.",
      },
      customerCoupon: {
        programId: draftId("customer_coupon_program_test"),
        name: "Test customer coupon Proin",
        sourceType: "coupon",
        walletType: "customer_rewards",
        qualificationEvent: "coupon_claimed",
        rewardRecipient: "account",
        referralInviterRole: "",
        rewardAmountProin: "50",
        rewardValidityDays: "30",
        totalBudgetProin: "2500",
        maximumTotalGrants: "50",
        maximumGrantsPerAccount: "1",
        termsVersion: "test-customer-coupon-v1",
        title: "Create customer coupon-program draft",
        description: "Creates an inactive reward program that can later be linked to a customer-entered Proin coupon code.",
      },
      salonCoupon: {
        programId: draftId("salon_coupon_program_test"),
        name: "Test salon coupon credits",
        sourceType: "coupon",
        walletType: "salon_promotion_credits",
        qualificationEvent: "coupon_claimed",
        rewardRecipient: "account",
        referralInviterRole: "",
        rewardAmountProin: "100",
        rewardValidityDays: "45",
        totalBudgetProin: "5000",
        maximumTotalGrants: "50",
        maximumGrantsPerAccount: "1",
        termsVersion: "test-salon-coupon-v1",
        title: "Create salon coupon-program draft",
        description: "Creates an inactive program that lets a salon claim promotional credits from a coupon code once activated.",
      },
    }[kind];
    return {
      title: presets.title,
      description: `${presets.description} It stays inactive until you review and activate it.`,
      confirmLabel: "Create program draft",
      callableName: "upsertProinProgramAsAdmin",
      payload: {},
      fields: [
        { key: "programId", label: "Program ID", initialValue: presets.programId },
        { key: "name", label: "Program name", initialValue: presets.name },
        { key: "sourceType", label: "Reward source", type: "select", initialValue: presets.sourceType, options: [
          { label: "Customer referral", value: "referral_customer" }, { label: "Salon referral", value: "referral_salon" }, { label: "Coupon", value: "coupon" }, { label: "Promotion", value: "promotion" }, { label: "Manual support grant", value: "manual" },
        ] },
        { key: "walletType", label: "Recipient wallet", type: "select", initialValue: presets.walletType, options: [{ label: "Customer rewards", value: "customer_rewards" }, { label: "Salon promotion credits", value: "salon_promotion_credits" }] },
        { key: "qualificationEvent", label: "Qualification event", type: "select", initialValue: presets.qualificationEvent, options: [
          { label: "First completed booking", value: "first_completed_booking" }, { label: "Salon approved + first completed booking", value: "salon_approved_and_first_completed_booking" }, { label: "Coupon claimed", value: "coupon_claimed" }, { label: "Campaign award", value: "campaign_award" }, { label: "Manual approval", value: "manual_approval" },
        ] },
        { key: "rewardRecipient", label: "Reward recipient", type: "select", initialValue: presets.rewardRecipient, options: [{ label: "Account (coupon/promotion/manual)", value: "account" }, { label: "Referral inviter", value: "inviter" }, { label: "Referred account", value: "referred" }] },
        { key: "referralInviterRole", label: "Referral inviter role", type: "select", initialValue: presets.referralInviterRole, required: false, options: [{ label: "Customer", value: "customer" }, { label: "Salon owner", value: "owner" }] },
        { key: "active", label: "Program active", type: "select", valueKind: "boolean", initialValue: "false", options: booleanOptions },
        { key: "rewardAmountProin", label: "Reward amount (Proin)", type: "number", min: 1, initialValue: presets.rewardAmountProin },
        { key: "rewardValidityDays", label: "Reward validity (days)", type: "number", min: 1, max: 730, initialValue: presets.rewardValidityDays },
        { key: "totalBudgetProin", label: "Program budget (Proin)", type: "number", min: 1, initialValue: presets.totalBudgetProin },
        { key: "maximumTotalGrants", label: "Maximum total grants", type: "number", min: 1, initialValue: presets.maximumTotalGrants },
        { key: "maximumGrantsPerAccount", label: "Max rewards / invites per account", type: "number", min: 1, initialValue: presets.maximumGrantsPerAccount },
        { key: "minimumBookingAmount", label: "Minimum booking amount (₹)", type: "number", min: 0, initialValue: "0" },
        { key: "maximumProinPerBooking", label: "Maximum Proin per booking", type: "number", min: 1, initialValue: presets.rewardAmountProin },
        { key: "maximumRedemptionPercent", label: "Maximum redemption percent", type: "number", min: 1, max: 100, initialValue: "25" },
        { key: "stackableWithDiscount", label: "Stackable with discount", type: "select", valueKind: "boolean", initialValue: "false", options: booleanOptions },
        { key: "startsAtMillis", label: "Program starts", type: "datetime-local", initialValue: dateTimeLocalValue(start) },
        { key: "endsAtMillis", label: "Program ends", type: "datetime-local", initialValue: dateTimeLocalValue(start + 30 * day) },
        { key: "eligibleSalonIds", label: "Eligible salon IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "eligibleServiceIds", label: "Eligible service IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "termsVersion", label: "Terms version", initialValue: presets.termsVersion },
        { ...reasonField, initialValue: "Create inactive Proin starter draft for controlled testing." },
      ],
    };
  }

  function starterCouponAction(walletType: "customer_rewards" | "salon_promotion_credits"): AdminAction {
    const program = walletType === "customer_rewards" ? customerCouponProgram : salonCouponProgram;
    const start = Date.now();
    return {
      title: walletType === "customer_rewards" ? "Create WELCOME50 customer coupon draft" : "Create SALON100 salon coupon draft",
      description: "Creates an inactive coupon code linked to the selected coupon program. It can be claimed only after both the program and coupon are activated.",
      confirmLabel: "Create coupon draft",
      callableName: "upsertProinCouponAsAdmin",
      payload: {},
      fields: [
        { key: "code", label: "Coupon code", initialValue: walletType === "customer_rewards" ? "WELCOME50" : "SALON100" },
        { key: "programId", label: "Linked coupon program", type: "select", initialValue: program?.programId ?? "", options: couponPrograms.filter((item) => item.walletType === walletType).map((item) => ({ label: item.name, value: item.programId })) },
        { key: "active", label: "Coupon active", type: "select", valueKind: "boolean", initialValue: "false", options: [{ label: "No", value: "false" }, { label: "Yes", value: "true" }] },
        { key: "claimStartsAtMillis", label: "Claims start", type: "datetime-local", initialValue: dateTimeLocalValue(start) },
        { key: "claimEndsAtMillis", label: "Claims end", type: "datetime-local", initialValue: dateTimeLocalValue(start + 14 * day) },
        { key: "maximumClaimsTotal", label: "Maximum total claims", type: "number", min: 1, initialValue: "50" },
        { key: "eligibleCustomerUids", label: "Eligible customer UIDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "eligibleSalonIds", label: "Eligible salon IDs (optional, comma separated)", type: "textarea", valueKind: "string-list", required: false, initialValue: "" },
        { key: "termsVersion", label: "Coupon terms version", initialValue: walletType === "customer_rewards" ? "test-customer-coupon-v1" : "test-salon-coupon-v1" },
        { ...reasonField, initialValue: "Create inactive Proin coupon draft for controlled testing." },
      ],
    };
  }

  return <>
    <section className="proin-hero">
      <div><p className="eyebrow">PROMOTIONAL REWARD CONTROL</p><h2>Proin operations</h2><p>Correct only unused promotional rewards and reconcile salon reimbursements paid outside Pritze. Customer purchases, transfers, withdrawals and cash conversion remain disabled.</p></div>
      <div className={`proin-health ${isBalanced ? "balanced" : "review"}`}><span>{isBalanced ? "✓" : "!"}</span><div><small>Latest reconciliation</small><strong>{latestReport ? titleCase(latestReport.status.replace("_", " ")) : "Not run"}</strong><time>{latestReport ? formatDateTime(latestReport.createdAtMillis) : "Run before operating"}</time></div></div>
    </section>

    <section className="metric-grid proin-metrics" aria-label="Proin financial position">
      <MetricCard label="Approved budget" value={formatMoney(finance.approvedBudgetInr)} detail={`${formatMoney(finance.unallocatedBudgetInr)} unallocated`} tone="gold" />
      <MetricCard label="Outstanding rewards" value={formatMoney(finance.outstandingLiabilityInr)} detail={`${formatMoney(finance.reservedLiabilityInr)} held for bookings`} tone="blue" />
      <MetricCard label="Salon payable" value={formatMoney(finance.redeemedPayableInr)} detail={`${payable.length} reimbursements awaiting payment`} tone="red" />
      <MetricCard label="Settled externally" value={formatMoney(finance.settledExpenseInr)} detail={`${settled.length} reimbursements recorded`} tone="green" />
    </section>

    <section className="proin-command-panel">
      <div><p className="eyebrow">CONFIGURATION & CONTROL</p><strong>Manage the full Proin lifecycle</strong><span>Changes are sent through protected Firebase functions, versioned and attributed to the signed-in administrator.</span></div>
      <div className="proin-command-buttons">
        <button disabled={!canOperate} onClick={() => onAdminAction(programAction())}>New program</button>
        <button disabled={!canOperate || !couponPrograms.length} onClick={() => onAdminAction(couponAction())}>New coupon</button>
        <button disabled={!canOperate} onClick={() => onAdminAction(budgetAction)}>Change budget</button>
        <button disabled={!canOperate || !manualPrograms.length} onClick={() => onAdminAction(manualGrantAction)}>Manual grant</button>
        <button className="quiet" disabled={!canOperate} onClick={() => onAdminAction(reconciliationAction)}>Run reconciliation</button>
      </div>
    </section>

    <section className="starter-panel proin-starter" aria-label="Proin starter setup">
      <div><p className="eyebrow">SAFE STARTER SETUP</p><strong>Create Proin and coupon drafts without activating them</strong><span>Use these to set up the normal testing objects. First create budgets/programs, then create coupon codes, then activate only after review.</span></div>
      <div className="starter-grid">
        <article><b>01</b><strong>Customer invites customer</strong><p>Create the inviter-side 40 Proin reward. Its per-account cap controls how many customers one customer can invite for rewards.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("customerReferral"))}>Create inviter reward</button></article>
        <article><b>02</b><strong>New customer also earns</strong><p>Create the referred-customer 40 Proin reward that pairs with the customer referral inviter reward.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("customerReferralReceiver"))}>Create receiver reward</button></article>
        <article><b>03</b><strong>Salon invites customer</strong><p>Create the salon-side 40 promotional Proin reward for customers invited by a salon owner.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("ownerCustomerReferral"))}>Create salon reward</button></article>
        <article><b>04</b><strong>Customer from salon earns</strong><p>Create the paired 40 Proin reward for the customer who joined from a salon referral code.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("ownerCustomerReferralReceiver"))}>Create customer reward</button></article>
        <article><b>05</b><strong>Salon invites salon</strong><p>Create the 500 promotional Proin reward for the inviting salon after the referred salon qualifies.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("salonReferral"))}>Create inviter reward</button></article>
        <article><b>06</b><strong>New salon also earns</strong><p>Create the paired 500 promotional Proin reward for the newly referred salon.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("salonReferralReceiver"))}>Create receiver reward</button></article>
        <article><b>07</b><strong>Customer coupon program</strong><p>Program that decides how much Proin a customer gets and when it expires after coupon claim.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("customerCoupon"))}>Create customer coupon program</button></article>
        <article><b>08</b><strong>Salon coupon program</strong><p>Program that lets salons receive promotional credits from a coupon claim.</p><button disabled={!canOperate} onClick={() => onAdminAction(starterProgramAction("salonCoupon"))}>Create salon coupon program</button></article>
        <article><b>09</b><strong>WELCOME50 customer coupon</strong><p>Coupon-code draft linked to a customer coupon program. Create the customer coupon program first.</p><button disabled={!canOperate || !customerCouponProgram} onClick={() => onAdminAction(starterCouponAction("customer_rewards"))}>Create WELCOME50 coupon</button></article>
        <article><b>10</b><strong>SALON100 salon coupon</strong><p>Coupon-code draft linked to a salon coupon program. Create the salon coupon program first.</p><button disabled={!canOperate || !salonCouponProgram} onClick={() => onAdminAction(starterCouponAction("salon_promotion_credits"))}>Create SALON100 coupon</button></article>
      </div>
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Referral codes" subtitle={`View and edit the actual customer and salon referral codes. Code changes affect future invites only.${cut.referralCodes ? " Showing the 1,000 newest codes." : ""}`} />
      <div className="data-table proin-program-table">
        <div className="data-head"><span>Code / owner</span><span>Purpose</span><span>Usage</span><span>Status</span><span>Action</span></div>
        {[...data.referralCodes].sort((a, b) => Number(b.active) - Number(a.active) || a.code.localeCompare(b.code)).map((code) => (
          <div className="data-row" key={`${code.code}-${code.replacedByCode || "current"}`}>
            <div><strong>{code.code}</strong><small>{referralOwnerLabel(code.ownerUid)}</small></div>
            <div><strong>{referralPurposeLabel(code)}</strong><small>{code.inviterRole} → {code.targetRole}</small></div>
            <span>{referralUsageLabel(code)}</span>
            <div><span className={`proin-state ${code.active && !code.replacedByCode ? "active" : "inactive"}`}>{code.replacedByCode ? "Replaced" : code.active ? "Active" : "Inactive"}</span><small>{code.replacedByCode ? `Now ${code.replacedByCode}` : code.updatedAtMillis ? `Edited ${formatDateTime(code.updatedAtMillis)}` : code.createdAtMillis ? `Created ${formatDateTime(code.createdAtMillis)}` : "No timestamp"}</small></div>
            <button className="control-button" disabled={!canOperate || Boolean(code.replacedByCode)} onClick={() => onAdminAction(referralCodeAction(code))}>Edit</button>
          </div>
        ))}
      </div>
      {!data.referralCodes.length ? <EmptyState title="No referral codes yet" detail="Codes appear after customers or salon owners open their referral page in the app." /> : null}
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Referral relationships" subtitle="Track who used which code, whether the referral qualified, and the Proin award state." />
      <div className="data-table proin-program-table">
        <div className="data-head"><span>Referred account</span><span>Inviter</span><span>Code</span><span>Status</span><span>Reward state</span></div>
        {[...data.referrals].sort((a, b) => b.createdAtMillis - a.createdAtMillis).slice(0, 200).map((referral) => (
          <div className="data-row" key={referral.referralId}>
            <div><strong>{referralOwnerLabel(referral.referredUid)}</strong><small>{referral.referredRole}</small></div>
            <div><strong>{referralOwnerLabel(referral.inviterUid)}</strong><small>{referral.inviterRole}</small></div>
            <strong>{referral.referralCode || "—"}</strong>
            <div><span className={`proin-state ${referral.status === "qualified" ? "active" : "inactive"}`}>{titleCase(referral.status || "pending")}</span><small>{referral.qualifiedAtMillis ? formatDateTime(referral.qualifiedAtMillis) : referral.createdAtMillis ? formatDateTime(referral.createdAtMillis) : "Waiting"}</small></div>
            <span>{referral.proinAwardStatus || (referral.proinAwardPending ? "waiting" : "not started")}</span>
          </div>
        ))}
      </div>
      {!data.referrals.length ? <EmptyState title="No referral relationships yet" detail="When a new customer or salon submits a referral code during onboarding, the relationship appears here." /> : null}
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Reward programs" subtitle={`Referral, coupon, promotion and support policies are versioned on every save.${cut.programs ? " Only the first 500 programs are shown." : ""}`} />
      <div className="data-table proin-program-table">
        <div className="data-head"><span>Program</span><span>Reward / validity</span><span>Usage</span><span>Window</span><span>Action</span></div>
        {[...data.programs].sort((a, b) => Number(b.active) - Number(a.active) || a.name.localeCompare(b.name)).map((program) => {
          const usage = usageMap.get(program.programId);
          return <div className="data-row" key={program.programId}><div><strong>{program.name}</strong><small>{program.programId} · {titleCase(program.sourceType.replaceAll("_", " "))} · v{program.version}{program.systemManaged ? " · managed by its discount campaign" : ""}</small></div><div><strong>{formatProin(program.rewardAmountProin)}</strong><small>{program.rewardValidityDays} days · up to {program.maximumRedemptionPercent}% per booking</small></div><div><strong>{usage?.grantCount ?? 0} grants</strong><small>{formatProin(usage?.grantedProin ?? 0)} of {formatProin(program.totalBudgetProin)}</small></div><div><span className={`proin-state ${program.active ? "active" : "inactive"}`}>{program.active ? "Active" : "Inactive"}</span><small>{formatDateTime(program.startsAtMillis)} – {formatDateTime(program.endsAtMillis)}</small></div><button className="control-button" disabled={!canOperate || program.systemManaged} title={program.systemManaged ? "Edit this cashback in its discount campaign" : undefined} onClick={() => onAdminAction(programAction(program))}>Edit</button></div>;
        })}
      </div>
      {!data.programs.length ? <EmptyState title="No Proin programs" detail="Create an inactive, capped program before issuing any rewards." /> : null}
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Coupon campaigns" subtitle={`Plain coupon codes are never returned by Firebase; retain the approved code securely outside the app.${cut.coupons ? " Only the first 500 coupons are shown." : ""}`} />
      <div className="data-table proin-coupon-table">
        <div className="data-head"><span>Coupon</span><span>Linked program</span><span>Claims</span><span>Claim window</span><span>Action</span></div>
        {[...data.coupons].sort((a, b) => Number(b.active) - Number(a.active) || b.claimEndsAtMillis - a.claimEndsAtMillis).map((coupon) => {
          const usage = couponUsageMap.get(coupon.codeHash);
          const audience = coupon.eligibleSalonIds.length ? `${coupon.eligibleSalonIds.length} selected salons` : coupon.eligibleCustomerUids.length ? `${coupon.eligibleCustomerUids.length} selected customers` : "All eligible accounts";
          return <div className="data-row" key={coupon.codeHash}><div><strong>{coupon.maskedCode}</strong><small>v{coupon.version} · {audience}</small></div><div><strong>{data.programs.find((program) => program.programId === coupon.programId)?.name ?? coupon.programId}</strong><small>{coupon.programId}</small></div><div><strong>{usage?.claimedCount ?? 0} / {coupon.maximumClaimsTotal}</strong><small>{usage?.reservedClaims ?? 0} reserved</small></div><div><span className={`proin-state ${coupon.active ? "active" : "inactive"}`}>{coupon.active ? "Active" : "Inactive"}</span><small>{formatDateTime(coupon.claimStartsAtMillis)} – {formatDateTime(coupon.claimEndsAtMillis)}</small></div><button className="control-button" disabled={!canOperate} onClick={() => onAdminAction(couponAction(coupon))}>Edit</button></div>;
        })}
      </div>
      {!data.coupons.length ? <EmptyState title="No coupon campaigns" detail="Create a coupon-type reward program first, then add its claim code and dates." /> : null}
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Payable Proin reimbursements" subtitle={`Record a payment only after the external transfer has completed.${cut.payableReimbursements ? " Only 1,000 payable reimbursements are shown; more appear as these are settled." : ""}`} />
      <div className="data-table proin-reimbursement-table">
        <div className="data-head"><span>Salon / booking</span><span>Amount</span><span>Created</span><span>Payment state</span><span>Action</span></div>
        {payable.map((item) => <div className="data-row" key={item.bookingId}><div><strong>{salonMap.get(item.salonId)?.name ?? "Unknown salon"}</strong><small>{item.bookingId}</small></div><strong>{formatMoney(item.amountInr)}</strong><span>{formatDateTime(item.createdAtMillis)}</span><span className="proin-state payable">Awaiting external payment</span><button className="control-button" disabled={!canOperate} onClick={() => onAdminAction(settlementAction(item))}>Record paid</button></div>)}
      </div>
      {!payable.length ? <EmptyState title="No Proin reimbursements payable" detail="Completed bookings that used Proin will appear here." /> : null}
    </section>

    <section className="panel main-panel proin-panel">
      <PanelHeader title="Unused Proin" subtitle={`Only the available portion of an active, unexpired reward lot can be adjusted. Salon promotional credit is listed under the salon's name.${revocableLots.length > 200 || cut.lots ? " Showing the 200 that expire soonest." : ""}`} />
      <div className="data-table proin-lot-table">
        <div className="data-head"><span>Owner / reward</span><span>Unused</span><span>Protected</span><span>Expires</span><span>Action</span></div>
        {revocableLots.slice(0, 200).map((lot) => <div className="data-row" key={lot.lotId}><div><strong>{lotOwnerName(lot)}</strong><small>{lot.walletType === "salon_promotion_credits" ? "Salon credit · " : ""}{titleCase(lot.sourceType.replaceAll("_", " "))} · {lot.programId}</small></div><strong>{formatProin(lot.availableProin)}</strong><span>{formatProin(lot.reservedProin)} reserved</span><span>{formatDateTime(lot.expiresAtMillis)}</span><button className="control-button danger-link" disabled={!canOperate} onClick={() => onAdminAction(revocationAction(lot))}>Adjust</button></div>)}
      </div>
      {!revocableLots.length ? <EmptyState title="No unused Proin to adjust" detail="Active and unexpired reward lots will appear here." /> : null}
    </section>

    <section className="proin-secondary-grid">
      <article className="panel proin-wallet-panel"><PanelHeader title="Customer reward wallets" subtitle="Current server-calculated balances" /><div className="proin-wallet-list">{customerWallets.slice(0, 100).map((wallet) => <div key={wallet.walletId}><div className="customer-avatar">{initials(customerMap.get(wallet.accountId)?.name ?? "Customer")}</div><div><strong>{customerMap.get(wallet.accountId)?.name ?? wallet.accountId}</strong><span>{formatProin(wallet.availableProin)} available · {formatProin(wallet.reservedProin)} reserved</span></div><b>{wallet.nextExpiryAtMillis ? formatDateTime(wallet.nextExpiryAtMillis) : "No expiry"}</b></div>)}</div>{!customerWallets.length ? <EmptyState title="No customer Proin wallets" detail="Reward wallets appear after the first grant." /> : null}</article>
      <article className="panel proin-wallet-panel"><PanelHeader title="Salon promotional credit wallets" subtitle="Balances can go negative up to the approved credit line" /><div className="proin-wallet-list">{salonWallets.slice(0, 100).map((wallet) => {
        const parsedCreditLine = Number(wallet.creditLimitProin);
        const creditLine = Number.isFinite(parsedCreditLine) ? parsedCreditLine : 1000;
        const parsedSpendable = Number(wallet.spendableProin);
        const spendable = Number.isFinite(parsedSpendable) ? parsedSpendable : Math.max(0, wallet.availableProin + creditLine);
        return <div key={wallet.walletId}><div className="customer-avatar">{initials(salonMap.get(wallet.accountId)?.name ?? "Salon")}</div><div><strong>{salonMap.get(wallet.accountId)?.name ?? wallet.accountId}</strong><span>{formatProin(wallet.availableProin)} balance · {formatProin(spendable)} can spend</span></div><b>{formatProin(creditLine)} line</b></div>;
      })}</div>{!salonWallets.length ? <EmptyState title="No salon credit wallets" detail="Salon promotional wallets appear after the first salon grant or salon-funded discount." /> : null}</article>
      <article className="panel proin-history-panel"><PanelHeader title="Settled reimbursement history" subtitle="External reference evidence retained for reconciliation" /><div className="proin-history-list">{settled.slice(0, 100).map((item) => <div key={item.bookingId}><div><strong>{salonMap.get(item.salonId)?.name ?? "Unknown salon"}</strong><span>{item.bookingId} · {formatDateTime(item.paidAtMillis)}</span></div><div><b>{formatMoney(item.amountInr)}</b><small>{formatSettlementPaymentMethod(item.paymentMethod)} · {item.paymentReference}</small></div></div>)}</div>{!settled.length ? <EmptyState title="No settled Proin reimbursements" detail="Recorded external payments will appear here." /> : null}</article>
    </section>
  </>;
}

function ReportsView({ data, completedValue }: { data: AdminData; completedValue: number }) {
  const statusCounts = ["completed", "confirmed", "inProgress", "pending", "cancelled", "rejected"].map((status) => ({ status, value: data.bookings.filter((booking) => booking.status === status).length }));
  const maximum = Math.max(1, ...statusCounts.map((item) => item.value));
  const serviceTotals = new Map<string, number>();
  data.bookings.filter((booking) => booking.status === "completed").forEach((booking) => serviceTotals.set(booking.serviceName || "Service", (serviceTotals.get(booking.serviceName || "Service") ?? 0) + booking.servicePrice));
  const services = [...serviceTotals.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);
  const cancellationRate = data.bookings.length ? data.bookings.filter((booking) => ["cancelled", "rejected"].includes(booking.status)).length / data.bookings.length * 100 : 0;
  return <><section className="report-grid"><MetricCard label="Completed-service value" value={formatMoney(completedValue)} detail="Not verified payment revenue" tone="gold" /><MetricCard label="Completion rate" value={`${data.bookings.length ? Math.round(data.bookings.filter((booking) => booking.status === "completed").length / data.bookings.length * 100) : 0}%`} detail="Across loaded bookings" tone="green" /><MetricCard label="Cancellation rate" value={`${cancellationRate.toFixed(1)}%`} detail="Cancelled and rejected" tone="red" /></section><section className="analytics-grid"><article className="panel chart-card"><PanelHeader title="Booking status mix" subtitle="Distribution across the current reporting window" /><div className="bar-chart">{statusCounts.map((item) => <div className="bar-item" key={item.status}><div className="bar-track"><i style={{ height: `${Math.max(8, item.value / maximum * 100)}%` }} /></div><strong>{item.value}</strong><span>{titleCase(item.status)}</span></div>)}</div></article><article className="panel service-report"><PanelHeader title="Top services" subtitle="Completed-service value" /><div>{services.length ? services.map(([service, value], index) => <div className="service-rank" key={service}><span>{index + 1}</span><strong>{service}</strong><b>{formatMoney(value)}</b></div>) : <EmptyState title="No completed services" detail="Completed bookings will appear here." />}</div></article></section></>;
}

function ActivityView({ auditLogs, notes }: { auditLogs: AuditLog[]; notes: AdminNote[] }) {
  const visibleLogs = [...auditLogs].sort((a, b) => b.createdAtMillis - a.createdAtMillis);
  return <><section className="report-grid"><MetricCard label="Audited decisions" value={String(auditLogs.length)} detail="Loaded operational actions" tone="gold" /><MetricCard label="Internal notes" value={String(notes.length)} detail="Customer, booking, salon and staff context" tone="blue" /><MetricCard label="Unattributed actions" value={String(auditLogs.filter((item) => !item.adminUid).length)} detail="Should remain zero" tone="green" /></section><section className="panel main-panel activity-panel"><PanelHeader title="Administrator audit trail" subtitle="Immutable record of who changed what, when and why." />{visibleLogs.length ? <div className="activity-list">{visibleLogs.map((log) => <article key={log.id}><div className="activity-icon">{log.action.includes("note") ? "✎" : "✓"}</div><div><strong>{auditActionLabel(log.action)}</strong><span>{titleCase(log.targetType)} · {log.targetId}</span><p>{log.reason || "No reason recorded"}</p></div><time>{formatDateTime(log.createdAtMillis)}</time></article>)}</div> : <EmptyState title="No administrator activity" detail="Phase 2 decisions will appear here after the controls are connected." />}</section></>;
}

function auditActionLabel(value: string) {
  return value.replaceAll("_", " ").replaceAll(".", " · ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function BookingDrawer({ booking, salon, barber, barbers, notes, currentTime, canOperate, onAdminAction, onClose }: { booking: Booking; salon?: Salon; barber?: Barber; barbers: Barber[]; notes: AdminNote[]; currentTime: number; onClose: () => void } & AdminControlProps) {
  const statusAction = (status: BookingStatus, label: string, danger = false): AdminAction => ({ title: `${label}: ${booking.customerName}`, description: `This moves booking ${booking.id} from ${titleCase(booking.status)} to ${titleCase(status)} and notifies the booking participants.`, confirmLabel: label, callableName: "updateBookingStatusAsAdmin", payload: { bookingId: booking.id, status }, fields: [reasonField], tone: danger ? "danger" : "default" });
  const actions: AdminAction[] = [];
  if (booking.status === "pending" && booking.isInstant) actions.push(statusAction("confirmed", "Accept request"), statusAction("rejected", "Reject request", true));
  if (booking.status === "confirmed") actions.push(statusAction("inProgress", "Start service"), statusAction("cancelled", "Cancel booking", true));
  if (booking.status === "inProgress") actions.push(statusAction("completed", "Complete service"), statusAction("cancelled", "Cancel service", true));
  if (booking.status === "confirmed" && !booking.isInstant) actions.push({ title: `Reschedule ${booking.id}`, description: "Choose an eligible barber and a new future appointment time. Existing slot locks will be moved safely.", confirmLabel: "Reschedule booking", callableName: "rescheduleBookingAsAdmin", payload: { bookingId: booking.id }, fields: [{ key: "barberId", label: "Assigned barber", type: "select", options: barbers.map((item) => ({ label: item.name, value: item.id })) }, { key: "startMillis", label: "New appointment time", type: "datetime-local" }, reasonField] });
  return <div className="drawer-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}><aside className="drawer" role="dialog" aria-modal="true" aria-label={`Booking ${booking.id}`}><div className="drawer-head"><div><span className={`status ${booking.status}`}>{titleCase(booking.status)}</span><h2>{booking.customerName}</h2><p>{booking.id} · {booking.isInstant ? "Instant booking" : "Scheduled booking"}</p></div><button onClick={onClose} aria-label="Close booking details">×</button></div><div className="arrival-summary"><span>Expected arrival</span><strong>{arrivalText(booking, currentTime)}</strong><small>{formatDateTime(booking.startMillis)}</small></div><div className="detail-list"><Detail label="Customer phone" value={booking.customerPhone} /><Detail label="Salon" value={salon?.name ?? "Unknown salon"} /><Detail label="Assigned barber" value={barber?.name ?? "Unassigned"} /><Detail label="Service" value={booking.serviceName || "Service"} /><Detail label="Duration" value={`${booking.durationMinutes} minutes`} /><Detail label="Service value" value={formatMoney(booking.servicePrice)} /><Detail label="Customer journey" value={arrivalStatusText(booking.arrivalStatus)} /><Detail label="Live sharing" value={booking.arrivalSharingActive ? "Active (customer opted in)" : "Not active"} /></div><div className="timeline"><h3>Booking timeline</h3><Timeline label="Booking created" value={booking.createdAtMillis} active /><Timeline label="Accepted" value={booking.acceptedAtMillis} active={Boolean(booking.acceptedAtMillis)} /><Timeline label="Service started" value={booking.startedAtMillis} active={Boolean(booking.startedAtMillis)} /><Timeline label="Completed" value={booking.completedAtMillis} active={Boolean(booking.completedAtMillis)} /></div>{booking.cancellationReason ? <div className="cancellation-note"><strong>Cancellation reason</strong><p>{booking.cancellationReason} · {booking.cancelledBy || "Unknown"}</p></div> : null}<div className="booking-controls"><div><strong>Phase 2 controls</strong><span>Every action requires a reason and is audited.</span></div>{actions.length ? <div className="control-cluster">{actions.map((action) => <button key={action.confirmLabel} className={action.tone === "danger" ? "danger-link" : ""} disabled={!canOperate} onClick={() => onAdminAction(action)}>{action.confirmLabel}</button>)}</div> : <p>This booking is locked in history.</p>}<button className="note-control" disabled={!canOperate} onClick={() => onAdminAction(noteAction("booking", booking.id, booking.id))}>Add internal note</button></div>{notes.length ? <div className="drawer-notes"><h3>Internal notes</h3>{notes.map((note) => <article key={note.id}><p>{note.note}</p><time>{formatDateTime(note.createdAtMillis)}</time></article>)}</div> : null}</aside></div>;
}

function JourneyMilestoneEditor({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  let milestones: JourneyMilestone[] = [];
  try {
    const parsed = JSON.parse(value || "[]");
    milestones = Array.isArray(parsed) ? parsed : [];
  } catch {
    milestones = [];
  }
  const save = (next: JourneyMilestone[]) => onChange(JSON.stringify(next));
  const update = (index: number, changes: Partial<JourneyMilestone>) => save(milestones.map((item, itemIndex) => itemIndex === index ? { ...item, ...changes } : item));
  const add = () => save([...milestones, {
    bookingNumber: milestones.length ? Math.max(...milestones.map((item) => Number(item.bookingNumber) || 0)) + 1 : 1,
    rewardType: "discount",
    discountType: "percent",
    discountPercent: 10,
    fixedDiscountAmount: 0,
    maximumDiscountAmount: 0,
    cashbackProinAmount: 0,
    cashbackValidityDays: 30,
  }]);
  return <div className="journey-editor">
    <div className="journey-editor-head"><span>Reward schedule</span><button type="button" onClick={add}>+ Add booking milestone</button></div>
    {milestones.map((milestone, index) => {
      const includesDiscount = milestone.rewardType !== "proin";
      const includesProin = milestone.rewardType !== "discount";
      return <article className="journey-milestone" key={`${milestone.bookingNumber}-${index}`}>
        <div className="journey-milestone-title"><strong>Booking reward {index + 1}</strong><button type="button" onClick={() => save(milestones.filter((_, itemIndex) => itemIndex !== index))}>Remove</button></div>
        <div className="journey-milestone-fields">
          <label>Booking number<input type="number" min={1} max={100000} value={milestone.bookingNumber} onChange={(event) => update(index, { bookingNumber: Number(event.target.value) })} required /></label>
          <label>Reward<select value={milestone.rewardType} onChange={(event) => update(index, { rewardType: event.target.value as JourneyMilestone["rewardType"], discountType: event.target.value === "proin" ? "none" : milestone.discountType === "none" ? "percent" : milestone.discountType })}><option value="discount">Discount only</option><option value="discount_proin">Discount + Proin</option><option value="proin">Proin only</option></select></label>
          {includesDiscount ? <label>Discount type<select value={milestone.discountType === "fixed" ? "fixed" : "percent"} onChange={(event) => update(index, { discountType: event.target.value as "percent" | "fixed" })}><option value="percent">Percentage off</option><option value="fixed">Fixed rupees off</option></select></label> : null}
          {includesDiscount && milestone.discountType !== "fixed" ? <label>Discount %<input type="number" min={0.01} max={100} step={0.01} value={milestone.discountPercent} onChange={(event) => update(index, { discountPercent: Number(event.target.value) })} required /></label> : null}
          {includesDiscount && milestone.discountType === "fixed" ? <label>Fixed discount ₹<input type="number" min={1} value={milestone.fixedDiscountAmount} onChange={(event) => update(index, { fixedDiscountAmount: Number(event.target.value) })} required /></label> : null}
          {includesDiscount ? <label>Maximum discount ₹<input type="number" min={0} value={milestone.maximumDiscountAmount} onChange={(event) => update(index, { maximumDiscountAmount: Number(event.target.value) })} required /></label> : null}
          {includesProin ? <label>Proin after completion<input type="number" min={1} value={milestone.cashbackProinAmount} onChange={(event) => update(index, { cashbackProinAmount: Number(event.target.value) })} required /></label> : null}
          {includesProin ? <label>Proin validity (days)<input type="number" min={1} max={730} value={milestone.cashbackValidityDays} onChange={(event) => update(index, { cashbackValidityDays: Number(event.target.value) })} required /></label> : null}
        </div>
      </article>;
    })}
    {!milestones.length ? <p className="journey-empty">Add at least one booking milestone.</p> : null}
  </div>;
}

function AdminActionDialog({ action, values, error, submitting, onChange, onSubmit, onClose }: { action: AdminAction; values: Record<string, string>; error: string; submitting: boolean; onChange: (key: string, value: string) => void; onSubmit: (event: React.FormEvent) => void; onClose: () => void }) {
  return <div className="drawer-backdrop auth-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <section className={`auth-dialog action-dialog ${action.tone === "danger" ? "danger" : ""}`} role="dialog" aria-modal="true" aria-labelledby="admin-action-title">
      <button className="auth-close" onClick={onClose} aria-label="Close administrator action">×</button>
      <div className="action-heading"><span>{action.tone === "danger" ? "!" : "✓"}</span><div><p>Audited administrator action</p><h2 id="admin-action-title">{action.title}</h2></div></div>
      <p className="action-description">{action.description}</p>
      {error ? <div className="auth-error">{error}</div> : null}
      <form onSubmit={onSubmit}>
        {action.fields.map((field) => {
          const help = adminActionFieldHelp(action, field);
          if (field.type === "journey-milestones") return <div className="action-field" key={field.key}>
            <span className="action-field-label"><span>{field.label}</span>{help ? <button type="button" className="field-help" aria-label={`Help for ${field.label}: ${help}`} data-tooltip={help}>?</button> : null}</span>
            <JourneyMilestoneEditor value={values[field.key] ?? "[]"} onChange={(value) => onChange(field.key, value)} />
          </div>;
          return <label className="action-field" key={field.key}>
            <span className="action-field-label">
              <span>{field.label}</span>
              {help ? <button type="button" className="field-help" aria-label={`Help for ${field.label}: ${help}`} data-tooltip={help}>?</button> : null}
            </span>
            {field.type === "textarea" ? <textarea value={values[field.key] ?? ""} onChange={(event) => onChange(field.key, event.target.value)} placeholder={field.placeholder} minLength={field.key === "reason" ? 5 : undefined} required={field.required !== false} /> : field.type === "checkbox-list" ? <div className="checkbox-list" aria-label={field.label}>{field.options?.map((option) => { const selected = (values[field.key] ?? "").split(/[\n,]/).map((value) => value.trim()).filter(Boolean); const checked = selected.includes(option.value); return <label key={option.value}><input type="checkbox" checked={checked} onChange={(event) => onChange(field.key, event.target.checked ? [...selected, option.value].join("\n") : selected.filter((value) => value !== option.value).join("\n"))} /><span>{option.label}</span></label>; })}</div> : field.type === "select" ? <select value={values[field.key] ?? ""} onChange={(event) => onChange(field.key, event.target.value)} required={field.required !== false}><option value="">Choose an option</option>{field.options?.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select> : <input type={field.type ?? "text"} value={values[field.key] ?? ""} onChange={(event) => onChange(field.key, event.target.value)} placeholder={field.placeholder} min={field.min} max={field.max} step={field.step ?? (field.type === "number" ? 1 : undefined)} required={field.required !== false} />}
          </label>;
        })}
        <div className="dialog-actions"><button type="button" className="auth-secondary" onClick={onClose}>Cancel</button><button className="auth-primary" disabled={submitting}>{submitting ? "Applying…" : action.confirmLabel}</button></div>
      </form>
      <p className="auth-note">This action will be attributed to the signed-in platform administrator.</p>
    </section>
  </div>;
}

function AdminAccessPage({ authReady, user, userId, password, passwordVisible, submitting, loading, error, setUserId, setPassword, setPasswordVisible, onSignIn, onRetry, onUseAnotherAccount }: { authReady: boolean; user: User | null; userId: string; password: string; passwordVisible: boolean; submitting: boolean; loading: boolean; error: string; setUserId: (value: string) => void; setPassword: (value: string) => void; setPasswordVisible: (value: boolean) => void; onSignIn: (event: React.FormEvent) => void; onRetry: () => void; onUseAnotherAccount: () => void }) {
  return <main className="access-page">
    <section className="access-story" aria-labelledby="pritze-access-title">
      <div className="access-brand"><span className="brand-mark">P</span><div><strong>Pritze</strong><small>CONTROL CENTER</small></div></div>
      <div className="access-story-copy"><p className="access-eyebrow">THE OPERATING DESK FOR BETTER SALON EXPERIENCES</p><h1 id="pritze-access-title">One trusted place to run Pritze.</h1><p>Keep bookings moving, support salon partners, and manage every customer reward with the clarity your team needs.</p></div>
      <div className="access-capabilities"><article><span>01</span><div><strong>Live operations</strong><p>Bookings, arrivals and salon activity in one view.</p></div></article><article><span>02</span><div><strong>Customer value</strong><p>Discounts, referrals and Proin with controlled budgets.</p></div></article><article><span>03</span><div><strong>Accountable decisions</strong><p>Team actions remain authorized and auditable.</p></div></article></div>
      <p className="access-footnote">Pritze · Built for the people behind every great appointment.</p>
    </section>
    <section className="access-panel" aria-label="Pritze team sign in">
      <div className="access-card">
        <span className="access-lock">P</span>
        <p className="access-card-eyebrow">AUTHORIZED TEAM ACCESS</p>
        <h2>Welcome back</h2>
        <p className="access-intro">Use the Pritze User ID and password assigned to you. No email, OTP or ChatGPT account is required.</p>
        {user ? <div className="access-session"><div className="access-progress"><i /><div><strong>{loading ? "Opening the control center" : "The control center could not open"}</strong><span>{loading ? "Loading live Pritze operations…" : error}</span></div></div>{!loading ? <div className="access-session-actions"><button className="auth-primary" onClick={onRetry}>Try again</button><button className="auth-secondary" onClick={onUseAnotherAccount}>Use another account</button></div> : null}</div> : <form className="access-form" onSubmit={onSignIn} aria-busy={!authReady || submitting}><label>User ID<input type="text" autoComplete="username" value={userId} onChange={(event) => setUserId(event.target.value)} placeholder="User 1" minLength={3} maxLength={40} autoCapitalize="words" required /></label><label>Password<div className="password-field"><input type={passwordVisible ? "text" : "password"} autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Enter your password" minLength={8} maxLength={72} required /><button type="button" onClick={() => setPasswordVisible(!passwordVisible)} aria-label={passwordVisible ? "Hide password" : "Show password"}>{passwordVisible ? "Hide" : "Show"}</button></div></label>{error ? <div className="auth-error" role="alert">{error}</div> : null}<button className="auth-primary" disabled={!authReady || submitting || !userId.trim() || password.length < 8}>{!authReady ? "Checking secure session…" : submitting ? "Signing in…" : "Open control center"}</button></form>}
        <p className="access-security">Private access for approved Pritze team members. There is no public registration.</p>
      </div>
    </section>
  </main>;
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div><span>{label}</span><strong>{value || "—"}</strong></div>;
}

function Timeline({ label, value, active }: { label: string; value?: number; active: boolean }) {
  return <div className={active ? "active" : ""}><i /><span><strong>{label}</strong><small>{value ? formatDateTime(value) : "Waiting"}</small></span></div>;
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return <div className="empty-state"><span>◇</span><strong>{title}</strong><p>{detail}</p></div>;
}

function average(values: number[]) {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}
