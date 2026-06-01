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
- [x] R2 audio manifest prepared for `https://media.fillmorechristian.org`
- [x] R2 enabled, bucket `fillmore-christian-sermons` created, and all 70 audio objects uploaded and SHA-256 verified
- [x] GitHub Pages staging deployment enabled from the personal repo
- [x] Cloudflare Pages project created and deployed at `https://fillmorechristian-website.pages.dev/`
- [x] DNS preserve/import artifacts prepared for Cloudflare cutover
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

#### Long-Term: Pick Permanent Audio Hosting

The copied feed still points to TheChurchCo-hosted MP3 files. Before canceling TheChurchCo, either:

1. Import the show into a podcast host such as Spotify for Creators, then use its RSS feed going forward, or
2. Move the MP3 files to durable storage/CDN and update the copied feed enclosure URLs.

If the feed URL changes, add an `<itunes:new-feed-url>` tag and a 301 redirect from the current feed URL to the new feed URL for at least four weeks.

Cloudflare R2 preparation scripts are included. The manifest and dry runs are safe before Cloudflare authorization:

```powershell
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons -DryRun
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -DryRun
```

The real upload and R2 hash verification were completed on June 1, 2026:

```powershell
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -SampleCount 5
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -VerifyHashes
```

After `media.fillmorechristian.org` is connected to the R2 bucket and public HTTPS audio is verified, rewrite the feed and run the public checks:

```powershell
npm run complete:cloudflare-cutover
npm run configure:r2-media-domain -- -VerifyAllPublicMedia
.\scripts\test-r2-public-audio.ps1 -All
.\scripts\rewrite-podcast-audio-urls.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
.\scripts\test-podcast-media.ps1 -All
```

The safer post-login path is the wrapper command:

```powershell
npm run migrate:cloudflare-audio -- -DryRun
npm run migrate:cloudflare-audio -- -SkipUpload -VerifyAllPublicMedia
```

It keeps the same personal GitHub owner guard as the deploy script, uploads and verifies the R2 audio backup, verifies the public media hostname before rewriting the RSS feeds, regenerates sermon pages, builds `dist`, and runs strict local checks.

The manifest, upload dry run, and R2 verifier dry run are safe before Cloudflare authorization. The real R2 upload is complete; do not rewrite the RSS feed until the public media hostname is active and `scripts\test-r2-public-audio.ps1 -All` passes.

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

The only expected warning before R2 setup is that the podcast audio enclosures still point at TheChurchCo.

The readiness script also fails if the Git remote or active GitHub CLI account points at `wake-byte`.

After Cloudflare authorization, deploy with the guarded command:

```powershell
npm run deploy:cloudflare
```

It builds, verifies readiness, runs the local Cloudflare Pages preflight, checks the personal GitHub remote, and then deploys `dist` to the `fillmorechristian-website` Cloudflare Pages project.

After the R2 audio wrapper rewrites feeds/pages, commit and push those changes to the personal GitHub repo before deploying.

To spot-check current or rewritten podcast audio URLs:

```powershell
.\scripts\test-podcast-media.ps1 -SampleCount 5
```

### Step 4: Contact Form

The contact forms currently create a prefilled email to `church@fillmorechristian.org` using the visitor's mail app. This avoids a broken placeholder form while the site is moving.

The site also publishes `contact.vcf`, a self-hosted contact card with the church email and address. The Contact page links it directly.

Later, the form can be upgraded to Cloudflare Pages Functions, Formspree, or another form service after the church chooses where form submissions should be stored and who should receive notifications.

### Step 5: Set Up Google Calendar (Events)

The site already publishes a self-hosted recurring Sunday calendar at `events.ics` for Sunday School and Sunday Worship. The Events page links it directly, and the build/readiness checks verify that it ships with the public site.

1. Create a Google Calendar for the church, or use an existing one.
2. Make it public: Calendar Settings > Access permissions > Make available to public.
3. Copy the Calendar ID from Settings > Integrate calendar.
4. Get a Google API key:
   - Go to https://console.cloud.google.com.
   - Create a project, or use an existing one.
   - Enable Google Calendar API.
   - Create an API key under Credentials.
   - Restrict the key to Google Calendar API and your domain.
5. Update `js/events.js`:
   - Set `GOOGLE_CALENDAR_ID` to your calendar ID.
   - Set `GOOGLE_API_KEY` to your API key.
6. Until a calendar is connected, the site shows the built-in Sunday School and Sunday Worship schedule.

### Step 6: Move DNS To Cloudflare

Domain registrar: Squarespace Domains, formerly Google Domains.

- Login: https://domains.squarespace.com
- Domain: `fillmorechristian.org`
- Renewal notice: auto-renews June 15, 2026 for $15.00; disable by June 14 only if transfer/cutover is safe.
- Current blocker: `fillmorechristian.org` is added to Cloudflare DNS but still pending. Verify the Cloudflare DNS records, then update Squarespace nameservers to `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`. `media.fillmorechristian.org` still needs to be connected to the R2 bucket after the zone is active before the podcast feed can move off TheChurchCo audio.

DNS changes needed:

1. In Cloudflare DNS for `fillmorechristian.org`, verify/import every preserve record first, especially Mailgun MX/TXT records, `pic._domainkey` DKIM, and Google verification CNAMEs.
2. Confirm old TheChurchCo web records are not carried forward except as records to replace.
3. In Squarespace, update the domain nameservers to `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`.
4. In Cloudflare Pages, confirm custom domains for `www` and apex become active.
5. Verify email still works before changing or deleting any mail records.
6. After Cloudflare DNS is active, configure `media.fillmorechristian.org` on the R2 bucket and verify public audio.
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

As of June 1, 2026, preserve at least the Mailgun MX records and these TXT/CNAME records:

- `v=spf1 include:mailgun.org ~all`
- `MS=ms48673064`
- `pic._domainkey` TXT DKIM
- `cbsw2pw4sdud` CNAME -> `gv-6xwzpofnvqguxs.dv.googlehosted.com`
- `4jb3ni34htue` CNAME -> `gv-xvljhthdwk5dxh.dv.googlehosted.com`
- `334xc4sml6cf` CNAME -> `gv-ujhethalu73pqt.dv.googlehosted.com`

Do not delete the old TheChurchCo website records until Cloudflare Pages custom domains are configured and ready to replace them.

### Step 7: Add Church Logo (Optional)

1. Save the church logo as `images/logo.png`.
2. In the navigation on each page, add an `<img>` tag inside `.nav-brand`:

   ```html
   <a href="index.html" class="nav-brand">
     <img src="images/logo.png" alt="FCC Logo">
     <div class="nav-brand-text">...</div>
   </a>
   ```

## Updating Content

### Adding A New Sermon

- Add the audio file to durable hosting.
- Add a new `<item>` entry in `podcast.xml` and in `podcast-category/fillmore-christian/feed/podcast`.
- Run `.\scripts\normalize-podcast-metadata.ps1`, `.\scripts\render-static-episodes.ps1`, `.\scripts\render-static-sermons.ps1`, and `.\scripts\render-homepage-latest-sermon.ps1`.
- Keep the sermons page pointed at the podcast feed in `js/sermons.js`.

### Adding Or Editing Events

- Add events to the Google Calendar; the website pulls them automatically once configured.

### Editing Page Content

- Open any `.html` file and modify the text directly.
- No build step needed; save, commit, and push.

## Monthly Cost

- Website hosting: free on Cloudflare Pages.
- Contact form: currently mailto-based, with no third-party form service.
- Calendar: free on Google Calendar.
- Domain renewal: Cloudflare Registrar at-cost after transfer.
- Podcast hosting: depends on final host choice; do not rely on TheChurchCo-hosted MP3s after cancellation.
