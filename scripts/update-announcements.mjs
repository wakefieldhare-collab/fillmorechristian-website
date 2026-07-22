import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const checkOnly = args.includes("--check");
const configArgument = args.find((argument) => argument !== "--check");

if (!configArgument) {
  throw new Error("Usage: node scripts/update-announcements.mjs <service-config.json> [--check]");
}

const configPath = path.resolve(configArgument);
const config = JSON.parse(await readFile(configPath, "utf8"));

if (!/^\d{4}-\d{2}-\d{2}$/.test(config.service_date || "")) {
  throw new Error("service-config.json must contain service_date in YYYY-MM-DD format.");
}

if (!Array.isArray(config.announcements) || config.announcements.length === 0) {
  throw new Error("No announcements are ready to publish. Add at least one confirmed announcement.");
}

const announcements = config.announcements.map((announcement, index) => {
  if (!announcement || typeof announcement !== "object" || Array.isArray(announcement)) {
    throw new Error(`Announcement ${index + 1} must use the structured website announcement format.`);
  }

  const status = String(announcement.status || "").trim().toLowerCase();
  if (status !== "confirmed") {
    throw new Error(`Announcement ${index + 1} (${announcement.title || "untitled"}) is not confirmed.`);
  }

  const normalized = {
    title: String(announcement.title || "").trim(),
    when: String(announcement.when || "").trim(),
    details: String(announcement.details || "").trim()
  };

  if (!normalized.title || !normalized.when || !normalized.details) {
    throw new Error(`Announcement ${index + 1} must include title, when, and details.`);
  }

  const location = String(announcement.location || "").trim();
  if (location) {
    normalized.location = location;
  }

  const url = String(announcement.url || "").trim();
  const linkLabel = String(announcement.link_label || "").trim();
  if (url) {
    let parsedUrl;
    try {
      parsedUrl = new URL(url);
    } catch {
      throw new Error(`Announcement ${index + 1} has an invalid website URL.`);
    }
    if (parsedUrl.protocol !== "https:") {
      throw new Error(`Announcement ${index + 1} website URL must use HTTPS.`);
    }
    normalized.url = parsedUrl.href;
    normalized.link_label = linkLabel || "Learn more";
  } else if (linkLabel) {
    throw new Error(`Announcement ${index + 1} has link_label without a website URL.`);
  }

  return normalized;
});

const today = new Intl.DateTimeFormat("en-CA", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  timeZone: "America/Chicago"
}).format(new Date());

const output = {
  schema_version: 1,
  service_date: config.service_date,
  updated_at: today,
  announcements
};

if (checkOnly) {
  console.log(`Validated ${announcements.length} confirmed announcements for ${config.service_date}.`);
} else {
  const outputPath = path.join(root, "announcements.json");
  await writeFile(outputPath, JSON.stringify(output, null, 2) + "\n", "utf8");
  console.log(`Updated ${path.relative(root, outputPath)} with ${announcements.length} announcements for ${config.service_date}.`);
}
