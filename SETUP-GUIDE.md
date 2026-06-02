# Fillmore Christian Church Website - Setup Guide

## Overview

Static website for Fillmore Christian Church, replacing ChurchCo ($50/mo). Built with plain HTML, CSS, and JavaScript. Host on Cloudflare Pages so the domain, DNS, and static site can live together at Cloudflare.

## What's Already Done

- [x] Website built (all pages, CSS, JS)
- [x] Team photos pulled from ChurchCo (images/ folder)
- [x] Giving link set to https://givebutter.com/fillmorechristian
- [x] Beliefs page written from FCC Constitution & Bylaws
- [x] Podcast feed export tooling added in `scripts/export-thechurchco-podcast.ps1`
- [x] Legacy Apple Podcasts feed path preserved at `podcast-category/fillmore-christian/feed/podcast`
- [x] Legacy WordPress-style podcast query links preserved with a Cloudflare Pages Function
- [x] Self-hosted favicon and web app manifest added for owned browser/app branding
- [x] Cloudflare Pages `_headers` and `_redirects` files added
- [x] Cloudflare build output prepared with `npm run build` -> `dist`
- [x] Migration preflight script added at `scripts/test-migration-readiness.ps1`
- [x] Podcast RSS feed exported and normalized into the static site
- [x] 70 unique sermon audio files backed up locally with SHA-256 inventory
- [x] R2 audio manifest prepared for `https://www.fillmorechristian.org/media`
- [x] R2 enabled, bucket `fillmore-christian-sermons` created, and all 70 audio objects uploaded and SHA-256 verified
- [x] GitHub Pages staging deployment enabled from the personal repo
- [x] Cloudflare Pages project created and deployed at `https://fillmorechristian-website.pages.dev/`
- [x] DNS preserve/import artifacts prepared for Cloudflare cutover
- [x] Cloudflare DNS records applied and API-verified for Pages, mail, SPF, DMARC, DKIM, and verification records
- [x] Project files in `C:\Users\wakef\Documents\AI-Projects\fcc-website`

See `MIGRATION-RUNBOOK.md` for the current Cloudflare migration order.

For a quick read-only snapshot of the migration state, run:

```powershell
npm run status:migration
```

## What's Left

### Step 1: Keep The Sermon Audio Backup Safe

This was the first critical task because it becomes impossible once ChurchCo access is canceled. It is already done as of June 1, 2026, and the same 70 files have been uploaded to Cloudflare R2 and hash-verified. Keep the local backup until the public R2 hostname and production feed have both been verified.

Current local backup status:

- Feed items exported: 73
- Items with audio enclosures: 71
- Unique downloaded audio files: 70
- Local backup folder: `exports/thechurchco-podcast/audio/`
- Inventory file: `exports/thechurchco-podcast/audio-inventory.csv`
- R2 upload manifest: `exports/thechurchco-podcast/r2-audio-manifest.csv`

Before canceling TheChurchCo, verify the backup again:

```powershell
.\scripts\test-migration-readiness.ps1 -VerifyAudioHashes
```

### Step 2: Set Up Podcast Hosting

#### Short-Term: Preserve The Current Feed URL

Apple Podcasts currently uses:

```text
https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast
```

The static site now serves that same path, so subscribers do not need a redirect immediately after DNS cutover.

The archive also includes generated static pages for every feed item under `/episode/.../`, so old ChurchCo sermon links can land on a specific message page with its own audio player.

Older podcast GUID/query links such as `/?post_type=podcasts&p=603` are preserved by the generated `functions/index.js` Cloudflare Pages Function and `_routes.json`.

#### Long-Term: FCC-Owned Audio Hosting

The permanent audio-hosting path is now Cloudflare R2 plus the FCC-owned feed URL. The copied feed has been rewritten so all current audio enclosures use:

```text
https://www.fillmorechristian.org/media/<object-key>
```

Cloudflare Pages serves those URLs through a `/media/<object-key>` Pages Function backed by the `SERMON_AUDIO` R2 bucket binding. The same route is already verifiable on the Pages preview domain before DNS cutover.

If the feed URL changes, add an `<itunes:new-feed-url>` tag and a 301 redirect from the current feed URL to the new feed URL for at least four weeks.

Cloudflare R2 preparation scripts are included. The manifest and dry runs are safe before Cloudflare authorization:

```powershell
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://www.fillmorechristian.org/media"
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons -DryRun
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -DryRun
```

The real upload and R2 hash verification were completed on June 1, 2026:

```powershell
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -SampleCount 5
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -VerifyHashes
```

The Cloudflare Pages project binds the R2 bucket as `SERMON_AUDIO` and serves audio at `/media/<object-key>`. After DNS cutover makes `www.fillmorechristian.org` point to Cloudflare Pages, run the public checks:

```powershell
npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia
.\scripts\test-r2-public-audio.ps1 -All
.\scripts\test-podcast-media.ps1 -All
```

The safer post-login path is the wrapper command:

```powershell
npm run migrate:cloudflare-audio -- -DryRun
npm run migrate:cloudflare-audio -- -SkipUpload -VerifyAllPublicMedia
```

It keeps the same personal GitHub owner guard as the deploy script, uploads and verifies the R2 audio backup, rewrites the RSS feeds to the owned Pages media route, regenerates sermon pages, builds `dist`, and runs strict local checks.

The manifest, upload dry run, and R2 verifier dry run are safe before Cloudflare authorization. The real R2 upload is complete; the Cloudflare Pages deployment now carries the R2 binding and feed rewrite, but production cancellation still waits for DNS cutover and `scripts\test-r2-public-audio.ps1 -All`.

### Step 3: Deploy Website To Cloudflare Pages

1. Keep the source repo under the personal GitHub owner `wakefieldhare-collab`, not the work account `wake-byte`.
2. In Cloudflare Pages, create a project from `wakefieldhare-collab/fillmorechristian-website`.
3. Use `npm run build` as the build command and `dist` as the output directory.
4. Add custom domains for `www.fillmorechristian.org` and `fillmorechristian.org`.
5. Keep `_headers`, `_redirects`, and `_routes.json` in the published output.

Before deploying, run:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1
.\scripts\test-cloudflare-pages-local.ps1
```

The readiness script fails if the Git remote or active GitHub CLI account points at `wake-byte`, and it requires the independent R2-backed podcast audio route.

After Cloudflare authorization, deploy with the guarded command:

```powershell
npm run deploy:cloudflare
```

It builds, verifies readiness, runs the local Cloudflare Pages preflight, checks the personal GitHub remote, and then deploys `dist` to the `fillmorechristian-website` Cloudflare Pages project.

After the R2 audio wrapper rewrites feeds/pages, commit and push those changes to the personal GitHub repo before deploying.

To verify R2 audio on the current Cloudflare Pages preview before DNS cutover:

```powershell
npm run verify:r2-pages-audio
```

To spot-check current or rewritten podcast audio URLs:

```powershell
.\scripts\test-podcast-media.ps1 -SampleCount 5
```

### Step 4: Contact Form

The contact forms currently create a prefilled email to `church@fillmorechristian.org` using the visitor's mail app. This avoids a broken placeholder form while the site is moving.

The site also publishes `contact.vcf`, a self-hosted contact card with the church email and address. The Contact page links it directly.

Later, the form can be upgraded to Cloudflare Pages Functions, Formspree, or another form service after the church chooses where form submissions should be stored and who should receive notifications.

### Step 5: Maintain Events

The site publishes a self-hosted recurring Sunday calendar at `events.ics` for Sunday School and Sunday Worship. The Events page links it directly, the homepage and Events page include a clear static recurring-Sunday fallback, and `js/events.js` expands the iCal feed into upcoming dated occurrences in the browser.

For ordinary schedule changes, edit `events.ics`, then keep the static fallback copy in `index.html`, `events.html`, and `js/events.js` aligned with the feed. The build/readiness checks verify that the self-hosted feed ships with the public site and that no Google Calendar API key is required.

### Step 6: Move DNS To Cloudflare

Domain registrar: Squarespace Domains, formerly Google Domains.

- Login: https://domains.squarespace.com
- Domain: `fillmorechristian.org`
- Renewal notice: auto-renews June 15, 2026 for $15.00; disable by June 14 only if transfer/cutover is safe.
- Current blocker: `fillmorechristian.org` is added to Cloudflare DNS and the Cloudflare DNS records are prepared. Update Squarespace nameservers to `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`. The podcast feed has moved off TheChurchCo audio in the Cloudflare Pages build; public audio verification waits for DNS to point `www.fillmorechristian.org` at Pages.

DNS changes needed:

1. In Cloudflare DNS for `fillmorechristian.org`, the preserve records have already been applied and API-verified, including Mailgun MX/TXT records, `_dmarc` DMARC, `pic._domainkey` DKIM, and Google verification CNAMEs.
2. The old TheChurchCo web records have already been removed inside Cloudflare and replaced with proxied Pages CNAMEs.
3. In Squarespace, update the domain nameservers to `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`.
4. In Cloudflare Pages, confirm custom domains for `www` and apex become active.
5. Verify email still works before changing or deleting any mail records.
6. After Cloudflare DNS is active, verify public audio through `https://www.fillmorechristian.org/media/...`.
7. After production website/feed/media are verified, transfer the registrar from Squarespace to Cloudflare Registrar.

Current public DNS can be snapshotted with:

```powershell
.\scripts\export-dns-snapshot.ps1
```

Then build the Cloudflare import/preserve files and verify the current pre-cutover state:

```powershell
.\scripts\build-cloudflare-dns-plan.ps1
.\scripts\test-cloudflare-dns-import-readiness.ps1
.\scripts\test-dns-cutover.ps1 -Mode Before
```

Preview the Cloudflare DNS records to keep and replace:

```powershell
npm run apply:cloudflare-dns
```

The Cloudflare API apply has already been run. If the record set ever needs to be re-applied, create a token at `https://dash.cloudflare.com/profile/api-tokens` with Zone:Read and Zone:DNS Edit permission for `fillmorechristian.org`, then set `CLOUDFLARE_API_TOKEN` or `CF_API_TOKEN`:

```powershell
npm run apply:cloudflare-dns -- -Apply
```

After DNS cutover and the production cancellation checks pass, revoke any temporary Cloudflare API token created or shared for the migration.

The preferred final verifier is:

```powershell
npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia
```

It runs the Cloudflare cutover, Cloudflare Registrar safety, and TheChurchCo cancellation checks in sequence, verifies both the `www` and apex production URLs, then writes a non-secret report under `exports/cutover/`.

As of June 1, 2026, preserve at least the Mailgun MX records and these TXT/CNAME records:

- `v=spf1 include:mailgun.org ~all`
- `MS=ms48673064`
- `_dmarc` TXT: `v=DMARC1; p=none; rua=mailto:church@fillmorechristian.org`
- `pic._domainkey` TXT DKIM
- `cbsw2pw4sdud` CNAME -> `gv-6xwzpofnvqguxs.dv.googlehosted.com`
- `4jb3ni34htue` CNAME -> `gv-xvljhthdwk5dxh.dv.googlehosted.com`
- `334xc4sml6cf` CNAME -> `gv-ujhethalu73pqt.dv.googlehosted.com`

Do not disable/cancel TheChurchCo until Cloudflare nameservers are active and the production website/feed/audio cancellation checks pass.

### Step 7: Maintain Church Logo

The official FCC navigation logo is published at `images/fcc-logo.png` and is checked by the local Pages verifier. Keep that file as the navigation logo source unless the church intentionally replaces it with a newer official mark.

## Updating Content

### Adding A New Sermon

- Add the audio file to durable hosting.
- Add a new `<item>` entry in `podcast.xml` and in `podcast-category/fillmore-christian/feed/podcast`.
- Run `npm run refresh:podcast-content`.
- Keep the sermons page pointed at the podcast feed in `js/sermons.js`.

### Adding Or Editing Events

- Edit `events.ics` for recurring or dated events.
- Keep the visible static fallback schedule in `index.html`, `events.html`, and `js/events.js` aligned with the iCal feed.
- Run `npm run build`, `scripts\test-migration-readiness.ps1 -RequireIndependentAudio`, and `scripts\test-cloudflare-pages-local.ps1` before deploying.

### Editing Page Content

- Open any `.html` file and modify the text directly.
- No build step needed; save, commit, and push.

## Monthly Cost

- Website hosting: free on Cloudflare Pages.
- Contact form: currently mailto-based, with no third-party form service.
- Calendar: self-hosted `events.ics` feed.
- Domain renewal: Cloudflare Registrar at-cost after transfer.
- Podcast hosting: Cloudflare R2 storage plus the FCC-owned Pages `/media` route.
