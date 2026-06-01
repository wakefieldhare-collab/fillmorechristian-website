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
- [x] Cloudflare Pages `_headers` and `_redirects` files added
- [x] Cloudflare build output prepared with `npm run build` -> `dist`
- [x] Migration preflight script added at `scripts/test-migration-readiness.ps1`
- [x] Project files in `C:\Users\wakef\Documents\AI-Projects\fcc-website`

See `MIGRATION-RUNBOOK.md` for the current Cloudflare migration order.

## What's Left

### Step 1: Export Sermon Audio from ChurchCo (DO FIRST)

This becomes impossible once you cancel ChurchCo.

1. Run the export script from this folder:

   ```powershell
   .\scripts\export-thechurchco-podcast.ps1 -DownloadAudio
   ```

2. Confirm the feed and manifest were written:
   - `podcast-category/fillmore-christian/feed/podcast`
   - `podcast.xml`
   - `exports/thechurchco-podcast/manifest.csv`
   - `exports/thechurchco-podcast/audio/`

3. Keep this backup before canceling TheChurchCo.

### Step 2: Set Up Podcast Hosting

#### Short-Term: Preserve The Current Feed URL

Apple Podcasts currently uses:

```text
https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast
```

The static site now serves that same path, so subscribers do not need a redirect immediately after DNS cutover.

#### Long-Term: Pick Permanent Audio Hosting

The copied feed still points to TheChurchCo-hosted MP3 files. Before canceling TheChurchCo, either:

1. Import the show into a podcast host such as Spotify for Creators, then use its RSS feed going forward, or
2. Move the MP3 files to durable storage/CDN and update the copied feed enclosure URLs.

If the feed URL changes, add an `<itunes:new-feed-url>` tag and a 301 redirect from the current feed URL to the new feed URL for at least four weeks.

Cloudflare R2 preparation scripts are included:

```powershell
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons -DryRun
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons
.\scripts\rewrite-podcast-audio-urls.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
.\scripts\test-podcast-media.ps1 -All
```

The manifest and dry run are safe before Cloudflare authorization. Run the real upload and feed rewrite only after Cloudflare authorization, R2 bucket creation, and public media hostname setup.

### Step 3: Deploy Website To Cloudflare Pages

1. Put this folder in a GitHub repo.
2. In Cloudflare Pages, create a project from that repo.
3. Use `npm run build` as the build command and `dist` as the output directory.
4. Add custom domains for `www.fillmorechristian.org` and `fillmorechristian.org`.
5. Keep `_headers` and `_redirects` in the published output.

Before deploying, run:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1
```

The only expected warning before R2 setup is that the podcast audio enclosures still point at TheChurchCo.

To spot-check current or rewritten podcast audio URLs:

```powershell
.\scripts\test-podcast-media.ps1 -SampleCount 5
```

### Step 4: Contact Form

The contact forms currently create a prefilled email to `church@fillmorechristian.org` using the visitor's mail app. This avoids a broken placeholder form while the site is moving.

Later, the form can be upgraded to Cloudflare Pages Functions, Formspree, or another form service after the church chooses where form submissions should be stored and who should receive notifications.

### Step 5: Set Up Google Calendar (Events)

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

DNS changes needed:

1. Add `fillmorechristian.org` as a site in Cloudflare.
2. Import/screenshot every current Squarespace DNS record first, especially Mailgun MX/TXT records.
3. In Squarespace, update the domain nameservers to Cloudflare's assigned nameservers.
4. In Cloudflare Pages, finish the custom domain setup for `www` and apex.
5. Verify email still works before changing or deleting any mail records.
6. After Cloudflare DNS is active, transfer the registrar from Squarespace to Cloudflare Registrar.

Current public DNS can be snapshotted with:

```powershell
.\scripts\export-dns-snapshot.ps1
```

Then build the Cloudflare import/preserve files and verify the current pre-cutover state:

```powershell
.\scripts\build-cloudflare-dns-plan.ps1
.\scripts\test-dns-cutover.ps1 -Mode Before
```

As of June 1, 2026, preserve at least the Mailgun MX records and these TXT records:

- `v=spf1 include:mailgun.org ~all`
- `MS=ms48673064`

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
- Run `.\scripts\normalize-podcast-metadata.ps1` and `.\scripts\render-static-sermons.ps1`.
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
