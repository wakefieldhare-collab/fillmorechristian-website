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

### Step 3: Deploy Website To Cloudflare Pages

1. Put this folder in a GitHub repo.
2. In Cloudflare Pages, create a project from that repo.
3. Use no build command and the repo root as the output directory.
4. Add custom domains for `www.fillmorechristian.org` and `fillmorechristian.org`.
5. Keep `_headers` and `_redirects` in the published output.

### Step 4: Set Up Contact Form

The contact form uses Formspree (free tier: 50 submissions/month):

1. Go to https://formspree.io and create a free account.
2. Create a new form and copy the form ID.
3. In `index.html` and `contact.html`, replace `YOUR_FORM_ID` in the form action URL.

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
6. Optionally, uncomment the iframe in `events.html` and replace `CALENDAR_ID`.

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
- Keep the sermons page pointed at the podcast feed in `js/sermons.js`.

### Adding Or Editing Events

- Add events to the Google Calendar; the website pulls them automatically once configured.

### Editing Page Content

- Open any `.html` file and modify the text directly.
- No build step needed; save, commit, and push.

## Monthly Cost

- Website hosting: free on Cloudflare Pages.
- Contact form: free on Formspree up to its current free-tier limit.
- Calendar: free on Google Calendar.
- Domain renewal: Cloudflare Registrar at-cost after transfer.
- Podcast hosting: depends on final host choice; do not rely on TheChurchCo-hosted MP3s after cancellation.

