// node --test test/payslip_portal.test.js
//
// The pure parts of the distributor payslip portal: login input checks,
// password hashing, and the payslip maths ported from the Dart payroll code.
const test = require("node:test");
const assert = require("node:assert");
const {
  normalizePhone, legalName, isPickable, checkPassword, hashPassword, verifyPassword,
  buildPayslipView, buildRepaymentSchedule, maskedAccount, publicAccount, isSafeId,
} = require("../lib/payslip_portal.js")._internal;

const DAY = 24 * 60 * 60 * 1000;
const civil = (iso) => {
  const [y, m, d] = iso.split("-").map(Number);
  return Date.UTC(y, m - 1, d);
};

test("phone numbers in any common format become one login", () => {
  for (const raw of ["082 123 4567", "0821234567", "+27 82 123 4567", "27821234567", "(082) 123-4567", "821234567"]) {
    assert.strictEqual(normalizePhone(raw), "0821234567", raw);
  }
  for (const raw of ["", "12345", "08212345678", "abc", null, undefined, "+44 7700 900123"]) {
    assert.strictEqual(normalizePhone(raw), null, String(raw));
  }
});

test("the sign-up list shows legal names, falling back to the schedule name", () => {
  assert.strictEqual(legalName({ name: "Thabo", fullName: "  Thabo   Mokoena " }), "Thabo Mokoena");
  assert.strictEqual(legalName({ name: "Thabo", fullName: "  " }), "Thabo");
  assert.strictEqual(legalName({ name: "Thabo" }), "Thabo");
  assert.ok(isPickable({ name: "A" }), "no status = active");
  assert.ok(isPickable({ name: "A", status: "onLeave" }));
  assert.ok(!isPickable({ name: "A", status: "inactive" }));
  assert.ok(!isPickable({ name: "A", status: "suspended" }));
  assert.ok(!isPickable({ name: " ", status: "active" }));
});

test("passwords are bounded", () => {
  assert.strictEqual(checkPassword("12345"), null);
  assert.strictEqual(checkPassword("123456"), "123456");
  assert.strictEqual(checkPassword(123456), null);
});

test("passwords hash with a salt and verify only the right one", async () => {
  const a = await hashPassword("secret99");
  const b = await hashPassword("secret99");
  assert.notStrictEqual(a.hash, b.hash, "salted");
  assert.ok(await verifyPassword("secret99", a.hash, a.salt));
  assert.ok(!(await verifyPassword("secret98", a.hash, a.salt)));
  assert.ok(!(await verifyPassword("secret99", undefined, a.salt)));
});

test("distributor ids must be plain document ids, never paths", () => {
  assert.ok(isSafeId("abcDEF123_-"));
  assert.ok(!isSafeId("a/b"));
  assert.ok(!isSafeId(""));
  assert.ok(!isSafeId("payslips.x"));
  assert.ok(!isSafeId(undefined));
});

test("the phone only learns its own account's state", () => {
  assert.deepStrictEqual(
    publicAccount({ name: "A", phone: "0821234567", status: "pending", signupCode: "1234", distributorId: "x" }),
    { name: "A", phone: "0821234567", status: "pending", signupCode: "1234" });
  assert.deepStrictEqual(
    publicAccount({ name: "A", phone: "0821234567", status: "approved", signupCode: "1234", distributorId: "x", distributorName: "Ann" }),
    { name: "A", phone: "0821234567", status: "approved", distributorName: "Ann" });
});

test("only a Firebase Storage logo link is passed on", () => {
  const view = (url) => buildPayslipView({
    weekId: "2026-10-30", payslip: { dailyEntries: {} }, advances: [], repayments: [],
    deposits: [], withdrawals: [], settings: { companyLogoUrl: url }, distributor: null,
  }).company.logoUrl;
  const good = "https://firebasestorage.googleapis.com/v0/b/x/o/company%2Flogo.png?alt=media&token=t";
  assert.strictEqual(view(good), good);
  assert.strictEqual(view("javascript:alert(1)"), null);
  assert.strictEqual(view("https://evil.example/logo.png"), null);
});

test("bank details are masked", () => {
  assert.strictEqual(maskedAccount({ method: "eWallet", ewalletNumber: "082 123 4567" }), "eWallet ••• 4567");
  assert.strictEqual(maskedAccount({ method: "Bank account", bankName: "Capitec", accountNumber: "1234567890" }), "Capitec ••• 7890");
  assert.strictEqual(maskedAccount(null), null);
});

test("repayment schedule: actual payments then weekly projection", () => {
  const s = buildRepaymentSchedule({
    totalAmount: 300,
    instalmentAmount: 100,
    originMs: civil("2026-10-01"),
    actualPayments: [{ dateMs: civil("2026-10-10"), amount: 100 }],
  });
  assert.deepStrictEqual(s.map((e) => [new Date(e.dateMs).toISOString().slice(0, 10), e.amount, e.actual]), [
    ["2026-10-10", 100, true],
    ["2026-10-17", 100, false],
    ["2026-10-24", 100, false],
  ]);
});

// One week, Fri 2026-10-30 .. Thu 2026-11-05, matching the wage formula in
// lib/utils/payroll_calculator.dart: basic = day rate when worked; bonus =
// code amount, or perSet*(sets-1) + estimate bonus (estimate reached, no notes).
test("payslip view matches the printed payslip's maths", () => {
  const weekId = "2026-10-30";
  const payslip = {
    distributorName: "Thabo",
    dayRateSnapshot: 213,
    bonusCodeAmountsSnapshot: { DR: 155 },
    perSetRateSnapshot: 37,
    estimateBonusSnapshot: 45,
    dailyEntries: {
      "2026-10-30": { worked: true, flyerSets: 3, estimateReached: true, notes: "" }, // 213 + 74 + 45
      "2026-10-31": { worked: true, flyerSets: 2, estimateReached: true, notes: "late" }, // 213 + 37, no estimate
      "2026-11-01": { worked: false },
      "2026-11-02": { worked: true, specialCode: "DR" }, // 213 + 155
    },
    grossWage: 950,
    netWage: 850,
    paymentStatus: "paid",
    paidAmount: 850,
    paymentAccountSnapshot: { method: "eWallet", ewalletNumber: "0821234567" },
  };
  const advances = [
    // Taken before this week, R100 repaid this week, R100 earlier: on the slip.
    { id: "a1", type: "advance", label: null, amount: 500, datePaidMs: civil("2026-10-01"), preferredInstallmentAmount: 100, note: "" },
    // Settled two weeks earlier: dropped from the slip.
    { id: "a2", type: "penalty", label: "Lost phone", amount: 50, datePaidMs: civil("2026-09-01"), preferredInstallmentAmount: 50, note: "" },
    // Taken after this week: not on the slip, not in the as-at balance.
    { id: "a3", type: "advance", label: null, amount: 999, datePaidMs: civil("2026-11-10"), preferredInstallmentAmount: 100, note: "" },
  ];
  const repayments = [
    { advanceId: "a1", amount: 100, dateMs: civil("2026-10-23"), linkedWeekId: "2026-10-23" },
    { advanceId: "a1", amount: 100, dateMs: civil("2026-10-30"), linkedWeekId: weekId },
    // A later week's repayment must not count towards this slip's balance.
    { advanceId: "a1", amount: 100, dateMs: civil("2026-11-06"), linkedWeekId: "2026-11-06" },
    { advanceId: "a2", amount: 50, dateMs: civil("2026-10-16"), linkedWeekId: "2026-10-16" },
  ];

  const view = buildPayslipView({
    weekId, payslip, advances, repayments, deposits: [], withdrawals: [],
    settings: { companyName: "CLM", companyVatNo: "" },
    distributor: { fullName: "Thabo Mokoena", idNumber: " 9001015800085 ", phone1: "0821234567" },
  });

  assert.strictEqual(view.weekEnd, "2026-11-05");
  assert.strictEqual(view.payDate, "2026-11-06");
  assert.strictEqual(view.name, "Thabo Mokoena");
  assert.deepStrictEqual(view.days.map((d) => [d.date, d.label, d.total]), [
    ["2026-10-30", "3 sets", 332],
    ["2026-10-31", "2 sets", 250],
    ["2026-11-01", "Off", 0],
    ["2026-11-02", "DR - Driving", 368],
  ]);
  assert.strictEqual(view.deductions.length, 1);
  const d = view.deductions[0];
  assert.strictEqual(d.title, "Advance 1");
  assert.strictEqual(d.thisWeek, 100);
  // 2 actual (as at this week) + 3 projected = 5 instalments of R100.
  assert.strictEqual(d.instalments, 5);
  assert.deepStrictEqual(d.schedule.map((s) => s.actual), [true, true, false, false, false]);
  assert.strictEqual(view.owedBalance, 300);
  assert.strictEqual(view.savingsBalance, 0);
  assert.strictEqual(view.netWage, 850);
  assert.deepStrictEqual(view.paid, { amount: 850, date: null, to: "eWallet ••• 4567" });
  assert.strictEqual(view.company.name, "CLM");
  // A stored empty string wins over the default, as in PayrollSettings.fromMap.
  assert.strictEqual(view.company.vatNo, "");
  assert.strictEqual(view.company.registrationNo, "2013/128702/07");
  assert.strictEqual(view.company.logoUrl, null);
  // Their own ID is on the slip, as on the printed one; the full account
  // number and their phone number are not.
  assert.strictEqual(view.idNumber, "9001015800085");
  assert.strictEqual(view.homeAddress, "");
  const json = JSON.stringify(view);
  assert.ok(!json.includes("0821234567"));
});

test("savings: the week that empties a deposit still shows it", () => {
  const weekId = "2026-10-30";
  const view = buildPayslipView({
    weekId,
    payslip: { distributorName: "A", dailyEntries: {}, grossWage: 0, netWage: 200 },
    advances: [], repayments: [],
    deposits: [{ id: "s1", amount: 200, dateDepositedMs: civil("2026-09-01"), preferredWithdrawalAmount: 0, note: "Christmas" }],
    withdrawals: [{ depositId: "s1", amount: 200, dateMs: civil("2026-10-30"), linkedWeekId: weekId }],
    settings: {}, distributor: null,
  });
  assert.strictEqual(view.savings.length, 1);
  assert.strictEqual(view.savings[0].title, "Christmas");
  assert.strictEqual(view.savings[0].thisWeek, 200);
  assert.strictEqual(view.savingsBalance, 0);
  assert.strictEqual(view.name, "A");
  assert.strictEqual(view.company.name, "Community Life Media");
  assert.strictEqual(view.company.vatNo, "4500285780");
});
