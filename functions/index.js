const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onObjectFinalized, onObjectDeleted } = require("firebase-functions/v2/storage");
const admin = require("firebase-admin");
const { GoogleGenAI } = require("@google/genai");
const { XMLParser } = require("fast-xml-parser");

admin.initializeApp();
const db = admin.firestore();

/** Lazily resolve the default storage bucket. */
function getBucket() {
  return admin.storage().bucket();
}

// Firebase AI Logic — uses Vertex AI backend with ADC (no API key needed)
// ============================================================
// LOOKUP MAP CACHE — avoids re-reading lookup collections
// on every function call. Cached for 5 minutes (TTL).
// ============================================================
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes
let _lookupCache = null;
let _lookupCacheTimestamp = 0;

/**
 * Returns cached lookup maps (distributors, statuses, invoice statuses, job types).
 * Re-reads from Firestore only if the cache is stale (older than CACHE_TTL_MS).
 */
async function getLookupMaps() {
  const now = Date.now();
  if (_lookupCache && (now - _lookupCacheTimestamp) < CACHE_TTL_MS) {
    return _lookupCache;
  }

  const [distributorsSnap, statusesSnap, invoiceStatusesSnap, jobTypesSnap] = await Promise.all([
    db.collection("distributors").get(),
    db.collection("customJobStatuses").get(),
    db.collection("customInvoiceStatuses").get(),
    db.collection("customJobTypes").get(),
  ]);

  const distributorMap = {};
  for (const doc of distributorsSnap.docs) {
    distributorMap[doc.id] = doc.data().name || "Unknown";
  }

  const statusMap = {};
  for (const doc of statusesSnap.docs) {
    statusMap[doc.id] = doc.data().name || doc.id;
  }

  const invoiceStatusMap = {};
  for (const doc of invoiceStatusesSnap.docs) {
    invoiceStatusMap[doc.id] = doc.data().label || doc.id;
  }

  const jobTypeMap = {};
  for (const doc of jobTypesSnap.docs) {
    jobTypeMap[doc.id] = doc.data().label || doc.id;
  }

  _lookupCache = { distributorMap, statusMap, invoiceStatusMap, jobTypeMap };
  _lookupCacheTimestamp = now;

  console.log(`[lookupCache] Refreshed: ${distributorsSnap.size} distributors, ${statusesSnap.size} statuses, ${invoiceStatusesSnap.size} invoiceStatuses, ${jobTypesSnap.size} jobTypes`);

  return _lookupCache;
}

// ============================================================
// DEBOUNCE MAP — prevents summary rebuild on every single write.
// Waits 30 seconds after the last write before rebuilding.
// ============================================================
const _pendingRebuilds = new Map(); // monthId → timeoutId
const DEBOUNCE_MS = 30 * 1000; // 30 seconds

function debouncedBuildSummary(monthId) {
  // Clear any pending rebuild for this month
  if (_pendingRebuilds.has(monthId)) {
    clearTimeout(_pendingRebuilds.get(monthId));
  }

  // Schedule a new rebuild
  const timeoutId = setTimeout(async () => {
    _pendingRebuilds.delete(monthId);
    try {
      console.log(`[debounce] Rebuilding summary for ${monthId} after debounce`);
      await buildMonthlySummary(monthId);
    } catch (e) {
      console.error(`[debounce] Failed to rebuild summary for ${monthId}:`, e.message);
    }
  }, DEBOUNCE_MS);

  _pendingRebuilds.set(monthId, timeoutId);
  console.log(`[debounce] Scheduled rebuild for ${monthId} in ${DEBOUNCE_MS / 1000}s`);
}

// ============================================================
// 1. GENERATE MONTHLY SUMMARY
//    Creates a single document per month with all jobs flattened
//    as an array of descriptive strings for Gemini context.
//    Triggered when any daily schedule/jobList doc changes.
// ============================================================

/**
 * Builds a summary document for a given month across schedule, jobList,
 * and collectionSchedule collections.
 */
async function buildMonthlySummary(monthId) {
  const summary = {
    monthId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    scheduleJobs: [],
    jobListJobs: [],
    collectionJobs: [],
  };

  // Use cached lookup maps (avoids 4 collection reads per call)
  const { distributorMap, statusMap, invoiceStatusMap, jobTypeMap } = await getLookupMaps();

  // Helper to resolve any ID via the appropriate map, falling back to the raw value
  const resolve = (map, id, fallback) => map[id] || fallback || id || "unknown";

  // Vehicle / trailer enum display names
  const vehicleNames = { hyundai: "Hyundai", mahindra: "Mahindra", nissan: "Nissan" };
  const trailerNames = { bigTrailer: "Big Trailer", smallTrailer: "Small Trailer", noTrailer: "No Trailer" };

  // 1. Read all schedule daily docs for this month
  const scheduleDays = await db
    .collection("schedules")
    .doc(monthId)
    .collection("days")
    .get();

  for (const dayDoc of scheduleDays.docs) {
    const data = dayDoc.data();
    const jobs = data.jobs || [];
    for (const job of jobs) {
      const clients = (job.clients || [job.client || ""]).join(", ");
      const areas = (job.workingAreas || [job.workingArea || ""]).join(", ");
      const date = job.date
        ? new Date(job.date._seconds * 1000).toISOString().split("T")[0]
        : dayDoc.id;
      const distributor = resolve(distributorMap, job.distributorId, "Unassigned");
      const status = resolve(statusMap, job.statusId || job.status, "Scheduled");
      summary.scheduleJobs.push(
        `Date:${date} | Client:${clients} | Area:${areas} | Distributor:${distributor} | Status:${status}`
      );
    }
  }

  // 2. Read all jobList items for this month (stored as individual docs in 'items' subcollection)
  const jobListItems = await db
    .collection("jobLists")
    .doc(monthId)
    .collection("items")
    .get();

  for (const itemDoc of jobListItems.docs) {
    const job = itemDoc.data();
    const date = job.date
      ? new Date(job.date._seconds * 1000).toISOString().split("T")[0]
      : "unknown";
    const jobStatus = resolve(statusMap, job.jobStatusId, "Standby");
    const invoiceStatus = resolve(invoiceStatusMap, job.invoiceStatusId, "Pending");
    const jobType = resolve(jobTypeMap, job.jobType, job.jobType);
    summary.jobListJobs.push(
      `Date:${date} | Invoice:${job.invoice || ""} | Client:${job.client || ""} | Amount:R${job.amount || 0} | Area:${job.area || ""} | Qty:${job.quantity || 0} | ManDays:${job.manDays || 0} | JobType:${jobType} | JobStatus:${jobStatus} | InvoiceStatus:${invoiceStatus} | QtyDistributed:${job.quantityDistributed || 0} | SpecialInstructions:${job.specialInstructions || ""} | CollectionAddress:${job.collectionAddress || ""} | ReportAddresses:${job.reportAddresses || ""} | WhoToInvoice:${job.whoToInvoice || ""} | InvoiceDetails:${job.invoiceDetails || ""}`
    );
  }

  // 3. Read all collection schedule daily docs for this month
  const collectionDays = await db
    .collection("collectionSchedules")
    .doc(monthId)
    .collection("days")
    .get();

  for (const dayDoc of collectionDays.docs) {
    const data = dayDoc.data();
    const jobs = data.collectionJobs || [];
    for (const job of jobs) {
      const date = job.date
        ? new Date(job.date._seconds * 1000).toISOString().split("T")[0]
        : dayDoc.id;
      const vehicle = vehicleNames[job.vehicleType] || job.vehicleType || "";
      const trailer = trailerNames[job.trailerType] || job.trailerType || "";
      const status = resolve(statusMap, job.statusId || job.status, "");
      const clients = (job.clients || []).join(", ");
      summary.collectionJobs.push(
        `Date:${date} | Client:${clients} | Location:${job.location || ""} | Vehicle:${vehicle} | Trailer:${trailer} | JobType:${job.jobType || ""} | Staff:${(job.assignedStaff || []).join(", ")} | Status:${status} | TimeSlot:${job.timeSlot || ""}`
      );
    }
  }

  // Write the summary document
  await db.collection("monthSummaries").doc(monthId).set(summary);

  console.log(
    `Monthly summary updated for ${monthId}: ${summary.scheduleJobs.length} schedule jobs, ${summary.jobListJobs.length} jobList jobs, ${summary.collectionJobs.length} collection jobs`
  );

  return summary;
}

// Trigger on schedule changes (debounced — waits for batch edits to settle)
exports.onScheduleChange = onDocumentWritten(
  "schedules/{monthId}/days/{dayId}",
  async (event) => {
    const monthId = event.params.monthId;
    debouncedBuildSummary(monthId);
  }
);

// Trigger on jobList changes (debounced)
exports.onJobListChange = onDocumentWritten(
  "jobLists/{monthId}/items/{itemId}",
  async (event) => {
    const monthId = event.params.monthId;
    debouncedBuildSummary(monthId);
  }
);

// Trigger on collection schedule changes (debounced)
exports.onCollectionScheduleChange = onDocumentWritten(
  "collectionSchedules/{monthId}/days/{dayId}",
  async (event) => {
    const monthId = event.params.monthId;
    debouncedBuildSummary(monthId);
  }
);

// Manual trigger to rebuild a month's summary (callable from app or admin)
exports.rebuildMonthlySummary = onCall(
  {},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const monthId = request.data.monthId;
    if (!monthId) {
      throw new HttpsError("invalid-argument", "monthId is required.");
    }
    await buildMonthlySummary(monthId);
    return { success: true, monthId };
  }
);

// ============================================================
// 2. SCHEDULED: Rebuild active month summaries daily (only if stale)
//    Skips months whose summary is already newer than the data.
// ============================================================
exports.dailySummaryRefresh = onSchedule(
  { schedule: "every day 02:00", timeZone: "Africa/Johannesburg" },
  async () => {
    const now = new Date();
    const months = [];

    // Current month
    months.push(formatMonthId(now));

    // Previous month
    const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    months.push(formatMonthId(prev));

    // Next month
    const next = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    months.push(formatMonthId(next));

    for (const monthId of months) {
      try {
        // Check if the summary already exists and is recent (built in last 22 hours)
        const summaryDoc = await db.collection("monthSummaries").doc(monthId).get();
        if (summaryDoc.exists) {
          const data = summaryDoc.data();
          const updatedAt = data.updatedAt?.toDate?.();
          if (updatedAt) {
            const ageMs = now.getTime() - updatedAt.getTime();
            const ageHours = ageMs / (1000 * 60 * 60);
            if (ageHours < 22) {
              console.log(`[dailyRefresh] Skipping ${monthId} — summary is ${ageHours.toFixed(1)}h old (fresh enough)`);
              continue;
            }
          }
        }
        console.log(`[dailyRefresh] Rebuilding summary for ${monthId}`);
        await buildMonthlySummary(monthId);
      } catch (e) {
        console.error(`Failed to rebuild summary for ${monthId}:`, e);
      }
    }
  }
);

function formatMonthId(date) {
  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  return `${monthNames[date.getMonth()]} ${date.getFullYear()}`;
}

// ── In-memory caches (persist across warm invocations) ──
const summaryCache = new Map(); // key: monthId, value: { data, timestamp }
const SUMMARY_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

let knowledgeCache = null; // { entries, timestamp }
const KNOWLEDGE_CACHE_TTL = 10 * 60 * 1000; // 10 minutes

/**
 * Get monthly summary with in-memory caching.
 * Avoids redundant Firestore reads on warm Cloud Function instances.
 */
async function getCachedSummary(monthId) {
  const cached = summaryCache.get(monthId);
  if (cached && Date.now() - cached.timestamp < SUMMARY_CACHE_TTL) {
    return cached.data;
  }
  const doc = await db.collection("monthSummaries").doc(monthId).get();
  const data = doc.exists ? doc.data() : null;
  summaryCache.set(monthId, { data, timestamp: Date.now() });
  return data;
}

/**
 * Load system knowledge entries from Firestore with caching.
 */
async function getCachedKnowledge() {
  if (knowledgeCache && Date.now() - knowledgeCache.timestamp < KNOWLEDGE_CACHE_TTL) {
    return knowledgeCache.entries;
  }
  try {
    const doc = await db.collection("aiConfig").doc("knowledge").get();
    const entries = doc.exists ? (doc.data().entries || []) : [];
    knowledgeCache = { entries, timestamp: Date.now() };
    return entries;
  } catch (e) {
    console.error("Error loading knowledge:", e);
    return [];
  }
}

/**
 * Build a context string from a monthly summary document for Gemini.
 */
function buildContextFromSummary(monthId, data) {
  let ctx = `\n\n=== ${monthId} ===\n`;

  if (data.scheduleJobs && data.scheduleJobs.length > 0) {
    ctx += `\n--- SCHEDULE JOBS (${data.scheduleJobs.length}) ---\nThese are distributor assignments from the Schedule tab:\n`;
    ctx += data.scheduleJobs.join("\n") + "\n";
  } else {
    ctx += `\n--- SCHEDULE JOBS: None for ${monthId} ---\n`;
  }

  if (data.jobListJobs && data.jobListJobs.length > 0) {
    ctx += `\n--- JOB LIST ITEMS (${data.jobListJobs.length}) ---\nThese are invoice/business entries from the Job List tab:\n`;
    ctx += data.jobListJobs.join("\n") + "\n";
  } else {
    ctx += `\n--- JOB LIST ITEMS: None for ${monthId} ---\n`;
  }

  if (data.collectionJobs && data.collectionJobs.length > 0) {
    ctx += `\n--- COLLECTION SCHEDULE (${data.collectionJobs.length}) ---\nThese are vehicle logistics from the Collection Schedule tab:\n`;
    ctx += data.collectionJobs.join("\n") + "\n";
  } else {
    ctx += `\n--- COLLECTION SCHEDULE: None for ${monthId} ---\n`;
  }

  return ctx;
}

// ============================================================
// 3. AI CHAT - Callable function for the chatbot
//    Reads monthly summary + conversation history,
//    sends to Gemini, returns the response.
//    Supports function calling for adding jobs to the Job List.
// ============================================================

// Tool definitions for Gemini function calling
const chatTools = [
  {
    functionDeclarations: [
      {
        name: "addJobToJobList",
        description:
          "Add a new job to the Job List. Use this ONLY when the user explicitly asks to add, create, or make a new job on the joblist. Ask the user for any missing required fields before calling this. TIME-SENSITIVE JOB TYPES (junkCollection, furnitureMove, trailerTowing, windowCleaning, solarPanelCleaning) REQUIRE a time slot — always ask the user for the time if not provided. Valid time slots: 07:30, then 08:00-20:00 in 30-minute intervals (e.g. 08:00, 08:30, 09:00...).",
        parameters: {
          type: "OBJECT",
          properties: {
            client: {
              type: "STRING",
              description: "Client name (required)",
            },
            date: {
              type: "STRING",
              description:
                "Job date in YYYY-MM-DD format (required). If the user says 'today', use the current date.",
            },
            time: {
              type: "STRING",
              description: "Time slot in HH:MM 24-hour format (e.g. '08:00', '14:30'). REQUIRED for time-sensitive job types: junkCollection, furnitureMove, trailerTowing, windowCleaning, solarPanelCleaning. Valid slots: 07:30, then 08:00-20:00 in 30-minute intervals. Omit for other job types.",
            },
            manDays: {
              type: "NUMBER",
              description: "Man-days required (required, must be greater than 0)",
            },
            jobTypeId: {
              type: "STRING",
              description: "Job type ID. TIME-SENSITIVE types (require time slot): junkCollection, furnitureMove, trailerTowing, windowCleaning, solarPanelCleaning. Other types: flyerDistribution, flyerPrintingAndDistribution, flyersPrintingOnly, flyersAndPosters, calendersDistribution, postering.",
              enum: [
                "flyersPrintingOnly",
                "junkCollection",
                "flyersAndPosters",
                "furnitureMove",
                "flyerDistribution",
                "flyerPrintingAndDistribution",
                "windowCleaning",
                "solarPanelCleaning",
                "calendersDistribution",
                "trailerTowing",
                "postering",
              ],
            },
            area: {
              type: "STRING",
              description: "Work area or location",
            },
            invoice: {
              type: "STRING",
              description: "Invoice number",
            },
            amount: {
              type: "NUMBER",
              description: "Amount in Rand (ZAR)",
            },
            quantity: {
              type: "NUMBER",
              description: "Quantity of items",
            },
            specialInstructions: {
              type: "STRING",
              description: "Special instructions or notes for the job",
            },
            collectionAddress: {
              type: "STRING",
              description: "Collection or delivery address. Especially important for junkCollection, furnitureMove, and trailerTowing jobs.",
            },
            whoToInvoice: {
              type: "STRING",
              description: "Who should be invoiced",
            },
          },
          required: ["client", "date", "manDays"],
        },
      },
      {
        name: "getMonthData",
        description:
          "Fetch schedule, job list, and collection data for a specific month. Use this when the user asks about a month that is NOT already in the context data (e.g., previous month, next month, or any other month). The data will be returned so you can answer the user's question.",
        parameters: {
          type: "OBJECT",
          properties: {
            monthId: {
              type: "STRING",
              description: "Month identifier in 'MMM YYYY' format, e.g. 'Jan 2026', 'Feb 2026', 'Mar 2026'. Use the 3-letter month abbreviation.",
            },
          },
          required: ["monthId"],
        },
      },
      {
        name: "getJobsByDate",
        description:
          "Fetch actual job records from the Job List for a specific date. Use this when the user wants to copy, duplicate, or replicate jobs from a previous date to a new date. Returns full job details (client, job type, man-days, area, amount, quantity, etc.) so you can use them to add new jobs.",
        parameters: {
          type: "OBJECT",
          properties: {
            date: {
              type: "STRING",
              description: "Date to fetch jobs from, in YYYY-MM-DD format.",
            },
          },
          required: ["date"],
        },
      },
      {
        name: "addMultipleJobsToJobList",
        description:
          "Add multiple jobs to the Job List in a single operation. Use this when the user asks to add several jobs at once, copy jobs from a previous date, or paste text containing multiple job requests. Each job in the array follows the same validation rules as addJobToJobList. All jobs are presented together for a single bulk confirmation.",
        parameters: {
          type: "OBJECT",
          properties: {
            jobs: {
              type: "ARRAY",
              description: "Array of jobs to add. Each job object has the same fields as addJobToJobList.",
              items: {
                type: "OBJECT",
                properties: {
                  client: {
                    type: "STRING",
                    description: "Client name (required)",
                  },
                  date: {
                    type: "STRING",
                    description: "Job date in YYYY-MM-DD format (required)",
                  },
                  time: {
                    type: "STRING",
                    description: "Time slot in HH:MM 24-hour format. Required for time-sensitive job types.",
                  },
                  manDays: {
                    type: "NUMBER",
                    description: "Man-days required (required, must be greater than 0)",
                  },
                  jobTypeId: {
                    type: "STRING",
                    description: "Job type ID",
                    enum: [
                      "flyersPrintingOnly",
                      "junkCollection",
                      "flyersAndPosters",
                      "furnitureMove",
                      "flyerDistribution",
                      "flyerPrintingAndDistribution",
                      "windowCleaning",
                      "solarPanelCleaning",
                      "calendersDistribution",
                      "trailerTowing",
                      "postering",
                    ],
                  },
                  area: { type: "STRING", description: "Work area or location" },
                  invoice: { type: "STRING", description: "Invoice number" },
                  amount: { type: "NUMBER", description: "Amount in Rand (ZAR)" },
                  quantity: { type: "NUMBER", description: "Quantity of items" },
                  specialInstructions: { type: "STRING", description: "Special instructions" },
                  collectionAddress: { type: "STRING", description: "Collection or delivery address" },
                  whoToInvoice: { type: "STRING", description: "Who should be invoiced" },
                },
                required: ["client", "date", "manDays"],
              },
            },
          },
          required: ["jobs"],
        },
      },
      {
        name: "updateJobOnJobList",
        description:
          "Update an existing job on the Job List. Use this when the user asks to change, update, edit, or modify a field on an existing job. You MUST identify the job by client name and date from the context data. Only include fields that need to change. For time-sensitive job types (junkCollection, furnitureMove, trailerTowing, windowCleaning, solarPanelCleaning), if changing the date, also ask about the time slot.",
        parameters: {
          type: "OBJECT",
          properties: {
            client: {
              type: "STRING",
              description: "Client name of the existing job to update (required to identify the job)",
            },
            date: {
              type: "STRING",
              description: "Current date of the job in YYYY-MM-DD format (required to identify the job)",
            },
            updates: {
              type: "OBJECT",
              description: "Only the fields to change. Omit any field that should stay the same. For time-sensitive jobs, include 'time' when changing the date or time slot.",
              properties: {
                client: { type: "STRING", description: "New client name" },
                date: { type: "STRING", description: "New date in YYYY-MM-DD format" },
                time: { type: "STRING", description: "New time slot in HH:MM 24-hour format (e.g. '08:00', '14:30'). For time-sensitive job types only. Valid slots: 07:30, then 08:00-20:00 in 30-minute intervals." },
                manDays: { type: "NUMBER", description: "New man-days value" },
                jobTypeId: {
                  type: "STRING",
                  description: "New job type ID",
                  enum: [
                    "flyersPrintingOnly",
                    "junkCollection",
                    "flyersAndPosters",
                    "furnitureMove",
                    "flyerDistribution",
                    "flyerPrintingAndDistribution",
                    "windowCleaning",
                    "solarPanelCleaning",
                    "calendersDistribution",
                    "trailerTowing",
                    "postering",
                  ],
                },
                area: { type: "STRING", description: "New work area" },
                invoice: { type: "STRING", description: "New invoice number" },
                amount: { type: "NUMBER", description: "New amount in Rand" },
                quantity: { type: "NUMBER", description: "New quantity" },
                specialInstructions: { type: "STRING", description: "New special instructions" },
                collectionAddress: { type: "STRING", description: "New collection address" },
                whoToInvoice: { type: "STRING", description: "New who to invoice" },
                jobStatusId: {
                  type: "STRING",
                  description: "New job status ID (use the ID from context, e.g. 'standby', 'scheduled', 'done', 'urgent', or custom status IDs)",
                },
                invoiceStatusId: {
                  type: "STRING",
                  description: "New invoice status ID (e.g. 'pending', 'paid', or custom invoice status IDs)",
                },
                quantityDistributed: { type: "NUMBER", description: "New quantity distributed" },
                invoiceDetails: { type: "STRING", description: "New invoice details" },
                reportAddresses: { type: "STRING", description: "New report addresses" },
              },
            },
          },
          required: ["client", "date", "updates"],
        },
      },
      {
        name: "getScheduleJobsByDate",
        description:
          "Fetch SCHEDULE GRID jobs (distributor assignments) for a specific date. These are different from Job List items — schedule jobs show WHO (distributor) is doing WHAT (client/area) on a specific date. Use this when the user wants to copy schedule assignments from a previous date or see who was assigned where.",
        parameters: {
          type: "OBJECT",
          properties: {
            date: {
              type: "STRING",
              description: "Date to fetch schedule jobs from, in YYYY-MM-DD format.",
            },
          },
          required: ["date"],
        },
      },
      {
        name: "getAvailableDistributors",
        description:
          "Get a list of active distributors that do NOT have any schedule grid assignments on a specific date. Use this when the user asks who is available, unallocated, or free on a date. Also returns all distributors with their assignment status for context.",
        parameters: {
          type: "OBJECT",
          properties: {
            date: {
              type: "STRING",
              description: "Date to check availability for, in YYYY-MM-DD format.",
            },
          },
          required: ["date"],
        },
      },
      {
        name: "addJobsToSchedule",
        description:
          "Add one or more jobs to the SCHEDULE GRID (distributor assignments). This is for assigning distributors to clients/areas on specific dates — NOT for the Job List. Each job requires a distributor name (or ID), client names, and a date. Use this when copying schedule assignments from a previous date, allocating distributors, or creating new schedule entries.",
        parameters: {
          type: "OBJECT",
          properties: {
            jobs: {
              type: "ARRAY",
              description: "Array of schedule jobs to add.",
              items: {
                type: "OBJECT",
                properties: {
                  distributorName: {
                    type: "STRING",
                    description: "Name of the distributor to assign (will be matched to distributor ID). Can also be the distributor ID directly.",
                  },
                  clients: {
                    type: "ARRAY",
                    description: "List of client names for this assignment.",
                    items: { type: "STRING" },
                  },
                  workingAreas: {
                    type: "ARRAY",
                    description: "List of working area names for this assignment.",
                    items: { type: "STRING" },
                  },
                  date: {
                    type: "STRING",
                    description: "Date for this schedule assignment in YYYY-MM-DD format.",
                  },
                  workMaps: {
                    type: "ARRAY",
                    description: "Array of work map polygon objects to include with this assignment. Each polygon has name, description, points (array of {latitude, longitude}), color (int), fillOpacity (number), strokeWidth (int). Pass these through exactly as received from getScheduleJobsByDate when copying jobs.",
                    items: { type: "OBJECT" },
                  },
                  statusId: {
                    type: "STRING",
                    description: "Status ID for the job. Default is 'scheduled'. Options: 'scheduled', 'done', 'urgent', 'standby', or custom status IDs.",
                  },
                },
                required: ["distributorName", "clients", "date"],
              },
            },
          },
          required: ["jobs"],
        },
      },
      {
        name: "copyScheduleJobs",
        description:
          "Copy schedule grid jobs (distributor assignments) from a source date to a target date. This preserves ALL data including work area polygons/maps. Use this instead of manually fetching and re-adding when the user wants to copy/replicate/duplicate schedule assignments from one date to another. Optionally reassign specific distributors or only copy certain distributors' jobs.",
        parameters: {
          type: "OBJECT",
          properties: {
            sourceDate: {
              type: "STRING",
              description: "The date to copy jobs FROM, in YYYY-MM-DD format.",
            },
            targetDate: {
              type: "STRING",
              description: "The date to copy jobs TO, in YYYY-MM-DD format.",
            },
            distributorNames: {
              type: "ARRAY",
              description: "Optional: Only copy jobs for these specific distributors (by name). If omitted, copies ALL jobs from the source date.",
              items: { type: "STRING" },
            },
            reassignments: {
              type: "ARRAY",
              description: "Optional: Reassign distributors during copy. Each entry maps a source distributor to a different target distributor. If omitted, jobs keep their original distributors.",
              items: {
                type: "OBJECT",
                properties: {
                  fromDistributor: {
                    type: "STRING",
                    description: "Name of the distributor in the source jobs.",
                  },
                  toDistributor: {
                    type: "STRING",
                    description: "Name of the distributor to assign in the target.",
                  },
                },
                required: ["fromDistributor", "toDistributor"],
              },
            },
            statusId: {
              type: "STRING",
              description: "Optional: Override status for all copied jobs. Default keeps 'scheduled'.",
            },
          },
          required: ["sourceDate", "targetDate"],
        },
      },
    ],
  },
];

/**
 * Execute the addJobToJobList function call from Gemini.
 * Validates and returns job data for user confirmation — does NOT write to Firestore.
 */
async function executeAddJobToJobList(args, userName, userId) {
  // Parse and validate the date
  const dateParts = args.date.split("-");
  if (dateParts.length !== 3) {
    return { success: false, error: "Invalid date format. Expected YYYY-MM-DD." };
  }
  const jobDate = new Date(
    parseInt(dateParts[0]),
    parseInt(dateParts[1]) - 1,
    parseInt(dateParts[2])
  );
  if (isNaN(jobDate.getTime())) {
    return { success: false, error: "Invalid date." };
  }

  const manDays = args.manDays;
  if (!manDays || manDays <= 0) {
    return { success: false, error: "manDays must be greater than 0." };
  }

  const client = (args.client || "").trim();
  if (!client) {
    return { success: false, error: "Client name is required." };
  }

  // Check if this is a time-sensitive job type
  const timeSensitiveTypes = ["junkCollection", "furnitureMove", "trailerTowing", "windowCleaning", "solarPanelCleaning"];
  const jobTypeId = args.jobTypeId || "flyersPrintingOnly";
  const isTimeSensitive = timeSensitiveTypes.includes(jobTypeId);

  // Validate time for time-sensitive job types
  let timeStr = null;
  if (isTimeSensitive) {
    if (!args.time) {
      return {
        success: false,
        error: `This job type requires a time slot. Please provide a time (e.g. "08:00", "14:30"). Valid slots: 07:30, then 08:00-20:00 in 30-minute intervals.`,
      };
    }
    // Validate time format HH:MM
    const timeMatch = (args.time || "").match(/^(\d{1,2}):(\d{2})$/);
    if (!timeMatch) {
      return { success: false, error: "Invalid time format. Expected HH:MM (e.g. '08:00', '14:30')." };
    }
    const hour = parseInt(timeMatch[1]);
    const minute = parseInt(timeMatch[2]);
    // Validate time is a valid slot (07:30, or 08:00-20:00 in 30-min intervals)
    const isValid0730 = hour === 7 && minute === 30;
    const isValidSlot = hour >= 8 && hour <= 20 && (minute === 0 || minute === 30) && !(hour === 20 && minute === 30);
    if (!isValid0730 && !isValidSlot) {
      return { success: false, error: "Invalid time slot. Valid slots: 07:30, then 08:00-20:00 in 30-minute intervals." };
    }
    jobDate.setHours(hour, minute, 0, 0);
    timeStr = `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`;
  }

  // Calculate the monthId (e.g. "Mar 2026")
  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;

  // Use cached lookup maps (avoids collection read per call)
  const { jobTypeMap } = await getLookupMaps();

  const jobTypeName = jobTypeMap[jobTypeId] || jobTypeId;
  const dateStr = `${jobDate.getDate()} ${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;
  const dateTimeDisplay = timeStr ? `${dateStr} at ${timeStr}` : dateStr;

  // Return validated data for confirmation — NO Firestore write here
  return {
    success: true,
    needsConfirmation: true,
    monthId: monthId,
    summary: `Ready to add: **${client}** — ${jobTypeName}, ${manDays} man-days on ${dateTimeDisplay}${args.area ? `, area: ${args.area}` : ""}${args.amount ? `, R${args.amount}` : ""}`,
    jobData: {
      client: client,
      date: args.date,
      time: timeStr,
      manDays: manDays,
      jobTypeId: jobTypeId,
      jobTypeName: jobTypeName,
      isTimeSensitive: isTimeSensitive,
      area: args.area || "",
      invoice: args.invoice || "",
      amount: args.amount || 0,
      quantity: args.quantity || 0,
      specialInstructions: args.specialInstructions || "",
      collectionAddress: args.collectionAddress || "",
      whoToInvoice: args.whoToInvoice || "",
      monthId: monthId,
      dateDisplay: dateTimeDisplay,
    },
  };
}

/**
 * Execute the updateJobOnJobList function call from Gemini.
 * Finds the matching job by client+date, validates changes, returns preview for confirmation.
 */
async function executeUpdateJobOnJobList(args, userName, userId) {
  const client = (args.client || "").trim();
  if (!client) {
    return { success: false, error: "Client name is required to identify the job." };
  }

  const date = (args.date || "").trim();
  if (!date) {
    return { success: false, error: "Date is required to identify the job (YYYY-MM-DD)." };
  }

  const updates = args.updates;
  if (!updates || Object.keys(updates).length === 0) {
    return { success: false, error: "No updates specified. Tell me what fields to change." };
  }

  // Parse the identifying date
  const dateParts = date.split("-");
  if (dateParts.length !== 3) {
    return { success: false, error: "Invalid date format. Expected YYYY-MM-DD." };
  }
  const jobDate = new Date(
    parseInt(dateParts[0]),
    parseInt(dateParts[1]) - 1,
    parseInt(dateParts[2])
  );
  if (isNaN(jobDate.getTime())) {
    return { success: false, error: "Invalid date." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;

  // Query Firestore for matching jobs by client name on that date
  const itemsRef = db.collection("jobLists").doc(monthId).collection("items");

  // Build date range for the target day (start of day to end of day)
  const dayStart = new Date(jobDate.getFullYear(), jobDate.getMonth(), jobDate.getDate());
  const dayEnd = new Date(jobDate.getFullYear(), jobDate.getMonth(), jobDate.getDate() + 1);

  const snapshot = await itemsRef
    .where("date", ">=", admin.firestore.Timestamp.fromDate(dayStart))
    .where("date", "<", admin.firestore.Timestamp.fromDate(dayEnd))
    .get();

  if (snapshot.empty) {
    return { success: false, error: `No jobs found on ${date}. Check the date and try again.` };
  }

  // Filter by client name (case-insensitive partial match)
  const clientLower = client.toLowerCase();
  const matches = [];
  snapshot.forEach((doc) => {
    const data = doc.data();
    const docClient = (data.client || "").toLowerCase();
    if (docClient.includes(clientLower) || clientLower.includes(docClient)) {
      matches.push({ id: doc.id, data });
    }
  });

  if (matches.length === 0) {
    // List available clients on that date to help user
    const available = [];
    snapshot.forEach((doc) => {
      const data = doc.data();
      if (data.client) available.push(data.client);
    });
    return {
      success: false,
      error: `No job found for client "${client}" on ${date}. Jobs on that date are for: ${available.join(", ") || "none found"}.`,
    };
  }

  if (matches.length > 1) {
    const clientNames = matches.map((m) => m.data.client);
    return {
      success: false,
      error: `Multiple jobs found matching "${client}" on ${date}: ${clientNames.join(", ")}. Please be more specific.`,
    };
  }

  // Exactly one match
  const match = matches[0];
  const currentData = match.data;

  // Use cached lookup maps (avoids 3 collection reads per call)
  const lookups = await getLookupMaps();
  const jobTypeMap = lookups.jobTypeMap;

  const jobStatusMap = { ...lookups.statusMap };
  // Add defaults
  jobStatusMap["standby"] = jobStatusMap["standby"] || "Standby";
  jobStatusMap["scheduled"] = jobStatusMap["scheduled"] || "Scheduled";
  jobStatusMap["done"] = jobStatusMap["done"] || "Done";
  jobStatusMap["urgent"] = jobStatusMap["urgent"] || "Urgent";

  const invoiceStatusMap = { ...lookups.invoiceStatusMap };
  invoiceStatusMap["pending"] = invoiceStatusMap["pending"] || "Pending";

  // Map update field names to Firestore field names and build changes preview
  const fieldMapping = {
    client: "client",
    date: "date",
    manDays: "manDays",
    jobTypeId: "jobType",       // Dart jobTypeId → Firestore field "jobType"
    area: "area",
    invoice: "invoice",
    amount: "amount",
    quantity: "quantity",
    specialInstructions: "specialInstructions",
    collectionAddress: "collectionAddress",
    whoToInvoice: "whoToInvoice",
    jobStatusId: "jobStatusId",
    invoiceStatusId: "invoiceStatusId",
    quantityDistributed: "quantityDistributed",
    invoiceDetails: "invoiceDetails",
    reportAddresses: "reportAddresses",
  };

  // Human-readable field labels
  const fieldLabels = {
    client: "Client",
    date: "Date",
    manDays: "Man-Days",
    jobTypeId: "Job Type",
    area: "Area",
    invoice: "Invoice",
    amount: "Amount",
    quantity: "Quantity",
    specialInstructions: "Special Instructions",
    collectionAddress: "Collection Address",
    whoToInvoice: "Who to Invoice",
    jobStatusId: "Job Status",
    invoiceStatusId: "Invoice Status",
    quantityDistributed: "Qty Distributed",
    invoiceDetails: "Invoice Details",
    reportAddresses: "Report Addresses",
  };

  // Determine if current job is time-sensitive
  const timeSensitiveTypes = ["junkCollection", "furnitureMove", "trailerTowing", "windowCleaning", "solarPanelCleaning"];
  const currentJobType = currentData.jobType || currentData.jobTypeId || "";
  const isTimeSensitive = timeSensitiveTypes.includes(currentJobType) || timeSensitiveTypes.includes(updates.jobTypeId || "");

  const changes = {};
  let summaryParts = [];

  // Helper to format date/time for display
  const formatDateDisplay = (d, includeTime) => {
    const dateStr = `${d.getDate()} ${monthNames[d.getMonth()]} ${d.getFullYear()}`;
    if (includeTime && (d.getHours() !== 0 || d.getMinutes() !== 0)) {
      const h = d.getHours().toString().padStart(2, '0');
      const m = d.getMinutes().toString().padStart(2, '0');
      return `${dateStr} at ${h}:${m}`;
    }
    return dateStr;
  };

  for (const [updateKey, newValue] of Object.entries(updates)) {
    // Handle time updates specially — they modify the date field
    if (updateKey === "time") continue;

    const firestoreField = fieldMapping[updateKey];
    if (!firestoreField) continue;

    let oldValue = currentData[firestoreField];
    let oldDisplay, newDisplay;

    // Handle special field types
    if (updateKey === "date") {
      // Parse new date
      const newDateParts = newValue.split("-");
      if (newDateParts.length !== 3) continue;
      const nd = new Date(parseInt(newDateParts[0]), parseInt(newDateParts[1]) - 1, parseInt(newDateParts[2]));
      if (isNaN(nd.getTime())) continue;

      // Apply time from updates.time if provided, or preserve existing time for time-sensitive jobs
      if (updates.time) {
        const timeMatch = updates.time.match(/^(\d{1,2}):(\d{2})$/);
        if (timeMatch) {
          nd.setHours(parseInt(timeMatch[1]), parseInt(timeMatch[2]), 0, 0);
        }
      } else if (isTimeSensitive && oldValue && oldValue.toDate) {
        // Preserve existing time when only date changes for time-sensitive jobs
        const od = oldValue.toDate();
        if (od.getHours() !== 0 || od.getMinutes() !== 0) {
          nd.setHours(od.getHours(), od.getMinutes(), 0, 0);
        }
      }
      
      // Format old date (include time for time-sensitive jobs)
      if (oldValue && oldValue.toDate) {
        const od = oldValue.toDate();
        oldDisplay = formatDateDisplay(od, isTimeSensitive);
      } else {
        oldDisplay = String(oldValue || "—");
      }
      newDisplay = formatDateDisplay(nd, isTimeSensitive);

      // Store the full date-time string for confirmUpdateJob to parse
      changes[updateKey] = {
        firestoreField,
        oldValue: oldValue,
        newValue: nd.toISOString(),
        oldDisplay,
        newDisplay,
        label: fieldLabels[updateKey] || updateKey,
      };
      summaryParts.push(`${fieldLabels[updateKey] || updateKey}: ${oldDisplay} → ${newDisplay}`);
      continue;
    } else if (updateKey === "jobTypeId") {
      oldDisplay = jobTypeMap[oldValue] || oldValue || "—";
      newDisplay = jobTypeMap[newValue] || newValue;
    } else if (updateKey === "jobStatusId") {
      oldDisplay = jobStatusMap[oldValue] || oldValue || "—";
      newDisplay = jobStatusMap[newValue] || newValue;
    } else if (updateKey === "invoiceStatusId") {
      oldDisplay = invoiceStatusMap[oldValue] || oldValue || "—";
      newDisplay = invoiceStatusMap[newValue] || newValue;
    } else if (updateKey === "amount") {
      oldDisplay = `R${oldValue || 0}`;
      newDisplay = `R${newValue}`;
    } else {
      oldDisplay = String(oldValue ?? "—");
      newDisplay = String(newValue);
    }

    changes[updateKey] = {
      firestoreField,
      oldValue: oldValue,
      newValue: newValue,
      oldDisplay,
      newDisplay,
      label: fieldLabels[updateKey] || updateKey,
    };

    summaryParts.push(`${fieldLabels[updateKey] || updateKey}: ${oldDisplay} → ${newDisplay}`);
  }

  // Handle time-only updates (when user changes just the time, not the date)
  if (updates.time && !updates.date && isTimeSensitive) {
    const timeMatch = updates.time.match(/^(\d{1,2}):(\d{2})$/);
    if (timeMatch) {
      const oldDateValue = currentData.date;
      if (oldDateValue && oldDateValue.toDate) {
        const od = oldDateValue.toDate();
        const nd = new Date(od.getTime());
        nd.setHours(parseInt(timeMatch[1]), parseInt(timeMatch[2]), 0, 0);

        const oldDisplay = formatDateDisplay(od, true);
        const newDisplay = formatDateDisplay(nd, true);

        changes["date"] = {
          firestoreField: "date",
          oldValue: oldDateValue,
          newValue: nd.toISOString(),
          oldDisplay,
          newDisplay,
          label: "Date & Time",
        };
        summaryParts.push(`Time: ${oldDisplay} → ${newDisplay}`);
      }
    }
  }

  if (Object.keys(changes).length === 0) {
    return { success: false, error: "No valid update fields found." };
  }

  const dateStr = `${jobDate.getDate()} ${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;

  return {
    success: true,
    needsConfirmation: true,
    summary: `Update **${currentData.client}** (${dateStr}):\n${summaryParts.join("\n")}`,
    updateData: {
      jobId: match.id,
      monthId: monthId,
      client: currentData.client,
      date: date,
      dateDisplay: dateStr,
      changes: changes,
    },
  };
}

/**
 * Execute the getJobsByDate function call from Gemini.
 * Fetches all job records from the Job List for a specific date.
 */
async function executeGetJobsByDate(args) {
  const date = (args.date || "").trim();
  if (!date) {
    return { success: false, error: "Date is required (YYYY-MM-DD)." };
  }

  const dateParts = date.split("-");
  if (dateParts.length !== 3) {
    return { success: false, error: "Invalid date format. Expected YYYY-MM-DD." };
  }
  const jobDate = new Date(
    parseInt(dateParts[0]),
    parseInt(dateParts[1]) - 1,
    parseInt(dateParts[2])
  );
  if (isNaN(jobDate.getTime())) {
    return { success: false, error: "Invalid date." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;

  const itemsRef = db.collection("jobLists").doc(monthId).collection("items");
  const dayStart = new Date(jobDate.getFullYear(), jobDate.getMonth(), jobDate.getDate());
  const dayEnd = new Date(jobDate.getFullYear(), jobDate.getMonth(), jobDate.getDate() + 1);

  const snapshot = await itemsRef
    .where("date", ">=", admin.firestore.Timestamp.fromDate(dayStart))
    .where("date", "<", admin.firestore.Timestamp.fromDate(dayEnd))
    .get();

  if (snapshot.empty) {
    return { success: false, error: `No jobs found on ${date}.` };
  }

  const { jobTypeMap } = await getLookupMaps();

  const jobs = [];
  snapshot.forEach((doc) => {
    const data = doc.data();
    const jobType = data.jobType || "flyersPrintingOnly";
    const jobTypeName = jobTypeMap[jobType] || jobType;
    // Extract time if present
    let time = null;
    if (data.date && data.date.toDate) {
      const d = data.date.toDate();
      if (d.getHours() !== 0 || d.getMinutes() !== 0) {
        time = `${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
      }
    }
    jobs.push({
      client: data.client || "",
      jobTypeId: jobType,
      jobTypeName: jobTypeName,
      manDays: data.manDays || 0,
      area: data.area || "",
      amount: data.amount || 0,
      quantity: data.quantity || 0,
      invoice: data.invoice || "",
      specialInstructions: data.specialInstructions || "",
      collectionAddress: data.collectionAddress || "",
      whoToInvoice: data.whoToInvoice || "",
      time: time,
      jobStatusId: data.jobStatusId || "standby",
      invoiceStatusId: data.invoiceStatusId || "pending",
    });
  });

  console.log(`[getJobsByDate] Found ${jobs.length} jobs on ${date} in ${monthId}`);

  return {
    success: true,
    date: date,
    monthId: monthId,
    jobCount: jobs.length,
    jobs: jobs,
  };
}

/**
 * Execute the addMultipleJobsToJobList function call from Gemini.
 * Validates all jobs and returns them for bulk confirmation — does NOT write to Firestore.
 */
async function executeAddMultipleJobsToJobList(args, userName, userId) {
  const jobs = args.jobs;
  if (!jobs || !Array.isArray(jobs) || jobs.length === 0) {
    return { success: false, error: "At least one job is required." };
  }

  if (jobs.length > 20) {
    return { success: false, error: "Maximum 20 jobs can be added at once." };
  }

  const validatedJobs = [];
  const errors = [];

  for (let i = 0; i < jobs.length; i++) {
    const job = jobs[i];
    const result = await executeAddJobToJobList(job, userName, userId);
    if (result.success && result.needsConfirmation) {
      validatedJobs.push(result.jobData);
    } else {
      errors.push(`Job ${i + 1} (${job.client || "unknown"}): ${result.error}`);
    }
  }

  if (validatedJobs.length === 0) {
    return { success: false, error: `All jobs failed validation:\n${errors.join("\n")}` };
  }

  const summaryLines = validatedJobs.map((j, i) =>
    `${i + 1}. **${j.client}** — ${j.jobTypeName}, ${j.manDays} man-days on ${j.dateDisplay}${j.area ? `, ${j.area}` : ""}${j.amount ? `, R${j.amount}` : ""}`
  );

  let summary = `Ready to add **${validatedJobs.length} job(s)**:\n${summaryLines.join("\n")}`;
  if (errors.length > 0) {
    summary += `\n\n⚠️ ${errors.length} job(s) had issues:\n${errors.join("\n")}`;
  }

  return {
    success: true,
    needsConfirmation: true,
    summary: summary,
    jobsData: validatedJobs,
    errorCount: errors.length,
    errors: errors,
  };
}

/**
 * Execute the getScheduleJobsByDate function call from Gemini.
 * Fetches schedule grid jobs (distributor assignments) for a specific date.
 */
async function executeGetScheduleJobsByDate(args) {
  const date = (args.date || "").trim();
  if (!date) {
    return { success: false, error: "Date is required (YYYY-MM-DD)." };
  }

  const dateParts = date.split("-");
  if (dateParts.length !== 3) {
    return { success: false, error: "Invalid date format. Expected YYYY-MM-DD." };
  }
  const jobDate = new Date(
    parseInt(dateParts[0]),
    parseInt(dateParts[1]) - 1,
    parseInt(dateParts[2])
  );
  if (isNaN(jobDate.getTime())) {
    return { success: false, error: "Invalid date." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;
  const dailyId = `${dateParts[0]}-${dateParts[1]}-${dateParts[2]}`;

  const dayDoc = await db
    .collection("schedules")
    .doc(monthId)
    .collection("days")
    .doc(dailyId)
    .get();

  if (!dayDoc.exists) {
    return { success: false, error: `No schedule data found for ${date}.` };
  }

  const data = dayDoc.data();
  const jobs = data.jobs || [];

  if (jobs.length === 0) {
    return { success: false, error: `No schedule jobs found on ${date}.` };
  }

  const { distributorMap, statusMap } = await getLookupMaps();

  const scheduleJobs = jobs.map((job) => {
    const clients = job.clients || [job.client || ""];
    const areas = job.workingAreas || [job.workingArea || ""];
    const distributorName = distributorMap[job.distributorId] || "Unassigned";
    const statusName = statusMap[job.statusId || job.status] || "Scheduled";

    return {
      distributorId: job.distributorId || "",
      distributorName: distributorName,
      clients: clients,
      workingAreas: areas,
      workMaps: job.workMaps || [],
      statusId: job.statusId || job.status || "scheduled",
      statusName: statusName,
    };
  });

  console.log(`[getScheduleJobsByDate] Found ${scheduleJobs.length} schedule jobs on ${date} in ${monthId}`);

  return {
    success: true,
    date: date,
    monthId: monthId,
    jobCount: scheduleJobs.length,
    jobs: scheduleJobs,
  };
}

/**
 * Execute the getAvailableDistributors function call from Gemini.
 * Returns distributors that do NOT have schedule assignments on a specific date.
 */
async function executeGetAvailableDistributors(args) {
  const date = (args.date || "").trim();
  if (!date) {
    return { success: false, error: "Date is required (YYYY-MM-DD)." };
  }

  const dateParts = date.split("-");
  if (dateParts.length !== 3) {
    return { success: false, error: "Invalid date format. Expected YYYY-MM-DD." };
  }
  const jobDate = new Date(
    parseInt(dateParts[0]),
    parseInt(dateParts[1]) - 1,
    parseInt(dateParts[2])
  );
  if (isNaN(jobDate.getTime())) {
    return { success: false, error: "Invalid date." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;
  const dailyId = `${dateParts[0]}-${dateParts[1]}-${dateParts[2]}`;

  // Get all distributors
  const { distributorMap } = await getLookupMaps();

  // Get all active distributors with their IDs
  const distributorsSnap = await db.collection("distributors").get();
  const allDistributors = [];
  for (const doc of distributorsSnap.docs) {
    const data = doc.data();
    if (data.status === "active" || data.status === undefined) {
      allDistributors.push({ id: doc.id, name: data.name || "Unknown" });
    }
  }

  // Get assigned distributor IDs for this date
  const assignedIds = new Set();
  const dayDoc = await db
    .collection("schedules")
    .doc(monthId)
    .collection("days")
    .doc(dailyId)
    .get();

  if (dayDoc.exists) {
    const data = dayDoc.data();
    const jobs = data.jobs || [];
    for (const job of jobs) {
      if (job.distributorId) {
        assignedIds.add(job.distributorId);
      }
    }
  }

  const available = allDistributors.filter((d) => !assignedIds.has(d.id));
  const assigned = allDistributors.filter((d) => assignedIds.has(d.id));

  console.log(`[getAvailableDistributors] ${date}: ${available.length} available, ${assigned.length} assigned out of ${allDistributors.length} total`);

  return {
    success: true,
    date: date,
    totalDistributors: allDistributors.length,
    availableCount: available.length,
    assignedCount: assigned.length,
    available: available,
    assigned: assigned,
  };
}

/**
 * Execute the addJobsToSchedule function call from Gemini.
 * Validates schedule jobs and returns them for user confirmation — does NOT write to Firestore.
 */
async function executeAddJobsToSchedule(args, userName) {
  const jobs = args.jobs;
  if (!jobs || !Array.isArray(jobs) || jobs.length === 0) {
    return { success: false, error: "At least one schedule job is required." };
  }

  if (jobs.length > 30) {
    return { success: false, error: "Maximum 30 schedule jobs can be added at once." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];

  // Get all distributors for name matching
  const distributorsSnap = await db.collection("distributors").get();
  const distributorList = [];
  for (const doc of distributorsSnap.docs) {
    const data = doc.data();
    distributorList.push({ id: doc.id, name: (data.name || "").trim() });
  }

  const { statusMap } = await getLookupMaps();

  const validatedJobs = [];
  const errors = [];

  for (let i = 0; i < jobs.length; i++) {
    const job = jobs[i];

    // Validate date
    const dateParts = (job.date || "").split("-");
    if (dateParts.length !== 3) {
      errors.push(`Job ${i + 1}: Invalid date format.`);
      continue;
    }
    const jobDate = new Date(
      parseInt(dateParts[0]),
      parseInt(dateParts[1]) - 1,
      parseInt(dateParts[2])
    );
    if (isNaN(jobDate.getTime())) {
      errors.push(`Job ${i + 1}: Invalid date.`);
      continue;
    }

    // Validate clients
    const clients = job.clients || [];
    if (clients.length === 0) {
      errors.push(`Job ${i + 1}: At least one client is required.`);
      continue;
    }

    // Match distributor name to ID
    const distInput = (job.distributorName || "").trim();
    if (!distInput) {
      errors.push(`Job ${i + 1}: Distributor name is required.`);
      continue;
    }

    // Try exact match first, then case-insensitive partial match
    let matchedDistributor = distributorList.find(
      (d) => d.name.toLowerCase() === distInput.toLowerCase()
    );
    if (!matchedDistributor) {
      matchedDistributor = distributorList.find(
        (d) => d.name.toLowerCase().includes(distInput.toLowerCase()) ||
               distInput.toLowerCase().includes(d.name.toLowerCase())
      );
    }
    // Also try direct ID match
    if (!matchedDistributor) {
      matchedDistributor = distributorList.find((d) => d.id === distInput);
    }

    if (!matchedDistributor) {
      const availableNames = distributorList.map((d) => d.name).join(", ");
      errors.push(`Job ${i + 1}: No distributor found matching "${distInput}". Available: ${availableNames}`);
      continue;
    }

    const monthId = `${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;
    const dailyId = `${dateParts[0]}-${dateParts[1]}-${dateParts[2]}`;
    const dateStr = `${jobDate.getDate()} ${monthNames[jobDate.getMonth()]} ${jobDate.getFullYear()}`;
    const statusId = job.statusId || "scheduled";
    const statusName = statusMap[statusId] || statusId;

    validatedJobs.push({
      distributorId: matchedDistributor.id,
      distributorName: matchedDistributor.name,
      clients: clients,
      workingAreas: job.workingAreas || [],
      workMaps: job.workMaps || [],
      date: job.date,
      monthId: monthId,
      dailyId: dailyId,
      statusId: statusId,
      statusName: statusName,
      dateDisplay: dateStr,
    });
  }

  if (validatedJobs.length === 0) {
    return { success: false, error: `All jobs failed validation:\n${errors.join("\n")}` };
  }

  const summaryLines = validatedJobs.map((j, i) =>
    `${i + 1}. **${j.distributorName}** → ${j.clients.join(", ")}${j.workingAreas.length > 0 ? ` (${j.workingAreas.join(", ")})` : ""} on ${j.dateDisplay}`
  );

  let summary = `Ready to add **${validatedJobs.length}** schedule assignment(s):\n${summaryLines.join("\n")}`;
  if (errors.length > 0) {
    summary += `\n\n⚠️ ${errors.length} job(s) had issues:\n${errors.join("\n")}`;
  }

  return {
    success: true,
    needsConfirmation: true,
    summary: summary,
    scheduleJobsData: validatedJobs,
    errorCount: errors.length,
    errors: errors,
  };
}

/**
 * Execute the copyScheduleJobs function call from Gemini.
 * Copies schedule jobs from source date to target date server-side,
 * preserving ALL data including workMaps polygon data.
 * Returns preview for user confirmation — does NOT write to Firestore.
 */
async function executeCopyScheduleJobs(args) {
  const sourceDate = (args.sourceDate || "").trim();
  const targetDate = (args.targetDate || "").trim();

  if (!sourceDate || !targetDate) {
    return { success: false, error: "Both sourceDate and targetDate are required (YYYY-MM-DD)." };
  }

  if (sourceDate === targetDate) {
    return { success: false, error: "Source and target dates must be different." };
  }

  const monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];

  // Parse source date
  const srcParts = sourceDate.split("-");
  if (srcParts.length !== 3) {
    return { success: false, error: "Invalid source date format. Expected YYYY-MM-DD." };
  }
  const srcDate = new Date(parseInt(srcParts[0]), parseInt(srcParts[1]) - 1, parseInt(srcParts[2]));
  if (isNaN(srcDate.getTime())) {
    return { success: false, error: "Invalid source date." };
  }

  // Parse target date
  const tgtParts = targetDate.split("-");
  if (tgtParts.length !== 3) {
    return { success: false, error: "Invalid target date format. Expected YYYY-MM-DD." };
  }
  const tgtDate = new Date(parseInt(tgtParts[0]), parseInt(tgtParts[1]) - 1, parseInt(tgtParts[2]));
  if (isNaN(tgtDate.getTime())) {
    return { success: false, error: "Invalid target date." };
  }

  const srcMonthId = `${monthNames[srcDate.getMonth()]} ${srcDate.getFullYear()}`;
  const srcDailyId = `${srcParts[0]}-${srcParts[1]}-${srcParts[2]}`;
  const tgtMonthId = `${monthNames[tgtDate.getMonth()]} ${tgtDate.getFullYear()}`;
  const tgtDailyId = `${tgtParts[0]}-${tgtParts[1]}-${tgtParts[2]}`;

  // Fetch source day jobs
  const srcDayDoc = await db
    .collection("schedules")
    .doc(srcMonthId)
    .collection("days")
    .doc(srcDailyId)
    .get();

  if (!srcDayDoc.exists) {
    return { success: false, error: `No schedule data found for source date ${sourceDate}.` };
  }

  const srcData = srcDayDoc.data();
  const srcJobs = srcData.jobs || [];

  if (srcJobs.length === 0) {
    return { success: false, error: `No schedule jobs found on ${sourceDate}.` };
  }

  const { distributorMap, statusMap } = await getLookupMaps();

  // Build distributor name-to-ID lookup for reassignments
  const distributorsSnap = await db.collection("distributors").get();
  const distributorList = [];
  for (const doc of distributorsSnap.docs) {
    const data = doc.data();
    distributorList.push({ id: doc.id, name: (data.name || "").trim() });
  }

  // Parse reassignment map if provided
  const reassignMap = {};
  if (args.reassignments && Array.isArray(args.reassignments)) {
    for (const r of args.reassignments) {
      const fromName = (r.fromDistributor || "").trim().toLowerCase();
      const toName = (r.toDistributor || "").trim();
      if (fromName && toName) {
        // Resolve target distributor
        let matched = distributorList.find((d) => d.name.toLowerCase() === toName.toLowerCase());
        if (!matched) {
          matched = distributorList.find(
            (d) => d.name.toLowerCase().includes(toName.toLowerCase()) ||
                   toName.toLowerCase().includes(d.name.toLowerCase())
          );
        }
        if (matched) {
          reassignMap[fromName] = { id: matched.id, name: matched.name };
        }
      }
    }
  }

  // Filter by distributor names if specified
  const filterNames = (args.distributorNames || []).map((n) => n.toLowerCase().trim());

  const tgtDateStr = `${tgtDate.getDate()} ${monthNames[tgtDate.getMonth()]} ${tgtDate.getFullYear()}`;
  const srcDateStr = `${srcDate.getDate()} ${monthNames[srcDate.getMonth()]} ${srcDate.getFullYear()}`;
  const overrideStatus = args.statusId || "scheduled";

  const copiedJobs = [];
  const errors = [];

  for (let i = 0; i < srcJobs.length; i++) {
    const job = srcJobs[i];
    const srcDistId = job.distributorId || "";
    const srcDistName = distributorMap[srcDistId] || "Unknown";

    // Filter by distributor names if provided
    if (filterNames.length > 0) {
      const nameMatch = filterNames.some(
        (fn) => srcDistName.toLowerCase().includes(fn) || fn.includes(srcDistName.toLowerCase())
      );
      if (!nameMatch) continue;
    }

    // Apply reassignment if configured
    let targetDistId = srcDistId;
    let targetDistName = srcDistName;
    const reassignKey = srcDistName.toLowerCase();
    if (reassignMap[reassignKey]) {
      targetDistId = reassignMap[reassignKey].id;
      targetDistName = reassignMap[reassignKey].name;
    }

    const clients = job.clients || [job.client || ""];
    const areas = job.workingAreas || [job.workingArea || ""];
    const statusId = overrideStatus;
    const statusName = statusMap[statusId] || statusId;

    copiedJobs.push({
      distributorId: targetDistId,
      distributorName: targetDistName,
      clients: clients,
      workingAreas: areas,
      workMaps: job.workMaps || [],  // FULL polygon data preserved server-side
      date: targetDate,
      monthId: tgtMonthId,
      dailyId: tgtDailyId,
      statusId: statusId,
      statusName: statusName,
      dateDisplay: tgtDateStr,
    });
  }

  if (copiedJobs.length === 0) {
    const reason = filterNames.length > 0
      ? `No jobs found matching the specified distributors on ${sourceDate}.`
      : `No jobs to copy from ${sourceDate}.`;
    return { success: false, error: reason };
  }

  const summaryLines = copiedJobs.map((j, i) =>
    `${i + 1}. **${j.distributorName}** → ${j.clients.join(", ")}${j.workingAreas.length > 0 ? ` (${j.workingAreas.join(", ")})` : ""}${j.workMaps.length > 0 ? " 🗺️" : ""}`
  );

  const polygonCount = copiedJobs.reduce((sum, j) => sum + (j.workMaps ? j.workMaps.length : 0), 0);
  let summary = `Ready to copy **${copiedJobs.length}** schedule assignment(s) from ${srcDateStr} to **${tgtDateStr}**:\n${summaryLines.join("\n")}`;
  if (polygonCount > 0) {
    summary += `\n\n🗺️ ${polygonCount} work area polygon(s) will be included.`;
  }
  if (errors.length > 0) {
    summary += `\n\n⚠️ ${errors.length} issue(s):\n${errors.join("\n")}`;
  }

  console.log(`[copyScheduleJobs] Copying ${copiedJobs.length} jobs from ${sourceDate} to ${targetDate} (${polygonCount} polygons)`);

  return {
    success: true,
    needsConfirmation: true,
    summary: summary,
    scheduleJobsData: copiedJobs,
    errorCount: errors.length,
    errors: errors,
  };
}

// ============================================================
// SHARED: Build system prompt for AI chat
// ============================================================
function buildSystemPrompt(userName, context, knowledgeEntries) {
  return `You are Pelisa, a friendly and knowledgeable AI assistant for the CLM Schedule application.
You help users understand their job schedules, job lists, collection schedules, and invoicing.
You can also ADD new jobs to the Job List when the user asks.
You can also UPDATE existing jobs on the Job List when the user asks to change, modify, or edit a job.

IMPORTANT: The CLM app has THREE separate data sections. You have access to ALL of them:

1. **SCHEDULE** (the "Schedule" tab) — This is the distributor assignment grid.
   - Shows which distributor is assigned to which client/area on which date.
   - Fields: client, working area, distributor, status (scheduled/done/urgent/standby).
   - Think of it as "WHO is going WHERE on WHAT date."

2. **JOB LIST** (the "Job List" tab) — This is the business/invoicing side.
   - Tracks invoices, amounts, quantities, man-days, job types, and payment status.
   - Fields: invoice number, client, amount (in Rand), area, quantity, man-days, job type, job status, invoice status, special instructions, collection address, report addresses, who to invoice.
   - Think of it as "WHAT work was done, HOW MUCH it costs, and WHAT's the payment status."

3. **COLLECTION SCHEDULE** (the "Collection Schedule" tab) — Vehicle logistics.
   - Tracks which vehicles/trailers are collecting materials from which addresses.
   - Fields: client, address, vehicle, trailer, status.

When a user asks about "jobs" without specifying, search BOTH Schedule AND Job List data.
When they ask about invoices, amounts, or payment status, look in Job List data.
When they ask about distributors or assignments, look in Schedule data.
When they ask about vehicles or collections, look in Collection Schedule data.

IMPORTANT — DISTINGUISHING BETWEEN JOB LIST AND SCHEDULE:
- **JOB LIST** = business/invoicing side: invoice numbers, amounts, man-days, job types, payment status. Use addJobToJobList or addMultipleJobsToJobList for these.
- **SCHEDULE GRID** = distributor assignment side: WHO (distributor) is going WHERE (client/area) on WHAT date. Use addJobsToSchedule for these.
- When the user says "add to schedule" or "assign distributor" or "allocate" → use SCHEDULE operations (addJobsToSchedule).
- When the user says "add to job list" or mentions invoices, amounts, man-days → use JOB LIST operations (addJobToJobList).
- If unclear, ASK the user: "Do you want to add this to the Job List (invoicing) or the Schedule Grid (distributor assignments)?"

SCHEDULE GRID OPERATIONS:
- You can VIEW schedule assignments using the context data (SCHEDULE JOBS section shows Date|Client|Area|Distributor|Status).
- You can FETCH schedule jobs from any date using getScheduleJobsByDate.
- You can CHECK which distributors are available (not assigned) on a date using getAvailableDistributors.
- You can ADD new schedule assignments using addJobsToSchedule. Required: distributor name, client names, date. Optional: working areas, status.
- New schedule assignments default to status "Scheduled".

COPYING SCHEDULE JOBS FROM PREVIOUS DATES / LAST MONTH:
- When the user asks to "copy schedule from last month", "replicate last week's assignments", or "same assignments as [date]":
  **ALWAYS use copyScheduleJobs** — this copies jobs server-side and guarantees ALL data is preserved, including work area polygons/maps.
  1. Call copyScheduleJobs with sourceDate and targetDate.
  2. Optionally specify distributorNames to only copy certain distributors' jobs.
  3. Optionally specify reassignments to change which distributor gets assigned.
  4. The user will see a confirmation preview including polygon/map indicators (🗺️).
- Do NOT use getScheduleJobsByDate + addJobsToSchedule for copying — use copyScheduleJobs instead, as it preserves work area polygon data reliably.
- When copying from a different month, the user may say "copy February's schedule to March" — you'll need to copy day by day or ask which specific dates.

ALLOCATING TO AVAILABLE DISTRIBUTORS:
- When the user says "assign to distributors that are free" or "allocate unassigned distributors":
  1. Use getAvailableDistributors to find who has no assignments on the target date.
  2. Present the available distributors and ask which clients/areas to assign.
  3. Use addJobsToSchedule to create the assignments.
- You can also suggest available distributors proactively when the user is adding schedule jobs.

ADDING JOBS TO THE JOB LIST:
- You have the ability to add new jobs to the Job List using the addJobToJobList function.
- Required fields: client name, date, and man-days. ALWAYS ask for these if the user doesn't provide them.
- Optional fields: job type, area, invoice number, amount, quantity, special instructions, collection address, who to invoice.
- Available job types: Flyer Distribution, Flyer Printing and Distribution, Flyers - Printing only, Flyers and Posters, Postering, Calenders Distribution, Window Cleaning, Solar Panel Cleaning, Junk Collection, Furniture Move, Trailer Towing. Default is Flyer Distribution.
- New jobs are created with status "Standby" and invoice status "Pending".
- After adding a job, confirm the details to the user.
- ALWAYS present a summary of what you're about to add and wait for user confirmation before calling the function.
- Today's date is: ${new Date().toISOString().split("T")[0]}

COPYING JOBS FROM PREVIOUS DATES:
- You can fetch actual job records from ANY date using the getJobsByDate function.
- Use this when the user asks to "copy jobs from [date]", "duplicate last Monday's jobs", "add the same jobs as [date]", etc.
- When copying, use the fetched job details (client, job type, man-days, area, amount, quantity, etc.) and apply them to the new target date.
- After fetching, use addMultipleJobsToJobList to add all jobs at once with the new date.
- Ask the user for the target date if they don't specify it.
- The user may want to modify some fields (e.g., different date, adjusted amounts) — ask if they want any changes.

ADDING MULTIPLE JOBS AT ONCE:
- Use addMultipleJobsToJobList when the user wants to add more than one job in a single operation.
- This is useful for: copying jobs from a previous date, pasting text with multiple jobs, or explicitly listing several jobs.
- Each job in the array is validated individually — partial success is possible (valid jobs proceed, invalid ones are reported).
- Maximum 20 jobs per call.
- All validated jobs are shown in a SINGLE bulk confirmation card for the user to confirm or cancel.

TIME-SENSITIVE JOB TYPES:
The following job types REQUIRE a time slot — you must ALWAYS ask the user for the time if they don't provide it:
  - Junk Collection (junkCollection) — requires time, vehicle, collection address
  - Furniture Move (furnitureMove) — requires time, vehicle, collection address
  - Trailer Towing (trailerTowing) — requires time, vehicle
  - Window Cleaning (windowCleaning) — requires time
  - Solar Panel Cleaning (solarPanelCleaning) — requires time
Valid time slots: 07:30, then 08:00 to 20:00 in 30-minute intervals (e.g. 08:00, 08:30, 09:00, ..., 20:00).
When a user asks to add or change a time-sensitive job, ALWAYS:
1. Ask for the time slot if not provided
2. Show both date AND time in confirmations (e.g. "15 March 2026 at 08:00")
3. When changing the date of a time-sensitive job, ask if the time should stay the same or change

FORM FIELDS AND REQUIRED DATA PER JOB TYPE:
All job types require: client, date, man-days
Junk Collection / Furniture Move / Trailer Towing also typically need: collection address, quantity (determines vehicle size)
Window Cleaning / Solar Panel Cleaning also typically need: quantity (number of panels/windows), area
Flyer Distribution / Flyer Printing types also typically need: quantity, area

CONFIRMATION RULES:
- You MUST NEVER write data directly. All adds and updates go through a confirmation step.
- When adding a job: present a summary card with all fields and wait for the user to click Confirm.
- When updating a job: present a change summary showing old→new values and wait for the user to click Confirm.
- If the user says "yes", "confirm", "go ahead" etc. in response to a confirmation card, that is handled by the UI button — do NOT call the function again.

UPDATING JOBS ON THE JOB LIST:
- You can update existing jobs using the updateJobOnJobList function.
- To identify which job to update, you need the client name and date from the context data.
- Only include fields that need to change in the updates object — omit fields that stay the same.
- If the user says "change the amount for ClientX to R5000", find ClientX's date from context and call updateJobOnJobList with client, date, and updates: {amount: 5000}.
- If multiple jobs match, the system will ask the user to be more specific.
- For time-sensitive jobs (junkCollection, furnitureMove, trailerTowing, windowCleaning, solarPanelCleaning):
  - When changing the date, ask if the time slot should also change
  - When changing just the time, include the time field in updates
  - Always show both old and new date+time in the change summary
- Updatable fields: client, date, time (for time-sensitive jobs), manDays, jobTypeId, area, invoice, amount, quantity, specialInstructions, collectionAddress, whoToInvoice, jobStatusId, invoiceStatusId, quantityDistributed, invoiceDetails, reportAddresses.
- ALWAYS present old→new changes summary and wait for user confirmation before proceeding.

Your role:
- Answer questions about jobs, schedules, distributors, and invoicing
- Add new jobs to the Job List when asked
- Update existing jobs on the Job List when asked (change client, amount, status, date, etc.)
- Provide summaries of daily, weekly, or monthly activities
- Help find specific jobs by client, area, date, or status
- Search across BOTH schedule and job list when looking for a client
- Explain job statuses and what they mean
- Calculate totals (amounts, quantities, man-days) when asked
- Extract job information from pasted WhatsApp messages, emails, and other unstructured text
- Be friendly, concise, and reference specific data when relevant

EXTRACTING JOBS FROM WHATSAPP / EMAIL / PASTED TEXT:
Users will often paste raw WhatsApp conversations or email threads containing job requests. You MUST intelligently parse these and extract job information. Here's how:

1. **Identify the job request**: Look for keywords like "collection", "move", "clean", "distribute", "deliver", "pick up", "drop off", "tow", "flyers", "posters", "calendars", "junk", "furniture", "windows", "solar panels", etc.

2. **Extract fields from natural language**:
   - **Client name**: Look for company names, personal names, or property names. Often appears after "for", "from", "at", or in email signatures/WhatsApp contact names.
   - **Date**: Parse natural language dates like "tomorrow", "next Monday", "the 15th", "25 March", "25/03/2026", "2026-03-25". Relative dates should use today's date (${new Date().toISOString().split("T")[0]}) as reference.
   - **Time**: Look for "at 8am", "08:00", "morning" (suggest 08:00), "afternoon" (suggest 13:00), "8 o'clock", etc. Round to nearest valid 30-min slot.
   - **Address / Location**: Look for street addresses, suburb names, complex names. Map to collection address or area.
   - **Job type**: Infer from context:
     - "junk", "rubble", "waste", "rubbish", "garden refuse" → junkCollection
     - "move", "furniture", "relocate", "items to move" → furnitureMove
     - "tow", "trailer", "transport" → trailerTowing
     - "windows", "window cleaning" → windowCleaning
     - "solar", "solar panels", "panels" → solarPanelCleaning
     - "flyers", "pamphlets", "leaflets" → flyerDistribution or flyerPrintingAndDistribution
     - "posters" → postering or flyersAndPosters
     - "calendars", "calenders" → calendersDistribution
     - "print", "printing only" → flyersPrintingOnly
   - **Quantity / Volume**: Look for numbers of items, bags, loads, panels, windows, etc.
   - **Amount / Price**: Look for "R500", "R1,500", "quoted R2000", currency amounts.
   - **Special instructions**: Any extra details like "gate code 1234", "call on arrival", "fragile items", "2nd floor", access notes, parking instructions.
   - **Man-days**: If not explicitly stated, make a reasonable estimate: 1 for simple jobs, 2+ for larger moves or multi-day work. Always confirm with the user.
   - **Who to invoice**: Sometimes mentioned as "bill to", "invoice to", "charge to", or a different name than the client.

3. **Handle multiple jobs in one message**: If the pasted text contains multiple job requests (e.g., "Monday: collection at X, Tuesday: move at Y"), extract ALL jobs and use addMultipleJobsToJobList to add them all at once. Present the complete list for a single bulk confirmation.

4. **Handle ambiguity**: If critical fields are missing or unclear:
   - Present what you extracted clearly
   - Ask specifically for the missing required fields (client, date, man-days)
   - For time-sensitive jobs, also ask for the time slot
   - Suggest reasonable defaults when possible (e.g., "I'll assume 1 man-day unless you say otherwise")

5. **WhatsApp format awareness**: WhatsApp messages often have:
   - Timestamps like "[12:34, 23/03/2026]" or "23/03/2026, 12:34" — these are MESSAGE timestamps, not job dates (unless the content refers to "today" or "now")
   - Contact names before colons: "John Smith: Can you collect..."
   - Forwarded message headers: "Forwarded from..."
   - Reply quotes: Lines starting with ">" or indented text
   - Multiple messages from different people in a conversation thread

6. **Email format awareness**: Emails often have:
   - Subject lines with job details
   - Signature blocks (ignore phone numbers/addresses in signatures unless they're the job location)
   - Reply chains with ">" prefixes or "On [date], [person] wrote:" headers
   - CC/BCC recipients that might indicate who to invoice

7. **After extraction**: Always present a clear summary of what you extracted and ask the user to confirm or correct before adding. Format like:
   "I extracted the following from your message:
   - **Client**: [name]
   - **Job Type**: [type]
   - **Date**: [date] at [time]
   - **Address**: [address]
   - **Man-days**: [estimate]
   - **Special Instructions**: [any notes]
   
   Shall I add this job? Or would you like to change anything?"

FETCHING OTHER MONTHS:
- You only have the CURRENT month's data loaded initially.
- If the user asks about a different month (previous, next, or any other), use the getMonthData function to fetch that month's data first, then answer their question.
- Month IDs use format 'MMM YYYY' (e.g., 'Jan 2026', 'Feb 2026').

Important rules:
- Always reference actual data from the context provided
- When searching for a client, check BOTH schedule jobs AND job list items
- If you don't have data for a requested period, use getMonthData to fetch it. Only say data is unavailable if getMonthData returns no results.
- Use Rand (R) for currency amounts
- Format dates in a human-friendly way (e.g., "15 March 2026")
- When referencing specific entries, include the client name, date, and which section (Schedule or Job List) it came from
- If the user asks about something outside your knowledge, suggest they check the app directly

The user's name is: ${userName || "User"}

${knowledgeEntries.length > 0 ? `SYSTEM KNOWLEDGE (taught by admin):
${knowledgeEntries.map((e) => `- ${e.content}`).join("\n")}
` : ""}
Here is the current data context:
${context || "No monthly summary data available yet. The summaries will be generated as jobs are added to the schedule."}`;
}

// ============================================================
// SHARED: Load context and knowledge for a month
// ============================================================
async function loadChatContext(monthId, logPrefix) {
  const now = new Date();
  const currentMonthId = monthId || formatMonthId(now);
  let context = "";
  let knowledgeEntries = [];
  try {
    const [summaryData, knowledge] = await Promise.all([
      getCachedSummary(currentMonthId),
      getCachedKnowledge(),
    ]);
    knowledgeEntries = knowledge;
    if (summaryData) {
      console.log(`[${logPrefix}] Loaded summary for ${currentMonthId}: ${summaryData.scheduleJobs?.length || 0} schedule, ${summaryData.jobListJobs?.length || 0} jobList, ${summaryData.collectionJobs?.length || 0} collection (cached)`);
      context = buildContextFromSummary(currentMonthId, summaryData);
    } else {
      console.log(`[${logPrefix}] No summary for ${currentMonthId}, skipping`);
    }
  } catch (e) {
    console.error("Error loading context:", e);
    context = "Monthly summary data is currently unavailable.";
  }
  return { currentMonthId, context, knowledgeEntries };
}

// ============================================================
// SHARED: Process function calls from AI response
// ============================================================
async function processFunctionCalls(fnCalls, userName, authUid) {
  let action = null;
  const functionResponses = [];

  for (const fnCall of fnCalls) {
    console.log(`[chat] Function call: ${fnCall.name}`, JSON.stringify(fnCall.args));
    let fnResult;

    if (fnCall.name === "addJobToJobList") {
      fnResult = await executeAddJobToJobList(fnCall.args, userName, authUid);
      if (fnResult.success && fnResult.needsConfirmation) {
        action = { type: "jobPendingConfirmation", jobData: fnResult.jobData };
      }
    } else if (fnCall.name === "addMultipleJobsToJobList") {
      fnResult = await executeAddMultipleJobsToJobList(fnCall.args, userName, authUid);
      if (fnResult.success && fnResult.needsConfirmation) {
        action = { type: "multiJobPendingConfirmation", jobsData: fnResult.jobsData };
      }
    } else if (fnCall.name === "getJobsByDate") {
      fnResult = await executeGetJobsByDate(fnCall.args);
    } else if (fnCall.name === "getScheduleJobsByDate") {
      fnResult = await executeGetScheduleJobsByDate(fnCall.args);
    } else if (fnCall.name === "getAvailableDistributors") {
      fnResult = await executeGetAvailableDistributors(fnCall.args);
    } else if (fnCall.name === "addJobsToSchedule") {
      fnResult = await executeAddJobsToSchedule(fnCall.args, userName);
      if (fnResult.success && fnResult.needsConfirmation) {
        action = { type: "schedulePendingConfirmation", scheduleJobsData: fnResult.scheduleJobsData };
      }
    } else if (fnCall.name === "copyScheduleJobs") {
      fnResult = await executeCopyScheduleJobs(fnCall.args);
      if (fnResult.success && fnResult.needsConfirmation) {
        action = { type: "schedulePendingConfirmation", scheduleJobsData: fnResult.scheduleJobsData };
      }
    } else if (fnCall.name === "updateJobOnJobList") {
      fnResult = await executeUpdateJobOnJobList(fnCall.args, userName, authUid);
      if (fnResult.success && fnResult.needsConfirmation) {
        action = { type: "updatePendingConfirmation", updateData: fnResult.updateData };
      }
    } else if (fnCall.name === "getMonthData") {
      const requestedMonthId = fnCall.args.monthId;
      console.log(`[chat] Fetching month data for: ${requestedMonthId}`);
      const monthData = await getCachedSummary(requestedMonthId);
      if (monthData) {
        fnResult = { success: true, data: buildContextFromSummary(requestedMonthId, monthData) };
      } else {
        fnResult = { success: false, error: `No data found for ${requestedMonthId}. The monthly summary may not have been generated yet.` };
      }
    } else {
      fnResult = { success: false, error: `Unknown function: ${fnCall.name}` };
    }

    console.log(`[chat] Function result for ${fnCall.name}:`, JSON.stringify(fnResult));
    functionResponses.push({
      functionResponse: { id: fnCall.id, name: fnCall.name, response: fnResult },
    });
  }

  return { action, functionResponses };
}

// ============================================================
// 3. CHAT WITH ASSISTANT — Non-streaming (kept for backward compat)
// ============================================================
exports.chatWithAssistant = onCall(
  {
    timeoutSeconds: 60,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { message, conversationHistory, monthId, userName } = request.data;
    if (!message || typeof message !== "string") {
      throw new HttpsError("invalid-argument", "message is required.");
    }

    const { currentMonthId, context, knowledgeEntries } = await loadChatContext(monthId, "chatWithAssistant");
    const systemPrompt = buildSystemPrompt(userName, context, knowledgeEntries);

    // Build conversation for Gemini via Firebase AI Logic (Vertex AI backend)
    const ai = new GoogleGenAI({
      vertexai: true,
      project: process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT,
      location: "us-central1",
    });

    const history = [];
    if (conversationHistory && Array.isArray(conversationHistory)) {
      // Only keep last 10 messages to reduce token usage
      const trimmed = conversationHistory.slice(-10);
      for (const msg of trimmed) {
        history.push({
          role: msg.role === "assistant" ? "model" : "user",
          parts: [{ text: msg.content }],
        });
      }
    }

    console.log(`[chatWithAssistant] User: ${userName}, Message: "${message}", Month: ${currentMonthId}, History: ${history.length} msgs, Context length: ${context.length} chars`);

    try {
      const chat = ai.chats.create({
        model: "gemini-2.5-flash",
        config: {
          systemInstruction: systemPrompt,
          tools: chatTools,
        },
        history,
      });
      let result = await chat.sendMessage({ message });
      let action = null;

      // Handle function calling loop (Gemini may call multiple tools per turn)
      while (true) {
        const fnCalls = result.functionCalls;
        if (!fnCalls || fnCalls.length === 0) break;

        const { action: fnAction, functionResponses } = await processFunctionCalls(fnCalls, userName, request.auth.uid);
        if (fnAction) action = fnAction;

        result = await chat.sendMessage({ message: functionResponses });
      }

      const response = result.text || "";

      console.log(`[chatWithAssistant] Success - response length: ${response.length} chars, action: ${action ? action.type : "none"}`);

      return {
        success: true,
        response,
        monthId: currentMonthId,
        action,
      };
    } catch (e) {
      console.error("[chatWithAssistant] Gemini API error:", e.message || e);
      console.error("[chatWithAssistant] Error status:", e.status, "statusText:", e.statusText);
      throw new HttpsError(
        "internal",
        `AI error: ${e.message || "Failed to get AI response. Please try again."}`
      );
    }
  }
);

// ============================================================
// 4. CONFIRM ADD JOB - Writes a validated job to Firestore
//    Called from Flutter after the user confirms the preview.
// ============================================================
exports.confirmAddJob = onCall(
  {
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { jobData, userName } = request.data;
    if (!jobData || !jobData.client || !jobData.date || !jobData.manDays) {
      throw new HttpsError("invalid-argument", "Missing required job data.");
    }

    // Parse the date from YYYY-MM-DD string
    const dateParts = jobData.date.split("-");
    const jobDate = new Date(
      parseInt(dateParts[0]),
      parseInt(dateParts[1]) - 1,
      parseInt(dateParts[2])
    );
    if (isNaN(jobDate.getTime())) {
      throw new HttpsError("invalid-argument", "Invalid date.");
    }

    // Apply time if provided (for time-sensitive job types)
    if (jobData.time) {
      const timeMatch = jobData.time.match(/^(\d{1,2}):(\d{2})$/);
      if (timeMatch) {
        jobDate.setHours(parseInt(timeMatch[1]), parseInt(timeMatch[2]), 0, 0);
      }
    }

    const monthId = jobData.monthId;
    if (!monthId) {
      throw new HttpsError("invalid-argument", "Missing monthId.");
    }

    // Default collection date placeholder (matches Flutter: DateTime(2000, 1, 1))
    const defaultCollectionDate = new Date(2000, 0, 1);

    // Build the Firestore document matching JobListItem.toMap() format
    const firestoreData = {
      client: jobData.client,
      date: admin.firestore.Timestamp.fromDate(jobDate),
      manDays: jobData.manDays,
      jobType: jobData.jobTypeId || "flyersPrintingOnly",
      jobStatusId: "standby",
      invoiceStatusId: "pending",
      area: jobData.area || "",
      invoice: jobData.invoice || "",
      amount: jobData.amount || 0,
      quantity: jobData.quantity || 0,
      specialInstructions: jobData.specialInstructions || "",
      collectionAddress: jobData.collectionAddress || "",
      whoToInvoice: jobData.whoToInvoice || "",
      collectionDate: admin.firestore.Timestamp.fromDate(defaultCollectionDate),
      quantityDistributed: 0,
      invoiceDetails: "",
      reportAddresses: "",
      collectionJobId: "",
      updates: [
        {
          userId: request.auth.uid,
          fieldName: "created",
          oldValue: null,
          newValue: "Job created via Pelisa",
          timestamp: admin.firestore.Timestamp.now(),
          userDisplayName: userName || "Pelisa",
          oldValueDisplay: null,
          newValueDisplay: null,
        },
      ],
      customPolygons: [],
      reminders: [],
    };

    // Ensure the monthly document exists
    const monthRef = db.collection("jobLists").doc(monthId);
    const monthDoc = await monthRef.get();
    if (!monthDoc.exists) {
      await monthRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
    }

    // Write to Firestore
    const docRef = await monthRef.collection("items").add(firestoreData);

    console.log(`[confirmAddJob] Created job ${docRef.id} in ${monthId} for client "${jobData.client}"`);

    return {
      success: true,
      jobId: docRef.id,
      monthId: monthId,
    };
  }
);

// ============================================================
// 4b. CONFIRM ADD MULTIPLE JOBS - Writes multiple validated jobs to Firestore
//     Called from Flutter after the user confirms the bulk preview.
// ============================================================
exports.confirmAddMultipleJobs = onCall(
  {
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { jobsData, userName } = request.data;
    if (!jobsData || !Array.isArray(jobsData) || jobsData.length === 0) {
      throw new HttpsError("invalid-argument", "Missing jobs data.");
    }

    if (jobsData.length > 20) {
      throw new HttpsError("invalid-argument", "Maximum 20 jobs per batch.");
    }

    const defaultCollectionDate = new Date(2000, 0, 1);
    const results = [];
    const batch = db.batch();

    // Group jobs by monthId to ensure month docs exist
    const monthIds = new Set();

    for (const jobData of jobsData) {
      if (!jobData.client || !jobData.date || !jobData.manDays) {
        continue; // Skip invalid jobs
      }

      const dateParts = jobData.date.split("-");
      const jobDate = new Date(
        parseInt(dateParts[0]),
        parseInt(dateParts[1]) - 1,
        parseInt(dateParts[2])
      );
      if (isNaN(jobDate.getTime())) continue;

      if (jobData.time) {
        const timeMatch = jobData.time.match(/^(\d{1,2}):(\d{2})$/);
        if (timeMatch) {
          jobDate.setHours(parseInt(timeMatch[1]), parseInt(timeMatch[2]), 0, 0);
        }
      }

      const monthId = jobData.monthId;
      if (!monthId) continue;

      monthIds.add(monthId);

      const firestoreData = {
        client: jobData.client,
        date: admin.firestore.Timestamp.fromDate(jobDate),
        manDays: jobData.manDays,
        jobType: jobData.jobTypeId || "flyersPrintingOnly",
        jobStatusId: "standby",
        invoiceStatusId: "pending",
        area: jobData.area || "",
        invoice: jobData.invoice || "",
        amount: jobData.amount || 0,
        quantity: jobData.quantity || 0,
        specialInstructions: jobData.specialInstructions || "",
        collectionAddress: jobData.collectionAddress || "",
        whoToInvoice: jobData.whoToInvoice || "",
        collectionDate: admin.firestore.Timestamp.fromDate(defaultCollectionDate),
        quantityDistributed: 0,
        invoiceDetails: "",
        reportAddresses: "",
        collectionJobId: "",
        updates: [
          {
            userId: request.auth.uid,
            fieldName: "created",
            oldValue: null,
            newValue: "Job created via Pelisa (bulk)",
            timestamp: admin.firestore.Timestamp.now(),
            userDisplayName: userName || "Pelisa",
            oldValueDisplay: null,
            newValueDisplay: null,
          },
        ],
        customPolygons: [],
        reminders: [],
      };

      const monthRef = db.collection("jobLists").doc(monthId);
      const docRef = monthRef.collection("items").doc();
      batch.set(docRef, firestoreData);
      results.push({ jobId: docRef.id, monthId, client: jobData.client });
    }

    // Ensure month documents exist
    for (const monthId of monthIds) {
      const monthRef = db.collection("jobLists").doc(monthId);
      const monthDoc = await monthRef.get();
      if (!monthDoc.exists) {
        await monthRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
      }
    }

    await batch.commit();

    console.log(`[confirmAddMultipleJobs] Created ${results.length} jobs across ${monthIds.size} month(s)`);

    return {
      success: true,
      jobCount: results.length,
      jobs: results,
    };
  }
);

// ============================================================
// 4c. CONFIRM ADD SCHEDULE JOBS - Writes validated schedule jobs to Firestore
//     Adds jobs to the schedule grid daily document jobs arrays.
// ============================================================
exports.confirmAddScheduleJobs = onCall(
  {
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { scheduleJobsData } = request.data;
    if (!scheduleJobsData || !Array.isArray(scheduleJobsData) || scheduleJobsData.length === 0) {
      throw new HttpsError("invalid-argument", "Missing schedule jobs data.");
    }

    if (scheduleJobsData.length > 30) {
      throw new HttpsError("invalid-argument", "Maximum 30 schedule jobs per batch.");
    }

    // Group jobs by dailyId to batch writes per document
    const jobsByDay = {};

    for (const jobData of scheduleJobsData) {
      if (!jobData.distributorId || !jobData.clients || !jobData.date) {
        continue;
      }

      const dateParts = jobData.date.split("-");
      const jobDate = new Date(
        parseInt(dateParts[0]),
        parseInt(dateParts[1]) - 1,
        parseInt(dateParts[2])
      );
      if (isNaN(jobDate.getTime())) continue;

      const monthId = jobData.monthId;
      const dailyId = jobData.dailyId || jobData.date;
      const key = `${monthId}|${dailyId}`;

      if (!jobsByDay[key]) {
        jobsByDay[key] = { monthId, dailyId, timestamp: admin.firestore.Timestamp.fromDate(jobDate), jobs: [] };
      }

      // Generate unique job ID
      const jobId = db.collection("dummy").doc().id;

      jobsByDay[key].jobs.push({
        id: jobId,
        clients: jobData.clients,
        workingAreas: jobData.workingAreas || [],
        workMaps: jobData.workMaps || [],
        distributorId: jobData.distributorId,
        date: admin.firestore.Timestamp.fromDate(jobDate),
        statusId: jobData.statusId || "scheduled",
        // Backwards compatibility
        status: jobData.statusId || "scheduled",
        client: jobData.clients.length > 0 ? jobData.clients[0] : "",
        workingArea: jobData.workingAreas && jobData.workingAreas.length > 0 ? jobData.workingAreas[0] : "",
      });
    }

    let totalAdded = 0;

    // Write to each daily document
    for (const [, dayGroup] of Object.entries(jobsByDay)) {
      const dayRef = db
        .collection("schedules")
        .doc(dayGroup.monthId)
        .collection("days")
        .doc(dayGroup.dailyId);

      const dayDoc = await dayRef.get();

      if (!dayDoc.exists) {
        // Create the daily document with the jobs
        await dayRef.set({
          created: admin.firestore.FieldValue.serverTimestamp(),
          date: dayGroup.dailyId,
          timestamp: dayGroup.timestamp,
          jobs: dayGroup.jobs,
        });

        // Ensure monthly index exists
        const monthRef = db.collection("schedules").doc(dayGroup.monthId);
        const monthDoc = await monthRef.get();
        if (!monthDoc.exists) {
          await monthRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
        }
      } else {
        // Append to existing jobs array
        await dayRef.update({
          jobs: admin.firestore.FieldValue.arrayUnion(...dayGroup.jobs),
        });
      }

      totalAdded += dayGroup.jobs.length;
    }

    console.log(`[confirmAddScheduleJobs] Added ${totalAdded} schedule jobs across ${Object.keys(jobsByDay).length} day(s)`);

    return {
      success: true,
      jobCount: totalAdded,
    };
  }
);

// ============================================================
// 5. CONFIRM UPDATE JOB - Applies validated changes to an existing job
//    Called from Flutter after the user confirms the update preview.
// ============================================================
exports.confirmUpdateJob = onCall(
  {
    timeoutSeconds: 30,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { updateData, userName } = request.data;
    if (!updateData || !updateData.jobId || !updateData.monthId || !updateData.changes) {
      throw new HttpsError("invalid-argument", "Missing required update data.");
    }

    const { jobId, monthId, changes } = updateData;

    // Verify the job still exists
    const jobRef = db.collection("jobLists").doc(monthId).collection("items").doc(jobId);
    const jobDoc = await jobRef.get();

    if (!jobDoc.exists) {
      throw new HttpsError("not-found", "Job no longer exists. It may have been deleted.");
    }

    const monthNames = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];

    // Build the Firestore update map and audit trail entries
    const firestoreUpdates = {};
    const auditEntries = [];

    for (const [updateKey, changeInfo] of Object.entries(changes)) {
      const { firestoreField, oldValue, newValue, oldDisplay, newDisplay, label } = changeInfo;

      if (updateKey === "date") {
        // Convert date string to Timestamp (may be ISO string with time or YYYY-MM-DD)
        let nd;
        if (newValue.includes("T")) {
          // ISO string with time component (e.g. from time-sensitive job updates)
          nd = new Date(newValue);
        } else {
          // Plain YYYY-MM-DD
          const newDateParts = newValue.split("-");
          nd = new Date(parseInt(newDateParts[0]), parseInt(newDateParts[1]) - 1, parseInt(newDateParts[2]));
        }
        firestoreUpdates[firestoreField] = admin.firestore.Timestamp.fromDate(nd);
      } else {
        firestoreUpdates[firestoreField] = newValue;
      }

      auditEntries.push({
        userId: request.auth.uid,
        fieldName: label,
        oldValue: oldDisplay || String(oldValue ?? ""),
        newValue: newDisplay || String(newValue),
        timestamp: admin.firestore.Timestamp.now(),
        userDisplayName: userName || "Pelisa",
        oldValueDisplay: oldDisplay || null,
        newValueDisplay: newDisplay || null,
      });
    }

    // Apply updates + append audit trail
    firestoreUpdates["updates"] = admin.firestore.FieldValue.arrayUnion(...auditEntries);

    await jobRef.update(firestoreUpdates);

    console.log(`[confirmUpdateJob] Updated job ${jobId} in ${monthId}: ${Object.keys(changes).join(", ")}`);

    return {
      success: true,
      jobId: jobId,
      monthId: monthId,
      fieldsUpdated: Object.keys(changes),
    };
  }
);

// ============================================================
// 6. STREAMING CHAT — SSE endpoint for real-time text streaming
// ============================================================
exports.chatWithAssistantStream = onRequest(
  {
    timeoutSeconds: 120,
    memory: "512MiB",
    cors: true,
  },
  async (req, res) => {
    // Only accept POST
    if (req.method !== "POST") {
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    // Verify Firebase ID token
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      res.status(401).json({ error: "Missing or invalid Authorization header" });
      return;
    }
    const idToken = authHeader.split("Bearer ")[1];
    let decodedToken;
    try {
      decodedToken = await admin.auth().verifyIdToken(idToken);
    } catch (e) {
      res.status(401).json({ error: "Invalid or expired token" });
      return;
    }

    const { message, conversationHistory, monthId, userName } = req.body;
    if (!message || typeof message !== "string") {
      res.status(400).json({ error: "message is required" });
      return;
    }

    // Set SSE headers
    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");
    res.setHeader("X-Accel-Buffering", "no");

    const sendEvent = (data) => {
      res.write(`data: ${JSON.stringify(data)}\n\n`);
    };

    try {
      const { currentMonthId, context, knowledgeEntries } = await loadChatContext(monthId, "chatStream");
      const systemPrompt = buildSystemPrompt(userName, context, knowledgeEntries);

      const ai = new GoogleGenAI({
        vertexai: true,
        project: process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT,
        location: "us-central1",
      });

      const history = [];
      if (conversationHistory && Array.isArray(conversationHistory)) {
        const trimmed = conversationHistory.slice(-10);
        for (const msg of trimmed) {
          history.push({
            role: msg.role === "assistant" ? "model" : "user",
            parts: [{ text: msg.content }],
          });
        }
      }

      console.log(`[chatStream] User: ${userName}, Message: "${message}", Month: ${currentMonthId}, History: ${history.length} msgs`);

      const chat = ai.chats.create({
        model: "gemini-2.5-flash",
        config: {
          systemInstruction: systemPrompt,
          tools: chatTools,
        },
        history,
      });

      let action = null;
      let currentMessage = message;

      // Function calling loop: use non-streaming sendMessage for tool calls
      while (true) {
        // First, try non-streaming to check for function calls
        const result = await chat.sendMessage({ message: currentMessage });
        const fnCalls = result.functionCalls;

        if (!fnCalls || fnCalls.length === 0) {
          // No function calls — this is the final text response.
          // We already have the full text, send it in chunks for streaming effect.
          const fullText = result.text || "";
          // Split into chunks at sentence/paragraph boundaries for natural streaming
          const chunks = fullText.match(/[^.!?\n]+[.!?\n]+|[^.!?\n]+$/g) || [fullText];
          for (const chunk of chunks) {
            sendEvent({ type: "text", content: chunk });
          }
          break;
        }

        // Process function calls
        sendEvent({ type: "status", content: "Looking up data..." });
        const { action: fnAction, functionResponses } = await processFunctionCalls(fnCalls, userName, decodedToken.uid);
        if (fnAction) action = fnAction;

        // Send function responses back — next iteration will check for more calls or final text
        currentMessage = functionResponses;
      }

      // Send completion event with optional action
      sendEvent({ type: "done", action, monthId: currentMonthId });
      res.end();

      console.log(`[chatStream] Success - action: ${action ? action.type : "none"}`);
    } catch (e) {
      console.error("[chatStream] Error:", e.message || e);
      sendEvent({ type: "error", content: e.message || "Failed to get AI response" });
      res.end();
    }
  }
);

// =============================================================================
// GPX Compilation — compiles individual GPX files into lightweight JSON
// =============================================================================
// Triggered when a .gpx file is uploaded or deleted in the Distribution folder.
// Compiles all GPX files in the same folder into two JSON summary files:
//   _compiled_tracks.json   — all track polylines with metadata
//   _compiled_waypoints.json — all waypoints
//
// The client downloads one small JSON file instead of N large GPX files.
// =============================================================================

const COMPILED_TRACKS_FILE = "_compiled_tracks.json";
const COMPILED_WAYPOINTS_FILE = "_compiled_waypoints.json";

/**
 * Parse a GPX file's bytes into tracks and waypoints with metadata.
 * Extracts: coordinates, timestamps, distance, duration.
 */
function parseGpxFile(xmlString, fileName) {
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: "@_",
    textNodeName: "#text",
    isArray: (name) => ["trk", "trkseg", "trkpt", "wpt", "rtept", "rte"].includes(name),
  });

  const doc = parser.parse(xmlString);
  const gpx = doc.gpx;
  if (!gpx) return { tracks: [], waypoints: [] };

  const tracks = [];
  const waypoints = [];

  // ── Waypoints ──
  const wpts = gpx.wpt || [];
  for (const wpt of wpts) {
    const lat = parseFloat(wpt["@_lat"]);
    const lon = parseFloat(wpt["@_lon"]);
    if (isNaN(lat) || isNaN(lon)) continue;
    const name = wpt.name || "";
    const desc = wpt.desc || "";
    waypoints.push({ name, desc, lat, lon });
  }

  // ── Tracks ──
  const trks = gpx.trk || [];
  for (let ti = 0; ti < trks.length; ti++) {
    const trk = trks[ti];
    const trkName = trk.name || "";
    const trkDesc = trk.desc || "";
    const segs = trk.trkseg || [];

    for (let si = 0; si < segs.length; si++) {
      const seg = segs[si];
      const pts = seg.trkpt || [];
      if (pts.length < 2) continue;

      const coords = [];
      const times = [];

      for (const pt of pts) {
        const lat = parseFloat(pt["@_lat"]);
        const lon = parseFloat(pt["@_lon"]);
        if (isNaN(lat) || isNaN(lon)) continue;
        coords.push([lat, lon]);
        if (pt.time) {
          times.push(new Date(pt.time).getTime());
        }
      }

      if (coords.length < 2) continue;

      // Calculate distance (Haversine)
      let distanceMeters = 0;
      for (let i = 0; i < coords.length - 1; i++) {
        distanceMeters += haversine(coords[i][0], coords[i][1], coords[i + 1][0], coords[i + 1][1]);
      }

      // Time metadata
      const validTimes = times.filter((t) => !isNaN(t));
      const startTime = validTimes.length > 0 ? Math.min(...validTimes) : null;
      const endTime = validTimes.length > 0 ? Math.max(...validTimes) : null;
      const durationMs = startTime && endTime ? endTime - startTime : null;

      const segName = trkName || `Track ${ti + 1}`;
      const name = segs.length > 1 ? `${segName} (seg ${si + 1})` : segName;

      tracks.push({
        name,
        desc: trkDesc,
        file: fileName,
        points: coords,
        distanceMeters: Math.round(distanceMeters),
        startTime,
        endTime,
        durationMs,
      });
    }
  }

  // ── Routes (rte > rtept) ──
  const rtes = gpx.rte || [];
  for (let ri = 0; ri < rtes.length; ri++) {
    const rte = rtes[ri];
    const rteName = rte.name || `Route ${ri + 1}`;
    const rteDesc = rte.desc || "";
    const pts = rte.rtept || [];

    const coords = [];
    for (const pt of pts) {
      const lat = parseFloat(pt["@_lat"]);
      const lon = parseFloat(pt["@_lon"]);
      if (isNaN(lat) || isNaN(lon)) continue;
      coords.push([lat, lon]);
    }
    if (coords.length < 2) continue;

    let distanceMeters = 0;
    for (let i = 0; i < coords.length - 1; i++) {
      distanceMeters += haversine(coords[i][0], coords[i][1], coords[i + 1][0], coords[i + 1][1]);
    }

    tracks.push({
      name: rteName,
      desc: rteDesc,
      file: fileName,
      points: coords,
      distanceMeters: Math.round(distanceMeters),
      startTime: null,
      endTime: null,
      durationMs: null,
    });
  }

  return { tracks, waypoints };
}

/** Haversine distance in meters */
function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.asin(Math.sqrt(a));
}

/**
 * Compile all GPX files in a folder into summary JSON files.
 * Called by the Storage triggers.
 */
async function compileGpxFolder(folderPath) {
  const sw = Date.now();
  console.log(`[compileGpx] START folder=${folderPath}`);

  const bucket = getBucket();

  // List all files in the folder
  const [files] = await bucket.getFiles({ prefix: folderPath + "/" });
  const gpxFiles = files.filter(
    (f) => f.name.toLowerCase().endsWith(".gpx") && !f.name.startsWith("_compiled")
  );

  console.log(`[compileGpx] Found ${gpxFiles.length} GPX files in ${Date.now() - sw}ms`);

  if (gpxFiles.length === 0) {
    // Clean up compiled files if no GPX files remain
    try { await bucket.file(`${folderPath}/${COMPILED_TRACKS_FILE}`).delete(); } catch (_) {}
    try { await bucket.file(`${folderPath}/${COMPILED_WAYPOINTS_FILE}`).delete(); } catch (_) {}
    console.log(`[compileGpx] No GPX files — removed compiled files`);
    return;
  }

  // Download and parse all GPX files in parallel
  const allTracks = [];
  const allWaypoints = [];
  let totalBytes = 0;

  const parseResults = await Promise.allSettled(
    gpxFiles.map(async (file) => {
      const [buf] = await file.download();
      totalBytes += buf.length;
      const xmlString = buf.toString("utf-8");
      return { fileName: file.name.split("/").pop(), ...parseGpxFile(xmlString, file.name.split("/").pop()) };
    })
  );

  for (const r of parseResults) {
    if (r.status === "fulfilled") {
      allTracks.push(...r.value.tracks);
      allWaypoints.push(...r.value.waypoints);
    } else {
      console.warn(`[compileGpx] Failed to parse file: ${r.reason}`);
    }
  }

  console.log(`[compileGpx] Parsed ${gpxFiles.length} files (${(totalBytes / 1024).toFixed(1)}KB) → ${allTracks.length} tracks, ${allWaypoints.length} waypoints in ${Date.now() - sw}ms`);

  // Write compiled tracks JSON
  const tracksJson = JSON.stringify({
    version: 1,
    compiledAt: new Date().toISOString(),
    fileCount: gpxFiles.length,
    trackCount: allTracks.length,
    waypointCount: allWaypoints.length,
    tracks: allTracks,
  });

  await bucket.file(`${folderPath}/${COMPILED_TRACKS_FILE}`).save(tracksJson, {
    contentType: "application/json",
    metadata: { cacheControl: "public, max-age=300" },
  });

  // Write compiled waypoints JSON
  const waypointsJson = JSON.stringify({
    version: 1,
    compiledAt: new Date().toISOString(),
    fileCount: gpxFiles.length,
    waypointCount: allWaypoints.length,
    waypoints: allWaypoints,
  });

  await bucket.file(`${folderPath}/${COMPILED_WAYPOINTS_FILE}`).save(waypointsJson, {
    contentType: "application/json",
    metadata: { cacheControl: "public, max-age=300" },
  });

  const tracksKB = (tracksJson.length / 1024).toFixed(1);
  const waypointsKB = (waypointsJson.length / 1024).toFixed(1);
  console.log(`[compileGpx] DONE in ${Date.now() - sw}ms — tracks: ${tracksKB}KB, waypoints: ${waypointsKB}KB`);
}

/**
 * Extract the parent folder path from a file path.
 * e.g. "Distribution/2026/Mar 2026/Jo Lombard/track.gpx" → "Distribution/2026/Mar 2026/Jo Lombard"
 */
function getParentFolder(filePath) {
  const parts = filePath.split("/");
  parts.pop(); // remove filename
  return parts.join("/");
}

// Triggered when a GPX file is uploaded/updated in Storage
exports.compileGpxOnUpload = onObjectFinalized(
  { region: "us-central1" },
  async (event) => {
    const filePath = event.data.name;
    if (!filePath.toLowerCase().endsWith(".gpx")) return;
    if (filePath.includes("_compiled_")) return; // skip our own output

    const folder = getParentFolder(filePath);
    console.log(`[compileGpxOnUpload] Triggered by: ${filePath}`);
    await compileGpxFolder(folder);
  }
);

// Triggered when a GPX file is deleted from Storage
exports.compileGpxOnDelete = onObjectDeleted(
  { region: "us-central1" },
  async (event) => {
    const filePath = event.data.name;
    if (!filePath.toLowerCase().endsWith(".gpx")) return;
    if (filePath.includes("_compiled_")) return;

    const folder = getParentFolder(filePath);
    console.log(`[compileGpxOnDelete] Triggered by deletion of: ${filePath}`);
    await compileGpxFolder(folder);
  }
);

// Callable function to manually trigger compilation for a folder
exports.compileGpxFolder = onCall(
  { region: "us-central1" },
  async (request) => {
    const folderPath = request.data.folderPath;
    if (!folderPath || typeof folderPath !== "string") {
      throw new HttpsError("invalid-argument", "folderPath is required");
    }
    await compileGpxFolder(folderPath);
    return { success: true };
  }
);
