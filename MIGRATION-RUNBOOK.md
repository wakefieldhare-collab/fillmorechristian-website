# Fillmore Christian Website Migration Runbook

Last updated: 2026-06-01

## Current Facts

- Domain: `fillmorechristian.org`
- Current registrar/DNS account: Squarespace Domains / former Google Domains
- Current nameservers: `ns-cloud-d1.googledomains.com` through `ns-cloud-d4.googledomains.com`
- Current website host: TheChurchCo / WordPress
- Current `www` target: `ssl.thechurchco.com`
- Current mail MX records: `mxa.mailgun.org` and `mxb.mailgun.org`
- Squarespace renewal notice: auto-renew on 2026-06-15 for $15.00; disable by 2026-06-14 only if the transfer is already safely underway or complete.
- Current Apple Podcasts feed URL: `https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast`
- GitHub source repo for Cloudflare Pages: `https://github.com/wakefieldhare-collab/fillmorechristian-website`
- Source of truth: GitHub `main` branch in the repo above. Use `git log -1 --oneline` for the latest pushed commit.

## Migration Order

1. Export the podcast feed and audio before canceling TheChurchCo.
2. Deploy this static site to Cloudflare Pages.
3. Add `fillmorechristian.org` to Cloudflare DNS and import/verify existing DNS records.
4. Point Squarespace nameservers to Cloudflare nameservers so Cloudflare DNS becomes active.
5. Verify `www`, apex, email MX, contact form, and the legacy podcast feed URL.
6. After DNS is stable, transfer registrar from Squarespace to Cloudflare Registrar.
7. Only cancel TheChurchCo after the website and podcast feed are verified from the new host.

## Podcast Export

Run from this folder:

```powershell
.\scripts\export-thechurchco-podcast.ps1 -DownloadAudio
```

The script writes:

- `podcast-category/fillmore-christian/feed/podcast` so the legacy Apple Podcasts feed URL still works on Cloudflare Pages.
- `podcast.xml` as a readable feed copy.
- `exports/thechurchco-podcast/manifest.csv` with episode metadata.
- `exports/thechurchco-podcast/audio/` with downloaded MP3 backups when `-DownloadAudio` is used.

Do not cancel TheChurchCo until the audio files are backed up and a permanent podcast-hosting decision is made. The copied feed currently keeps enclosure URLs pointed at TheChurchCo's S3-hosted MP3 files; those may stop working after cancellation.

Export status on 2026-06-01:

- Feed items: 73
- Unique downloaded audio files: 70
- Audio backup size: about 2.16 GB
- Two feed items currently have no audio enclosure in ChurchCo.
- Two July 2023 feed items point to the same MP3, so only one local file was downloaded for that shared enclosure.
- Backup folder: `exports/thechurchco-podcast/audio/`
- Download verification inventory: `exports/thechurchco-podcast/audio-inventory.csv` with SHA-256 hashes for the 70 local audio files.

## Podcast Independence Plan

Current state is safe for cutover but not safe for canceling TheChurchCo:

- The RSS feed is preserved locally and will continue to publish from `www.fillmorechristian.org`.
- The historical MP3 files are backed up locally and hash-inventoried.
- The live feed enclosures still point to TheChurchCo's S3 URLs, so audio could break if TheChurchCo removes those files after cancellation.

Before canceling TheChurchCo, choose and complete one of these:

1. **Cloudflare R2 audio hosting:** upload `exports/thechurchco-podcast/audio/` to R2, put it behind a public hostname such as `media.fillmorechristian.org`, then rewrite RSS enclosure URLs to that hostname.
2. **Podcast-host import:** import the preserved RSS feed into a dedicated podcast host, verify all audio imported, then add `<itunes:new-feed-url>` and redirects per Apple Podcasts guidance.

Cloudflare R2 keeps the church infrastructure under the same Cloudflare account as the website and domain, so it is the cleanest ownership model if the church is comfortable with low-cost object storage.

Prepared scripts for the R2 path:

```powershell
# After `wrangler login` and R2 bucket creation:
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons

# After the bucket is reachable through a public hostname:
.\scripts\rewrite-podcast-audio-urls.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
```

After rewriting enclosure URLs, re-run local verification and push the RSS changes before canceling TheChurchCo.

## Public Staging Deployment

GitHub Pages staging is enabled from `main`:

- URL: `https://wakefieldhare-collab.github.io/fillmorechristian-website/`
- Purpose: public preview and QA before Cloudflare authorization.
- Limitation: Cloudflare `_redirects` and `_headers` are not honored by GitHub Pages. Treat this as staging only, not final production.

## Preflight Checks

Run the readiness check before any production DNS or podcast cutover:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1
```

The expected pre-R2 result is all checks passing with one warning: podcast audio enclosures still point at TheChurchCo. After R2 audio rewrite, run the stricter form:

```powershell
.\scripts\test-migration-readiness.ps1 -RequireIndependentAudio
```

To verify the 2.16 GB local audio backup hashes before cancellation:

```powershell
.\scripts\test-migration-readiness.ps1 -VerifyAudioHashes
```

## Cloudflare Pages Status

The repo is ready for a Cloudflare Pages static deployment. Use:

- Build command: `npm run build`
- Build output directory: `dist`
- Production branch: `main`

The build copies only public website assets into `dist` so migration notes, scripts, and export artifacts are not published as part of the production site.

`wrangler` is installed locally, but it was not authenticated on 2026-06-01. Run `wrangler login` or connect the GitHub repo through the Cloudflare dashboard before deployment.

## Cloudflare DNS Records To Preserve

Before changing nameservers, screenshot/export all current Squarespace DNS records. At minimum preserve:

- MX: `@` -> `mxa.mailgun.org`, priority 10
- MX: `@` -> `mxb.mailgun.org`, priority 10
- Any TXT records for SPF, DKIM, DMARC, domain verification, or Mailgun

For Cloudflare Pages, use the Pages custom-domain instructions generated by Cloudflare. Typically:

- `www` -> Cloudflare Pages custom domain target
- Apex `fillmorechristian.org` -> Cloudflare Pages apex custom domain setup

Current public DNS can be snapshotted with:

```powershell
.\scripts\export-dns-snapshot.ps1
```

Latest snapshot on 2026-06-01 found:

- NS: `ns-cloud-d1.googledomains.com` through `ns-cloud-d4.googledomains.com`
- A: `fillmorechristian.org` -> `77.83.141.16`
- CNAME: `www.fillmorechristian.org` -> `ssl.thechurchco.com`
- MX: `fillmorechristian.org` -> `mxa.mailgun.org`, priority 10
- MX: `fillmorechristian.org` -> `mxb.mailgun.org`, priority 10
- TXT: `v=spf1 include:mailgun.org ~all`
- TXT: `MS=ms48673064`

## Registrar Transfer To Cloudflare

Cloudflare requires the domain to be active on Cloudflare DNS before transferring registration. After DNS is active:

1. In Squarespace Domains, confirm DNSSEC is disabled.
2. Unlock `fillmorechristian.org`.
3. Request the transfer/auth/EPP code.
4. In Cloudflare Registrar, start the transfer and enter the auth code.
5. Keep the Squarespace account active until the registrar transfer completes.

## Verification Checklist

- `https://www.fillmorechristian.org/` loads the static site.
- `https://fillmorechristian.org/` redirects or loads correctly.
- `https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast` returns RSS XML.
- Sermons page shows podcast episodes.
- A known MP3 enclosure from the feed downloads or plays.
- `church@fillmorechristian.org` still receives mail.
- Contact form destination is configured and tested.
- Give link still points to `https://givebutter.com/fillmorechristian`.
