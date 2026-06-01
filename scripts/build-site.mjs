import { cp, mkdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(root, "dist");

const publishPaths = [
  "404.html",
  "about.html",
  "beliefs.html",
  "contact.html",
  "events.html",
  "feed.xml",
  "index.html",
  "podcast.xml",
  "robots.txt",
  "sermons.html",
  "sitemap.xml",
  "team.html",
  "_headers",
  "_redirects",
  "css",
  "images",
  "js",
  "podcast-category"
];

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

for (const relativePath of publishPaths) {
  const source = path.join(root, relativePath);
  if (!existsSync(source)) {
    throw new Error(`Missing publish path: ${relativePath}`);
  }

  await cp(source, path.join(outDir, relativePath), {
    recursive: true,
    force: true
  });
}

console.log(`Built ${publishPaths.length} publish paths into ${path.relative(root, outDir)}`);
