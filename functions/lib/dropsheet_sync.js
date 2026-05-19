/**
 * Server-side dropsheet sync.
 *
 * Mirrors the Pass-1 / Pass-2 logic from
 * `lib/providers/dropsheet_provider.dart::syncFromSchedule` but runs on
 * the server so:
 *   - The diff is computed once and broadcast to every connected client
 *     via the existing `dropsheet/daily/days/{YYYY-MM-DD}` Firestore
 *     listener.
 *   - Clients don't iterate the multi-pass sync loop on the main thread.
 *   - It can be wired to a Firestore trigger on schedule changes for
 *     fully automatic sync.
 *
 * Pass 1 — refresh existing drop-off tasks:
 *   • Match by `distributorJobId` first, fall back to `workArea` string.
 *   • Refresh distributor name / phone / typeData; preserve custom
 *     drop-off coords unless the task migrated to a different job.
 *
 * Pass 2 — append genuinely new schedule jobs to the synthetic
 *          "Unassigned stops" section.
 *
 * Exposed two ways:
 *   - `syncDropsheetFromSchedule` (callable) — explicit sync from the UI.
 *   - `onScheduleDayChanged` (Firestore trigger) — auto-sync whenever
 *     the day's schedule doc changes.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

// Must match `kUnassignedSectionId` in lib/providers/dropsheet_provider.dart.
const UNASSIGNED_SECTION_ID = "_unassigned";

function db() {
  return admin.firestore();
}

function dropsheetDocRef(dateId) {
  return db().collection("dropsheet").doc("daily").collection("days").doc(dateId);
}

function scheduleDocRef(dateId) {
  // YYYY-MM-DD → schedules/{YYYY-MM}/days/{YYYY-MM-DD}
  const monthId = dateId.slice(0, 7);
  return db().collection("schedules").doc(monthId).collection("days").doc(dateId);
}

async function loadDistributors() {
  const snap = await db().collection("distributors").get();
  const byId = {};
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    byId[doc.id] = {
      id: doc.id,
      name: data.name || doc.id,
      phone1: data.phone1 || "",
    };
  }
  return byId;
}

/**
 * Best-effort job extraction from a schedule day document. The schedule
 * stores jobs as an array under the `jobs` field; each entry has
 * `id`, `distributorId`, `workingAreas`, `dropOffPoint` (optional).
 */
function jobsFromScheduleDoc(scheduleDoc) {
  if (!scheduleDoc.exists) return [];
  const data = scheduleDoc.data() || {};
  const arr = Array.isArray(data.jobs) ? data.jobs : [];
  return arr.map((j) => ({
    id: j.id || "",
    distributorId: j.distributorId || "",
    workingAreas: Array.isArray(j.workingAreas) ? j.workingAreas : [],
    dropOffPoint: j.dropOffPoint || null,
  }));
}

function buildDropOffTask(job, distributorById) {
  const dist = distributorById[job.distributorId] || {};
  const wa = (job.workingAreas || []).join(", ");
  const td = {
    distributorJobId: job.id,
    distributorId: job.distributorId,
    distributorName: dist.name || job.distributorId,
    workArea: wa,
  };
  if (job.dropOffPoint && typeof job.dropOffPoint.latitude === "number") {
    td.lat = job.dropOffPoint.latitude;
    td.lng = job.dropOffPoint.longitude;
  }
  return {
    id: `t_${job.id}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    type: "dropOff",
    job: wa ? `Drop off: ${wa}` : "Drop off",
    details: dist.name || job.distributorId,
    location: wa,
    contact: dist.name || job.distributorId,
    tel: dist.phone1 || "",
    typeData: td,
    isMandatory: false,
  };
}

/**
 * Apply the Pass-1 / Pass-2 sync algorithm. Returns an updated
 * dropsheet day map ready to be written back to Firestore.
 *
 * Options:
 *   - destructive (default false): when true, drop-off tasks whose
 *     `distributorJobId` no longer matches any job in the current
 *     schedule (and whose `workArea` fallback also misses) are removed.
 *     ONLY safe for explicit user-initiated syncs.
 *
 *     When false (the auto-trigger path) existing tasks are NEVER
 *     removed or moved. Metadata is refreshed in place when a match is
 *     found; unmatched tasks are kept untouched so driver allocations
 *     can never be wiped by an unrelated schedule edit.
 */
function applySync(dropsheetData, jobs, distributorById, options) {
  const destructive = !!(options && options.destructive);
  const jobById = {};
  const workAreaByJobId = {};
  const jobByWorkArea = {};
  for (const j of jobs) {
    jobById[j.id] = j;
    const wa = (j.workingAreas || []).join(", ");
    workAreaByJobId[j.id] = wa;
    if (wa) jobByWorkArea[wa] = j;
  }

  const sections = Array.isArray(dropsheetData.sections) ? dropsheetData.sections : [];
  const consumed = new Set();

  // ── Pass 1 — refresh existing drop-off tasks ────────────────────
  const updatedSections = sections.map((section) => {
    const tasks = Array.isArray(section.tasks) ? section.tasks : [];
    const out = [];
    for (const task of tasks) {
      if (task.type !== "dropOff") {
        out.push(task);
        continue;
      }
      const td = task.typeData || {};
      const jobId = td.distributorJobId;
      if (!jobId) {
        out.push(task);
        continue;
      }
      let match = jobById[jobId];
      if (!match && td.workArea) match = jobByWorkArea[td.workArea];
      if (!match) {
        if (destructive) {
          // Explicit user-initiated cleanup: job moved or deleted, drop task.
          continue;
        }
        // Auto-trigger path: preserve the task as-is so driver
        // allocations are never wiped by an unrelated schedule write.
        out.push(task);
        continue;
      }
      consumed.add(match.id);
      const dist = distributorById[match.distributorId] || {};
      const wa = workAreaByJobId[match.id] || "";
      const newTd = {
        ...td,
        distributorJobId: match.id,
        distributorId: match.distributorId,
        distributorName: dist.name || match.distributorId,
        workArea: wa,
      };
      if (match.dropOffPoint && typeof match.dropOffPoint.latitude === "number") {
        newTd.lat = match.dropOffPoint.latitude;
        newTd.lng = match.dropOffPoint.longitude;
      } else if (jobId !== match.id) {
        delete newTd.lat;
        delete newTd.lng;
      }
      out.push({
        ...task,
        job: wa ? `Drop off: ${wa}` : "Drop off",
        details: dist.name || match.distributorId,
        location: wa,
        contact: dist.name || match.distributorId,
        tel: dist.phone1 || "",
        typeData: newTd,
      });
    }
    return { ...section, tasks: out };
  });

  // ── Pass 2 — append new schedule jobs to "Unassigned" ───────────
  const newJobs = jobs.filter((j) => j.id && !consumed.has(j.id));
  let finalSections = updatedSections;
  if (newJobs.length > 0) {
    const newTasks = newJobs.map((j) => buildDropOffTask(j, distributorById));
    const idx = finalSections.findIndex((s) => s.id === UNASSIGNED_SECTION_ID);
    if (idx === -1) {
      finalSections = [
        {
          id: UNASSIGNED_SECTION_ID,
          driverId: UNASSIGNED_SECTION_ID,
          driverName: "Unassigned stops",
          tasks: newTasks,
        },
        ...finalSections,
      ];
    } else {
      const existing = Array.isArray(finalSections[idx].tasks) ? finalSections[idx].tasks : [];
      finalSections = [
        ...finalSections.slice(0, idx),
        { ...finalSections[idx], tasks: [...existing, ...newTasks] },
        ...finalSections.slice(idx + 1),
      ];
    }
  }

  return { ...dropsheetData, sections: finalSections };
}

async function syncDay(dateId, options) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateId)) {
    throw new HttpsError("invalid-argument", "dateId must be YYYY-MM-DD");
  }
  const destructive = !!(options && options.destructive);

  const [scheduleSnap, dropsheetSnap, distributorById] = await Promise.all([
    scheduleDocRef(dateId).get(),
    dropsheetDocRef(dateId).get(),
    loadDistributors(),
  ]);

  const jobs = jobsFromScheduleDoc(scheduleSnap);
  const dropsheetData = dropsheetSnap.exists
    ? dropsheetSnap.data()
    : { date: dateId, sections: [] };

  // No dropsheet exists yet and no jobs to seed — bail out.
  if (!dropsheetSnap.exists && jobs.length === 0) {
    return { date: dateId, written: false, reason: "no-data" };
  }

  // Safety: an auto-trigger with zero schedule jobs must never wipe a
  // populated dropsheet. This can happen transiently when a schedule
  // doc is being rewritten as part of a multi-step move.
  if (!destructive && jobs.length === 0 && dropsheetSnap.exists) {
    return {
      date: dateId,
      written: false,
      reason: "auto-skip-empty-schedule",
    };
  }

  const next = applySync(dropsheetData, jobs, distributorById, { destructive });

  // Skip write if nothing actually changed — avoids re-triggering the
  // dropsheet listener on every schedule edit.
  if (dropsheetSnap.exists && shallowEqualSections(dropsheetData, next)) {
    return {
      date: dateId,
      written: false,
      reason: "no-changes",
      sectionCount: (next.sections || []).length,
      jobCount: jobs.length,
    };
  }

  await dropsheetDocRef(dateId).set(next, { merge: false });
  return {
    date: dateId,
    written: true,
    destructive,
    sectionCount: (next.sections || []).length,
    jobCount: jobs.length,
  };
}

/**
 * Cheap structural compare — returns true when the section/task shape
 * is identical so we can skip redundant writes. Stringified compare is
 * fine here: documents are small (tens of tasks) and this only runs
 * once per trigger invocation.
 */
function shallowEqualSections(a, b) {
  try {
    return JSON.stringify(a.sections || []) === JSON.stringify(b.sections || []);
  } catch (_) {
    return false;
  }
}

const syncDropsheetFromSchedule = onCall(
  { timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const dateId = (request.data && request.data.dateId) || "";
    // Explicit user-initiated sync — allowed to remove tasks whose
    // schedule job has gone away.
    return await syncDay(dateId, { destructive: true });
  }
);

/**
 * Auto-sync trigger: whenever a schedule day document changes,
 * recompute the matching dropsheet day. Debounced lightly via Firestore
 * idempotency — multiple rapid edits collapse into a single final write
 * because the function reads the latest schedule snapshot on each run.
 */
const onScheduleDayChanged = onDocumentWritten(
  "schedules/{monthId}/days/{dayId}",
  async (event) => {
    const dateId = event.params.dayId;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateId)) return;
    try {
      // Auto-trigger MUST be non-destructive — never delete or move
      // existing dropsheet tasks. It only refreshes metadata for tasks
      // whose job still exists and appends genuinely new jobs to the
      // "Unassigned stops" section.
      const result = await syncDay(dateId, { destructive: false });
      if (result && result.written === false && result.reason) {
        console.log(`[onScheduleDayChanged] ${dateId} skipped: ${result.reason}`);
      }
    } catch (err) {
      console.warn(`[onScheduleDayChanged] sync failed for ${dateId}: ${err.message}`);
    }
  }
);

module.exports = {
  syncDropsheetFromSchedule,
  onScheduleDayChanged,
  applySync, // exported for unit tests
};
