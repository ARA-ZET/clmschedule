/**
 * Lightweight test for the dropsheet_sync `applySync` algorithm.
 *
 * Verifies the critical bug fix: the auto-trigger (non-destructive)
 * path must never delete or move existing tasks, even when the schedule
 * no longer contains the matching job. Only the explicit user-initiated
 * (destructive) sync may prune stale drop-off tasks.
 *
 * Run with:  node test/dropsheet_sync.test.js
 */
const assert = require("assert");
const { applySync } = require("../lib/dropsheet_sync");

const distributorById = {
  d1: { id: "d1", name: "Alice", phone1: "111" },
  d2: { id: "d2", name: "Bob", phone1: "222" },
};

function makeDropsheetWithAllocatedTask() {
  return {
    date: "2026-05-12",
    sections: [
      {
        id: "driver1",
        driverId: "driver1",
        driverName: "Driver One",
        tasks: [
          {
            id: "t_mand_1",
            type: "inspect",
            job: "Inspect",
            isMandatory: true,
            typeData: {},
          },
          {
            id: "t_drop_j1",
            type: "dropOff",
            job: "Drop off: Area A",
            details: "Alice",
            location: "Area A",
            contact: "Alice",
            tel: "111",
            typeData: {
              distributorJobId: "j1",
              distributorId: "d1",
              distributorName: "Alice",
              workArea: "Area A",
            },
          },
        ],
      },
    ],
  };
}

// --- Test 1: non-destructive auto-trigger preserves allocations -------------
{
  const before = makeDropsheetWithAllocatedTask();
  // Schedule no longer has j1 — simulates a cross-date move or replace.
  const jobs = [];
  const after = applySync(before, jobs, distributorById, { destructive: false });
  const sec = after.sections[0];
  assert.strictEqual(sec.tasks.length, 2, "non-destructive must keep all tasks");
  assert.strictEqual(sec.tasks[1].id, "t_drop_j1", "allocated dropOff must survive");
  console.log("PASS: non-destructive preserves allocated drop-off tasks");
}

// --- Test 2: destructive explicit sync prunes stale tasks ------------------
{
  const before = makeDropsheetWithAllocatedTask();
  const jobs = [];
  const after = applySync(before, jobs, distributorById, { destructive: true });
  const sec = after.sections[0];
  assert.strictEqual(sec.tasks.length, 1, "destructive must prune stale dropOff");
  assert.strictEqual(sec.tasks[0].type, "inspect", "mandatory task must survive");
  console.log("PASS: destructive prunes stale drop-off tasks");
}

// --- Test 3: refresh metadata when match found (both modes) ----------------
for (const destructive of [false, true]) {
  const before = makeDropsheetWithAllocatedTask();
  const jobs = [
    {
      id: "j1",
      distributorId: "d2", // distributor reassigned
      workingAreas: ["Area A"],
      dropOffPoint: null,
    },
  ];
  const after = applySync(before, jobs, distributorById, { destructive });
  const task = after.sections[0].tasks[1];
  assert.strictEqual(task.contact, "Bob", `(destructive=${destructive}) metadata refreshed`);
  assert.strictEqual(task.typeData.distributorId, "d2");
  console.log(`PASS: metadata refresh (destructive=${destructive})`);
}

// --- Test 4: new jobs append to Unassigned section -------------------------
{
  const before = { date: "2026-05-12", sections: [] };
  const jobs = [
    {
      id: "j2",
      distributorId: "d1",
      workingAreas: ["Area B"],
      dropOffPoint: null,
    },
  ];
  const after = applySync(before, jobs, distributorById, { destructive: false });
  assert.strictEqual(after.sections.length, 1);
  assert.strictEqual(after.sections[0].id, "_unassigned",
    "section id must match dart kUnassignedSectionId");
  assert.strictEqual(after.sections[0].tasks.length, 1);
  console.log("PASS: new jobs appended to _unassigned section");
}

// --- Test 5: existing allocations NOT moved to unassigned ------------------
{
  const before = makeDropsheetWithAllocatedTask();
  // j1 still exists but with new workArea; also a new j2 appears.
  const jobs = [
    {
      id: "j1",
      distributorId: "d1",
      workingAreas: ["Area A"],
      dropOffPoint: null,
    },
    {
      id: "j2",
      distributorId: "d2",
      workingAreas: ["Area B"],
      dropOffPoint: null,
    },
  ];
  const after = applySync(before, jobs, distributorById, { destructive: false });
  // driver1 still owns j1's drop task.
  const driver1 = after.sections.find((s) => s.id === "driver1");
  assert.ok(driver1, "driver1 section preserved");
  assert.strictEqual(driver1.tasks.length, 2);
  assert.strictEqual(driver1.tasks[1].typeData.distributorJobId, "j1");
  // j2 ends up in unassigned.
  const unassigned = after.sections.find((s) => s.id === "_unassigned");
  assert.ok(unassigned, "unassigned section created for new job");
  assert.strictEqual(unassigned.tasks.length, 1);
  assert.strictEqual(unassigned.tasks[0].typeData.distributorJobId, "j2");
  console.log("PASS: allocations stay put, new jobs go to unassigned");
}

console.log("\nAll dropsheet_sync tests passed.");
