// node --test test/zoho_idempotency.test.js
//
// runIdempotent against an in-memory stand-in for Firestore: one create per
// key however many times (or how concurrently) the app sends it.
const test = require("node:test");
const assert = require("node:assert");
const { _runIdempotent: runIdempotent } = require("../lib/zoho_books.js");

function fakeDb() {
  const docs = new Map();
  let chain = Promise.resolve();
  const ref = (path) => ({
    path,
    get: async () => ({ exists: docs.has(path), data: () => docs.get(path) }),
    set: async (data) => { docs.set(path, { ...data }); },
    delete: async () => { docs.delete(path); },
  });
  return {
    docs,
    collection: (c) => ({ doc: (id) => ref(`${c}/${id}`) }),
    // Transactions run one at a time, as Firestore's serialisable ones
    // effectively do for a single document.
    runTransaction(fn) {
      const run = chain.then(() => fn({
        get: (r) => r.get(),
        set: (r, data) => { docs.set(r.path, { ...data }); },
      }));
      chain = run.catch(() => {});
      return run;
    },
  };
}

const args = { key: "clm-invoice-abc", op: "createInvoice", orgId: "747658013", uid: "u1" };

test("a repeated call replays the first result instead of creating again", async () => {
  const db = fakeDb();
  let creates = 0;
  const create = async () => ({ invoice: { invoice_id: `inv${++creates}` } });

  const first = await runIdempotent(args, create, db);
  const second = await runIdempotent(args, create, db);

  assert.strictEqual(creates, 1);
  assert.deepStrictEqual(second, first);
});

test("concurrent calls (impatient clicks) create once; the rest are told to wait", async () => {
  const db = fakeDb();
  let creates = 0;
  let release;
  const gate = new Promise((r) => { release = r; });
  const create = async () => { creates++; await gate; return { invoice: { invoice_id: "inv1" } }; };

  const calls = Array.from({ length: 12 }, () =>
    runIdempotent(args, create, db).then((v) => ({ ok: v }), (e) => ({ err: e })));
  // Let every call reach its claim before Zoho "answers".
  await new Promise((r) => setTimeout(r, 10));
  release();
  const results = await Promise.all(calls);

  assert.strictEqual(creates, 1);
  assert.strictEqual(results.filter((r) => r.ok).length, 1);
  for (const r of results.filter((r) => r.err)) {
    assert.strictEqual(r.err.code, "aborted");
  }
  // Once it has finished, a retry gets the invoice back.
  const retry = await runIdempotent(args, create, db);
  assert.strictEqual(retry.invoice.invoice_id, "inv1");
  assert.strictEqual(creates, 1);
});

test("a failed create releases the key so a genuine retry can run", async () => {
  const db = fakeDb();
  let attempts = 0;
  const flaky = async () => {
    attempts++;
    if (attempts === 1) throw new Error("Zoho said no");
    return { invoice: { invoice_id: "inv2" } };
  };

  await assert.rejects(runIdempotent(args, flaky, db), /Zoho said no/);
  const ok = await runIdempotent(args, flaky, db);
  assert.strictEqual(ok.invoice.invoice_id, "inv2");
  assert.strictEqual(attempts, 2);
});

test("a key reused for a different operation is refused", async () => {
  const db = fakeDb();
  await runIdempotent(args, async () => ({ invoice: {} }), db);
  await assert.rejects(
    runIdempotent({ ...args, op: "recordPayment" }, async () => ({}), db),
    (e) => e.code === "invalid-argument");
});

test("different keys are independent", async () => {
  const db = fakeDb();
  let creates = 0;
  const create = async () => ({ n: ++creates });
  await runIdempotent(args, create, db);
  await runIdempotent({ ...args, key: "clm-invoice-other" }, create, db);
  assert.strictEqual(creates, 2);
});
