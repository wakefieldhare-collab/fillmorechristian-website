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
  "contact.vcf",
  "events.ics",
  "events.html",
  "episode",
  "feed.xml",
  "favicon.svg",
  "index.html",
  "podcast.xml",
  "robots.txt",
  "sermons.html",
  "site.webmanifest",
  "sitemap.xml",
  "team.html",
  "_headers",
  "_routes.json",
  "_redirects",
  "css",
  "js",
  "podcast-category"
];

const publishImagePaths = [
  "andy-barnes.jpg",
  "church-exterior-1200.jpg",
  "church-exterior-1200.webp",
  "podcast-cover.jpg",
  "sanctuary-service-1200.jpg",
  "sanctuary-service-1200.webp",
  "wakefield-hare.jpg"
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

await mkdir(path.join(outDir, "images"), { recursive: true });
for (const imagePath of publishImagePaths) {
  const source = path.join(root, "images", imagePath);
  if (!existsSync(source)) {
    throw new Error(`Missing publish image: ${imagePath}`);
  }

  await cp(source, path.join(outDir, "images", imagePath), { force: true });
}

console.log(`Built ${publishPaths.length + publishImagePaths.length} publish paths into ${path.relative(root, outDir)}`);
