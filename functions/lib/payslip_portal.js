/**
 * Distributor payslip portal: backs clmworking.web.app/payslips.html.
 *
 * Distributors are NOT Firebase Auth users, on purpose. In firestore.rules any
 * real (non-anonymous) Firebase account counts as staff, and staff can read
 * every distributor's payroll week docs. A distributor holding one would see
 * everybody's wages. So their accounts, passwords and sessions live here, and
 * this function is the only path from a distributor to payroll data:
 *
 *   payslipAccounts/{accountId}      One sign-up request. Created only here;
 *                                    the office approves it in CLM Schedule
 *                                    (Payroll → Payslip access) by linking it
 *                                    to a distributor. Admin-only in rules.
 *   payslipLogins/{phone}            Password hash and lockout counter, keyed
 *                                    by phone so one phone has one live
 *                                    account. Unlisted in rules: Admin SDK only.
 *   payslipSessions/{sha256(token)}  Signed-in phones. Unlisted: Admin SDK only.
 *
 * What stops one distributor seeing another's payslip:
 *   - The distributor id comes only from the account doc, which only an admin
 *     can set (rules). Nothing the phone sends chooses whose payslip is read.
 *   - Every request re-reads the account, so removing access in CLM Schedule
 *     cuts a signed-in phone off on its next request.
 *   - Payroll week docs are read with a field mask of `payslips.{thatId}`, so
 *     other distributors' payslips never even reach this function.
 *   - Only weeks whose payslip is marked Paid are listed or opened.
 *
 * Forgotten password: the office removes access, the distributor signs up
 * again with the same phone, and the office approves the new request. A
 * reset always goes back through an admin.
 */
const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");

const REGION = "us-central1";
const ACCOUNTS = "payslipAccounts";
const LOGINS = "payslipLogins";
const SESSIONS = "payslipSessions";

const DAY_MS = 24 * 60 * 60 * 1000;
const SAST_OFFSET_MS = 2 * 60 * 60 * 1000; // South Africa, no DST
const KEEP_SIGNED_IN_MS = 120 * DAY_MS;
const SHORT_SESSION_MS = 12 * 60 * 60 * 1000;
const MAX_FAILED_LOGINS = 5;
const LOCK_MS = 15 * 60 * 1000;
// Sign-up is a public endpoint. This caps how much junk anyone can pile
// into the office's approval list.
const MAX_PENDING = 30;
const MIN_PASSWORD = 6;
const MAX_PASSWORD = 100;
const PAYSLIP_YEARS_BACK = 1; // this year and last year

const MONTH_NAMES_SHORT = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

// Same defaults as PayrollSettings.defaults() in the app, used when
// payrollSettings/config has no value of its own.
const DEFAULT_BONUS_CODE_LABELS = {
  DR: "Driving",
  SC: "Scooter",
  TL: "Traffic light handout",
  WC: "Window cleaning (full day)",
  HC: "Half-day collection",
  HW: "Half-day window cleaning",
  WM: "Window cleaning + distribution",
};
const DEFAULT_COMPANY = {
  companyName: "Community Life Media",
  companyRegistrationNo: "2013/128702/07",
  companyVatNo: "4500285780",
  companyAddress: "Unit 69, 27, 7th Avenue\nThe Old Timber Yard, Maitland\nCape Town, 7405",
  companyPhone: "+27 71 909 0839",
  companyEmail: "",
};

/** A company setting the way PayrollSettings.fromMap reads it: the stored
 *  string, even an empty one, else the default (Dart's `??`). */
function companySetting(settings, key) {
  const v = settings ? settings[key] : undefined;
  return typeof v === "string" ? v : DEFAULT_COMPANY[key];
}

// From the modular entry point: the functions emulator wraps the
// `admin.firestore` namespace and its statics are missing there.
const { FieldValue, FieldPath, Timestamp } = require("firebase-admin/firestore");

const db = () => admin.firestore();

class PortalError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Input checks ─────────────────────────────────────────────────────────────

/**
 * A South African mobile number as `0XXXXXXXXX`. Accepts spaces, dashes,
 * brackets and a +27 / 27 prefix, so "+27 82 123 4567" and "082-123-4567"
 * are the same login. Returns null when it is not a 10-digit number.
 */
function normalizePhone(raw) {
  let digits = String(raw || "").replace(/\D+/g, "");
  if (digits.startsWith("27") && digits.length === 11) digits = "0" + digits.slice(2);
  if (digits.length === 9 && !digits.startsWith("0")) digits = "0" + digits;
  return /^0\d{9}$/.test(digits) ? digits : null;
}

function checkPassword(raw) {
  if (typeof raw !== "string") return null;
  return raw.length >= MIN_PASSWORD && raw.length <= MAX_PASSWORD ? raw : null;
}

/** Firestore document ids the office links to: plain ids, never a path. */
const isSafeId = (id) => typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id);
const isWeekId = (id) => typeof id === "string" && /^\d{4}-\d{2}-\d{2}$/.test(id);

// Who can be picked on the sign-up page. Inactive and suspended distributors
// are left off, so the public list is today's crew only.
const PICKABLE_STATUSES = ["active", "onLeave"];

/** The name a distributor picks themselves by: the legal full name from
 *  their profile, else their schedule name until the office fills it in. */
function legalName(data) {
  const full = typeof data.fullName === "string" ? data.fullName.replace(/\s+/g, " ").trim() : "";
  if (full) return full;
  return typeof data.name === "string" ? data.name.trim() : "";
}

const isPickable = (data) => PICKABLE_STATUSES.includes(data.status || "active") && legalName(data) !== "";

// ── Passwords and sessions ───────────────────────────────────────────────────

const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

function scrypt(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, SCRYPT, (err, key) => (err ? reject(err) : resolve(key)));
  });
}

async function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const key = await scrypt(password, salt);
  return { hash: key.toString("base64"), salt: salt.toString("base64") };
}

async function verifyPassword(password, hash, salt) {
  if (typeof hash !== "string" || typeof salt !== "string") return false;
  const expected = Buffer.from(hash, "base64");
  const key = await scrypt(password, Buffer.from(salt, "base64"));
  return key.length === expected.length && crypto.timingSafeEqual(key, expected);
}

const sha256 = (text) => crypto.createHash("sha256").update(text).digest("hex");

/** The code the person reads out to the office, so an admin can tell their
 *  request from one somebody else made with their phone number. */
const signupCode = () => String(crypto.randomInt(1000, 10000));

async function createSession(accountId, keepSignedIn) {
  const token = crypto.randomBytes(32).toString("base64url");
  const life = keepSignedIn ? KEEP_SIGNED_IN_MS : SHORT_SESSION_MS;
  await db().collection(SESSIONS).doc(sha256(token)).set({
    accountId,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + life),
  });
  return token;
}

/** The session's account, or a 401 the page treats as "signed out". */
async function requireSession(token) {
  const signedOut = new PortalError(401, "signedOut", "Please sign in again.");
  if (typeof token !== "string" || token.length < 20 || token.length > 200) throw signedOut;
  const ref = db().collection(SESSIONS).doc(sha256(token));
  const session = await ref.get();
  if (!session.exists) throw signedOut;
  const expiresAt = session.get("expiresAt");
  if (!expiresAt || expiresAt.toMillis() < Date.now()) {
    await ref.delete().catch(() => {});
    throw signedOut;
  }
  const account = await db().collection(ACCOUNTS).doc(session.get("accountId")).get();
  if (!account.exists) {
    await ref.delete().catch(() => {});
    throw signedOut;
  }
  return { sessionRef: ref, account };
}

/** Only what the phone needs to know about its own account. */
function publicAccount(data) {
  const out = {
    name: data.name || "",
    phone: data.phone || "",
    status: data.status || "pending",
  };
  if (out.status === "pending") out.signupCode = data.signupCode || "";
  if (out.status === "approved") out.distributorName = data.distributorName || "";
  return out;
}

function requireApproved(account) {
  const data = account.data();
  if (data.status !== "approved" || !isSafeId(data.distributorId)) {
    throw new PortalError(403, "notApproved",
      "The office has not approved your account yet.");
  }
  return data.distributorId;
}

// ── Dates (SAST civil dates, kept as UTC-field millis like the app does) ─────

/** A stored instant as SAST wall-clock millis (fields read with getUTC*). */
const civilMs = (ts) => (ts && typeof ts.toMillis === "function" ? ts.toMillis() + SAST_OFFSET_MS : null);

function weekIdToCivilMs(weekId) {
  const [y, m, d] = weekId.split("-").map(Number);
  return Date.UTC(y, m - 1, d);
}

/** `yyyy-mm-dd` for a civil millis value. */
function isoDay(ms) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

/** payroll/{year}/{monthLabel}/{weekId}: the month is the week START's. */
function weekDocRef(weekId) {
  const [y, m] = weekId.split("-").map(Number);
  return db().collection("payroll").doc(String(y))
    .collection(`${MONTH_NAMES_SHORT[m - 1]} ${y}`).doc(weekId);
}

// ── Payslip maths: a port of lib/utils/payroll_calculator.dart and
//    lib/utils/repayment_schedule.dart, so the web payslip says what the
//    printed one (lib/utils/payroll_pdf.dart) says. Change them together. ───

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);

function dailyBasic(entry, dayRate) {
  return entry.worked ? dayRate : 0;
}

function dailyBonus(entry, bonusCodeAmounts, perSetRate, estimateBonus) {
  if (!entry.worked) return 0;
  const code = entry.specialCode;
  if (code) return num(bonusCodeAmounts[code]);
  const sets = entry.flyerSets;
  if (typeof sets !== "number" || sets < 1) return 0;
  const noIssueLogged = String(entry.notes || "").trim() === "";
  const achievement = entry.estimateReached === true && noIssueLogged ? estimateBonus : 0;
  return achievement + perSetRate * (sets - 1);
}

/** linkedWeekId on or before weekId; null (a manual entry) always counts. */
const isOnOrBeforeWeek = (linkedWeekId, weekId) =>
  linkedWeekId == null || String(linkedWeekId) <= weekId;

function belongsOnPayslip({ originMs, totalAmount, weekEndMs, weekId, payments }) {
  if (originMs > weekEndMs) return false;
  let paidToDate = 0;
  let touchedThisWeek = false;
  for (const p of payments) {
    if (p.linkedWeekId === weekId) touchedThisWeek = true;
    if (isOnOrBeforeWeek(p.linkedWeekId, weekId)) paidToDate += p.amount;
  }
  return touchedThisWeek || totalAmount - paidToDate > 0.005;
}

function buildRepaymentSchedule({ totalAmount, instalmentAmount, originMs, actualPayments }) {
  const sorted = [...actualPayments].sort((a, b) => a.dateMs - b.dateMs);
  const entries = sorted.map((p) => ({ dateMs: p.dateMs, amount: p.amount, actual: true }));
  let remaining = totalAmount - sorted.reduce((t, p) => t + p.amount, 0);
  let cursor = sorted.length ? sorted[sorted.length - 1].dateMs : originMs;
  if (instalmentAmount > 0) {
    let guard = 0;
    while (remaining > 0.005 && guard < 520) {
      cursor += 7 * DAY_MS;
      const amount = remaining < instalmentAmount ? remaining : instalmentAmount;
      entries.push({ dateMs: cursor, amount, actual: false });
      remaining -= amount;
      guard++;
    }
  }
  return entries;
}

const round2 = (v) => Math.round(v * 100) / 100;

/** "eWallet ••• 4567" / "Capitec ••• 1234": enough to recognise, not to reuse. */
function maskedAccount(snapshot) {
  if (!snapshot || typeof snapshot !== "object") return null;
  const isWallet = snapshot.method !== "Bank account";
  const number = String((isWallet ? snapshot.ewalletNumber : snapshot.accountNumber) || "").replace(/\s+/g, "");
  const last4 = number.length >= 4 ? number.slice(-4) : "";
  const label = isWallet ? "eWallet" : (String(snapshot.bankName || "").trim() || "Bank account");
  return last4 ? `${label} ••• ${last4}` : label;
}

/**
 * Everything the web page draws for one paid payslip. Pure: takes plain
 * objects (ledger rows already converted to civil millis) and returns plain
 * JSON, so it can be tested without Firestore.
 */
function buildPayslipView({
  weekId, payslip, advances, repayments, deposits, withdrawals, settings, distributor,
}) {
  const weekStartMs = weekIdToCivilMs(weekId);
  const weekEndMs = weekStartMs + 6 * DAY_MS;
  const payDateMs = weekStartMs + 7 * DAY_MS;

  const labels = { ...DEFAULT_BONUS_CODE_LABELS, ...((settings && settings.bonusCodeLabels) || {}) };
  const dayRate = num(payslip.dayRateSnapshot);
  const bonusAmounts = payslip.bonusCodeAmountsSnapshot || {};
  const perSet = num(payslip.perSetRateSnapshot);
  const estimate = num(payslip.estimateBonusSnapshot);

  const entries = payslip.dailyEntries || {};
  const days = Object.keys(entries).filter(isWeekId).sort().map((key) => {
    const e = entries[key] || {};
    const basic = dailyBasic(e, dayRate);
    const bonus = dailyBonus(e, bonusAmounts, perSet, estimate);
    let label;
    if (!e.worked) {
      label = "Off";
    } else if (e.specialCode) {
      const l = labels[e.specialCode];
      label = l && String(l).trim() ? `${e.specialCode} - ${l}` : e.specialCode;
    } else {
      const sets = typeof e.flyerSets === "number" ? e.flyerSets : 0;
      label = `${sets} set${sets === 1 ? "" : "s"}`;
    }
    return { date: key, label, basic: round2(basic), bonus: round2(bonus), total: round2(basic + bonus) };
  });

  // Deductions (advances and penalties), as payroll_pdf.dart _buildDeductionsTable.
  const deductionRows = [];
  const counters = {};
  const relevantAdvances = advances
    .filter((a) => belongsOnPayslip({
      originMs: a.datePaidMs, totalAmount: a.amount, weekEndMs, weekId,
      payments: repayments.filter((r) => r.advanceId === a.id),
    }))
    .sort((a, b) => a.datePaidMs - b.datePaidMs);
  for (const item of relevantAdvances) {
    const type = item.type === "penalty" ? "Penalty" : "Advance";
    counters[type] = (counters[type] || 0) + 1;
    const mine = repayments.filter((r) => r.advanceId === item.id);
    const schedule = buildRepaymentSchedule({
      totalAmount: item.amount,
      instalmentAmount: item.preferredInstallmentAmount,
      originMs: item.datePaidMs,
      actualPayments: mine.filter((r) => isOnOrBeforeWeek(r.linkedWeekId, weekId)),
    });
    const thisWeek = mine.filter((r) => r.linkedWeekId === weekId).reduce((t, r) => t + r.amount, 0);
    deductionRows.push({
      title: item.label && item.label.trim() ? item.label.trim() : `${type} ${counters[type]}`,
      date: isoDay(item.datePaidMs),
      amount: round2(item.amount),
      instalments: schedule.length,
      instalmentAmount: round2(item.preferredInstallmentAmount),
      note: item.note && item.note.trim() ? item.note.trim() : "",
      lastInstalment: schedule.length ? isoDay(schedule[schedule.length - 1].dateMs) : null,
      thisWeek: round2(thisWeek),
      schedule: schedule.map((s) => ({ date: isoDay(s.dateMs), amount: round2(s.amount), actual: s.actual })),
    });
  }

  // Savings, as _buildSavingsTable.
  const savingsRows = [];
  let savingsCount = 0;
  const relevantDeposits = deposits
    .filter((d) => belongsOnPayslip({
      originMs: d.dateDepositedMs, totalAmount: d.amount, weekEndMs, weekId,
      payments: withdrawals.filter((w) => w.depositId === d.id),
    }))
    .sort((a, b) => a.dateDepositedMs - b.dateDepositedMs);
  for (const item of relevantDeposits) {
    savingsCount++;
    const mine = withdrawals.filter((w) => w.depositId === item.id);
    const schedule = buildRepaymentSchedule({
      totalAmount: item.amount,
      instalmentAmount: item.preferredWithdrawalAmount,
      originMs: item.dateDepositedMs,
      actualPayments: mine.filter((w) => isOnOrBeforeWeek(w.linkedWeekId, weekId)),
    });
    const thisWeek = mine.filter((w) => w.linkedWeekId === weekId).reduce((t, w) => t + w.amount, 0);
    savingsRows.push({
      title: item.note && item.note.trim() ? item.note.trim() : `Savings ${savingsCount}`,
      date: isoDay(item.dateDepositedMs),
      amount: round2(item.amount),
      instalments: schedule.length,
      instalmentAmount: round2(item.preferredWithdrawalAmount),
      lastInstalment: schedule.length ? isoDay(schedule[schedule.length - 1].dateMs) : null,
      thisWeek: round2(thisWeek),
      schedule: schedule.map((s) => ({ date: isoDay(s.dateMs), amount: round2(s.amount), actual: s.actual })),
    });
  }

  // Balances AS AT this week, so an old payslip shows what was owed then
  // rather than today's figure.
  const owedAsAt = advances
    .filter((a) => a.datePaidMs <= weekEndMs)
    .reduce((t, a) => {
      const repaid = repayments
        .filter((r) => r.advanceId === a.id && isOnOrBeforeWeek(r.linkedWeekId, weekId))
        .reduce((s, r) => s + r.amount, 0);
      return t + Math.max(0, a.amount - repaid);
    }, 0);
  const savedAsAt = deposits
    .filter((d) => d.dateDepositedMs <= weekEndMs)
    .reduce((t, d) => {
      const taken = withdrawals
        .filter((w) => w.depositId === d.id && isOnOrBeforeWeek(w.linkedWeekId, weekId))
        .reduce((s, w) => s + w.amount, 0);
      return t + Math.max(0, d.amount - taken);
    }, 0);

  // The letterhead, as payroll_pdf.dart draws it.
  const logo = settings && typeof settings.companyLogoUrl === "string" ? settings.companyLogoUrl : "";
  const company = {
    name: companySetting(settings, "companyName"),
    addressLines: companySetting(settings, "companyAddress")
      .split("\n").map((l) => l.trim()).filter(Boolean),
    phone: companySetting(settings, "companyPhone"),
    email: companySetting(settings, "companyEmail"),
    vatNo: companySetting(settings, "companyVatNo"),
    registrationNo: companySetting(settings, "companyRegistrationNo"),
    // Only a Firebase Storage link (company/ is public-read); the page falls
    // back to its own copy of assets/logo.png.
    logoUrl: /^https:\/\/firebasestorage\.googleapis\.com\//.test(logo) ? logo : null,
  };

  const text = (v) => (typeof v === "string" ? v.trim() : "");
  const fullName = text(distributor && distributor.fullName);
  const extra = num(payslip.extraEarningsAmount);
  const paidAt = civilMs(payslip.paidAt);

  return {
    weekId,
    weekStart: isoDay(weekStartMs),
    weekEnd: isoDay(weekEndMs),
    payDate: isoDay(payDateMs),
    company,
    name: fullName || payslip.distributorName || "",
    // The distributor's own details, printed on the office's payslip too.
    idNumber: text(distributor && distributor.idNumber),
    homeAddress: text(distributor && distributor.homeAddress),
    days,
    grossWage: round2(num(payslip.grossWage)),
    deductions: deductionRows,
    savings: savingsRows,
    extraEarnings: extra !== 0
      ? { amount: round2(extra), note: String(payslip.extraEarningsNote || "") }
      : null,
    netWage: round2(num(payslip.netWage)),
    owedBalance: round2(owedAsAt),
    savingsBalance: round2(savedAsAt),
    paid: {
      amount: typeof payslip.paidAmount === "number" ? round2(payslip.paidAmount) : null,
      date: paidAt != null ? isoDay(paidAt) : null,
      to: maskedAccount(payslip.paymentAccountSnapshot),
    },
  };
}

// ── Firestore reads (only ever one distributor's payslip) ────────────────────

/** Every Paid week for [distId], newest first, this year and last. */
async function listPaidWeeks(distId) {
  const nowYear = new Date(Date.now() + SAST_OFFSET_MS).getUTCFullYear();
  const yearRefs = (await db().collection("payroll").listDocuments())
    .filter((r) => /^\d{4}$/.test(r.id) && Number(r.id) >= nowYear - PAYSLIP_YEARS_BACK);
  const months = (await Promise.all(yearRefs.map((r) => r.listCollections()))).flat();

  const field = (f) => new FieldPath("payslips", distId, f);
  const snaps = await Promise.all(months.map((col) => col
    .select(field("paymentStatus"), field("netWage"), field("paidAmount"), field("paidAt"))
    .get()));

  const weeks = [];
  for (const snap of snaps) {
    for (const doc of snap.docs) {
      if (!isWeekId(doc.id)) continue;
      const p = doc.get(new FieldPath("payslips", distId));
      if (!p || p.paymentStatus !== "paid") continue;
      const start = weekIdToCivilMs(doc.id);
      const paidAt = civilMs(p.paidAt);
      weeks.push({
        weekId: doc.id,
        weekStart: doc.id,
        weekEnd: isoDay(start + 6 * DAY_MS),
        payDate: isoDay(start + 7 * DAY_MS),
        netWage: round2(num(p.netWage)),
        paidAmount: typeof p.paidAmount === "number" ? round2(p.paidAmount) : null,
        paidDate: paidAt != null ? isoDay(paidAt) : null,
      });
    }
  }
  return weeks.sort((a, b) => (a.weekId < b.weekId ? 1 : -1));
}

async function loadLedgers(distId) {
  const adv = db().collection("payrollAdvances").doc(distId);
  const sav = db().collection("payrollSavings").doc(distId);
  const [advances, repayments, deposits, withdrawals] = await Promise.all([
    adv.collection("advances").get(),
    adv.collection("repayments").get(),
    sav.collection("deposits").get(),
    sav.collection("withdrawals").get(),
  ]);
  const created = (d) => civilMs(d.get("createdAt")) ?? 0;
  return {
    advances: advances.docs.map((d) => ({
      id: d.id,
      type: d.get("type"),
      label: d.get("label") || null,
      amount: num(d.get("amount")),
      datePaidMs: civilMs(d.get("datePaid")) ?? created(d),
      preferredInstallmentAmount: num(d.get("preferredInstallmentAmount")),
      note: d.get("note") || null,
    })),
    repayments: repayments.docs.map((d) => ({
      advanceId: d.get("advanceId") || "",
      amount: num(d.get("amount")),
      dateMs: civilMs(d.get("date")) ?? created(d),
      linkedWeekId: d.get("linkedWeekId") ?? null,
    })),
    deposits: deposits.docs.map((d) => ({
      id: d.id,
      amount: num(d.get("amount")),
      dateDepositedMs: civilMs(d.get("dateDeposited")) ?? created(d),
      preferredWithdrawalAmount: num(d.get("preferredWithdrawalAmount")),
      note: d.get("note") || null,
    })),
    withdrawals: withdrawals.docs.map((d) => ({
      depositId: d.get("depositId") || "",
      amount: num(d.get("amount")),
      dateMs: civilMs(d.get("date")) ?? created(d),
      linkedWeekId: d.get("linkedWeekId") ?? null,
    })),
  };
}

// ── Actions ──────────────────────────────────────────────────────────────────

async function signup(body) {
  const phone = normalizePhone(body.phone);
  const password = checkPassword(body.password);
  // They pick themselves from the list (`names`); the name stored is the one
  // on the profile, never typed. It is only a claim: the office still checks
  // the code and decides which distributor the account is linked to.
  const claimedId = body.distributorId;
  const claimed = isSafeId(claimedId)
    ? await db().collection("distributors").doc(claimedId).get()
    : null;
  if (!claimed || !claimed.exists || !isPickable(claimed.data())) {
    throw new PortalError(400, "badName", "Choose your name from the list.");
  }
  const name = legalName(claimed.data());
  if (!phone) throw new PortalError(400, "badPhone", "Type a 10-digit cellphone number, like 082 123 4567.");
  if (!password) {
    throw new PortalError(400, "badPassword",
      `Choose a password of at least ${MIN_PASSWORD} characters.`);
  }

  const pending = await db().collection(ACCOUNTS).where("status", "==", "pending").count().get();
  if (pending.data().count >= MAX_PENDING) {
    throw new PortalError(429, "busy",
      "There are too many sign-ups waiting for the office. Try again later.");
  }

  const { hash, salt } = await hashPassword(password);
  const accountRef = db().collection(ACCOUNTS).doc();
  const loginRef = db().collection(LOGINS).doc(phone);
  const code = signupCode();

  await db().runTransaction(async (t) => {
    const login = await t.get(loginRef);
    const previousId = login.exists ? login.get("accountId") : null;
    if (previousId) {
      const previous = await t.get(db().collection(ACCOUNTS).doc(previousId));
      const status = previous.exists ? previous.get("status") : null;
      if (status === "pending" || status === "approved") {
        throw new PortalError(409, "exists",
          "This phone number already has an account. Sign in instead, " +
          "or ask the office to reset it if you forgot your password.");
      }
    }
    t.create(accountRef, {
      name,
      claimedDistributorId: claimed.id,
      phone,
      status: "pending",
      signupCode: code,
      createdAt: FieldValue.serverTimestamp(),
    });
    // Replaces a rejected or removed account's login: that old account
    // stays as a record but can no longer be signed in to.
    t.set(loginRef, {
      accountId: accountRef.id,
      hash,
      salt,
      failedLogins: 0,
      lockedUntil: null,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  const token = await createSession(accountRef.id, body.keepSignedIn !== false);
  return { token, account: publicAccount({ name, phone, status: "pending", signupCode: code }) };
}

async function login(body) {
  const wrong = new PortalError(401, "wrongPassword", "Wrong phone number or password.");
  const phone = normalizePhone(body.phone);
  const password = typeof body.password === "string" ? body.password : "";
  if (!phone || !password || password.length > MAX_PASSWORD) {
    await sleep(500);
    throw wrong;
  }

  const loginRef = db().collection(LOGINS).doc(phone);
  const snap = await loginRef.get();
  if (!snap.exists) {
    await sleep(500);
    throw wrong;
  }
  const lockedUntil = snap.get("lockedUntil");
  if (lockedUntil && lockedUntil.toMillis() > Date.now()) {
    const minutes = Math.ceil((lockedUntil.toMillis() - Date.now()) / 60000);
    throw new PortalError(429, "locked",
      `Too many wrong passwords. Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`);
  }

  if (!(await verifyPassword(password, snap.get("hash"), snap.get("salt")))) {
    await db().runTransaction(async (t) => {
      const fresh = await t.get(loginRef);
      const failures = (fresh.get("failedLogins") || 0) + 1;
      t.update(loginRef, failures >= MAX_FAILED_LOGINS
        ? { failedLogins: 0, lockedUntil: Timestamp.fromMillis(Date.now() + LOCK_MS) }
        : { failedLogins: failures });
    });
    await sleep(500);
    throw wrong;
  }
  if (snap.get("failedLogins")) {
    await loginRef.update({ failedLogins: 0, lockedUntil: null });
  }

  const accountRef = db().collection(ACCOUNTS).doc(snap.get("accountId"));
  const account = await accountRef.get();
  if (!account.exists) {
    throw new PortalError(403, "noAccount", "This account no longer exists. Sign up again.");
  }
  const status = account.get("status");
  if (status === "rejected") {
    throw new PortalError(403, "rejected",
      "The office did not approve this sign-up. Speak to the office, then sign up again.");
  }
  if (status === "removed") {
    throw new PortalError(403, "removed",
      "Your access was removed by the office. Speak to the office, then sign up again.");
  }

  const token = await createSession(account.id, body.keepSignedIn !== false);
  await accountRef.update({ lastLoginAt: FieldValue.serverTimestamp() }).catch(() => {});
  return { token, account: publicAccount(account.data()) };
}

/** The sign-up page's name list: legal names only, never phone or ID
 *  numbers. The id is what the page sends back with the sign-up. */
async function names() {
  const snap = await db().collection("distributors").get();
  const list = snap.docs
    .filter((d) => isPickable(d.data()))
    .map((d) => ({ id: d.id, name: legalName(d.data()) }))
    .sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
  return { names: list };
}

async function logout(body) {
  if (typeof body.token === "string" && body.token.length <= 200) {
    await db().collection(SESSIONS).doc(sha256(body.token)).delete().catch(() => {});
  }
  return { ok: true };
}

/** The account's state and, once approved, its list of paid weeks. */
async function status(body) {
  const { sessionRef, account } = await requireSession(body.token);
  const data = account.data();
  if (data.status === "rejected" || data.status === "removed") {
    await sessionRef.delete().catch(() => {});
    return { account: publicAccount(data) };
  }
  if (data.status !== "approved") return { account: publicAccount(data) };
  const distId = requireApproved(account);
  return { account: publicAccount(data), payslips: await listPaidWeeks(distId) };
}

async function payslip(body) {
  const { account } = await requireSession(body.token);
  const distId = requireApproved(account);
  const weekId = body.weekId;
  if (!isWeekId(weekId)) throw new PortalError(400, "badWeek", "Unknown week.");

  const weekSnap = await weekDocRef(weekId).get();
  const p = weekSnap.exists ? weekSnap.get(new FieldPath("payslips", distId)) : null;
  // One message for "no such week" and "not paid yet": nothing here says
  // whether an unpaid payslip exists.
  if (!p || p.paymentStatus !== "paid") {
    throw new PortalError(404, "notFound", "This payslip is not available.");
  }

  const [ledgers, settingsSnap, distributorSnap] = await Promise.all([
    loadLedgers(distId),
    db().collection("payrollSettings").doc("config").get(),
    db().collection("distributors").doc(distId).get(),
  ]);

  return {
    payslip: buildPayslipView({
      weekId,
      payslip: p,
      ...ledgers,
      settings: settingsSnap.exists ? settingsSnap.data() : {},
      distributor: distributorSnap.exists ? distributorSnap.data() : null,
    }),
  };
}

const ACTIONS = { names, signup, login, logout, status, payslip };

exports.payslipPortal = onRequest(
  { region: REGION, cors: true, maxInstances: 10 },
  async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (req.method !== "POST") return res.status(405).json({ error: "Use POST." });
    const body = req.body && typeof req.body === "object" ? req.body : {};
    const action = Object.prototype.hasOwnProperty.call(ACTIONS, body.action)
      ? ACTIONS[body.action]
      : null;
    if (!action) return res.status(400).json({ error: "Unknown action." });
    try {
      return res.status(200).json(await action(body));
    } catch (e) {
      if (e instanceof PortalError) {
        return res.status(e.status).json({ error: e.message, code: e.code });
      }
      console.error(`[payslipPortal] ${body.action} failed:`, e);
      return res.status(500).json({ error: "Something went wrong. Try again in a minute." });
    }
  }
);

// Exposed for tests.
exports._internal = {
  normalizePhone, legalName, isPickable, checkPassword, hashPassword, verifyPassword,
  buildPayslipView, buildRepaymentSchedule, belongsOnPayslip, maskedAccount,
  publicAccount, isSafeId,
};
