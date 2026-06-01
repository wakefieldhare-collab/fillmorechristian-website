# Fillmore Christian Website Migration Runbook

Last updated: 2026-06-01

## Current Facts

- Domain: `fillmorechristian.org`
- Current registrar/DNS account: Squarespace Domains / former Google Domains
- Current nameservers: `ns-cloud-d1.googledomains.com` through `ns-cloud-d4.googledomains.com`
- Current website host: TheChurchCo / WordPress
- Current `www` target: `ssl.thechurchco.com`
- Current mail MX records: `mxa.mailgun.org` and `mxb.mailgun.org`
- Squarespace renewal notice: confirmed in personal Gmail message `19e8098f6dc383a7` from Squarespace on 2026-06-01; `fillmorechristian.org` auto-renews on 2026-06-15 for $15.00. Disable auto-renew by 2026-06-14 only if the transfer is already safely underway or complete.
- Current Apple Podcasts feed URL: `https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast`
- GitHub source repo for Cloudflare Pages: `https://github.com/wakefieldhare-collab/fillmorechristian-website`
- GitHub owner guard: keep this repo under `wakefieldhare-collab`; do not move or deploy it from the work account `wake-byte`.
- Source of truth: GitHub `main` branch in the repo above. Use `git log -1 --oneline` for the latest pushed commit.
- Browser/app branding: self-hosted `favicon.svg` and `site.webmanifest` are published with the site.

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
- Podcast artwork is hosted by the static site at `https://www.fillmorechristian.org/images/podcast-cover.jpg`.
- The live feed enclosures still point to TheChurchCo's S3 URLs, so audio could break if TheChurchCo removes those files after cancellation.

Before canceling TheChurchCo, choose and complete one of these:

1. **Cloudflare R2 audio hosting:** upload `exports/thechurchco-podcast/audio/` to R2, put it behind a public hostname such as `media.fillmorechristian.org`, then rewrite RSS enclosure URLs to that hostname.
2. **Podcast-host import:** import the preserved RSS feed into a dedicated podcast host, verify all audio imported, then add `<itunes:new-feed-url>` and redirects per Apple Podcasts guidance.

Cloudflare R2 keeps the church infrastructure under the same Cloudflare account as the website and domain, so it is the cleanest ownership model if the church is comfortable with low-cost object storage.

Prepared scripts for the R2 path:

```powershell
# Build the deterministic object manifest first. This validates local files,
# inventory hashes, duplicate feed references, object keys, and public URLs.
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"

# Safe pre-auth rehearsal. This does not contact Cloudflare.
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons -DryRun

# After `wrangler login` and R2 bucket creation:
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons

# Verify R2 received the uploaded files. Use -All before canceling TheChurchCo.
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -SampleCount 5
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -VerifyHashes

# After the bucket is reachable through the public hostname:
.\scripts\rewrite-podcast-audio-urls.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
```

After Cloudflare authentication, the guarded one-command local preparation path is:

```powershell
npm run migrate:cloudflare-audio -- -DryRun

# After `npx wrangler login`, R2 bucket/custom media hostname setup, and a clean tree:
npm run migrate:cloudflare-audio -- -CreateBucket
```

The migration command refuses the work GitHub owner, requires `https://` audio URLs, verifies Cloudflare authentication, can create the R2 bucket, uploads and hash-verifies all 70 audio objects, rewrites all three RSS feeds to `https://media.fillmorechristian.org`, regenerates episode pages/sermon archive/homepage latest-sermon links, builds `dist`, and runs strict local readiness plus the Cloudflare Pages local preflight. Use `-VerifyPublicMedia` or `-VerifyPublicMedia -VerifyAllPublicMedia` after the R2 custom hostname is live.

After rewriting enclosure URLs, re-run local verification and push the RSS changes before canceling TheChurchCo.

R2 preparation status on 2026-06-01:

- `exports/thechurchco-podcast/r2-audio-manifest.csv` maps 70 local objects to 71 RSS enclosure references.
- The manifest totals 2,315,228,157 bytes and includes the intended `https://media.fillmorechristian.org/...` public URLs.
- The upload script supports `-DryRun`, uses either `wrangler` or `npx wrangler`, and reads from this manifest so the real upload follows the same object keys.
- `scripts/test-r2-audio-upload.ps1` can verify sampled or full R2 downloads against the manifest before TheChurchCo is canceled.

Podcast metadata cleanup:

```powershell
.\scripts\normalize-podcast-metadata.ps1
.\scripts\render-static-episodes.ps1
.\scripts\render-static-sermons.ps1
.\scripts\render-homepage-latest-sermon.ps1
```

This keeps old ChurchCo account author values such as `thechurchcodaniel` out of the public RSS feed and sermon archive, and it creates one static page for every feed episode so old `/episode/.../` links remain useful after the static-site cutover.

The episode renderer also writes `exports/thechurchco-podcast/legacy-podcast-redirects.csv`, `functions/index.js`, and `_routes.json`. Those preserve the older WordPress-style podcast links such as `/?post_type=podcasts&p=603` by redirecting them to the generated `/episode/.../` page when the site is deployed on Cloudflare Pages.

## Public Staging Deployment

GitHub Pages staging is enabled from `main`:

- URL: `https://wakefieldhare-collab.github.io/fillmorechristian-website/`
- Purpose: public preview and QA before Cloudflare authorization.
- Deployment: `.github/workflows/pages.yml` builds with `npm run build` and publishes `dist`, matching the Cloudflare Pages output directory.
- Limitation: Cloudflare `_redirects`, `_headers`, `_routes.json`, and Pages Functions are not honored by GitHub Pages. Treat this as staging only, not final production.

## Preflight Checks

Run the readiness check before any production DNS or podcast cutover:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1
```

The expected pre-R2 result is all checks passing with one warning: podcast audio enclosures still point at TheChurchCo. After R2 audio rewrite, run the stricter form:

The readiness script also checks that the `origin` remote and active `gh` account are using `wakefieldhare-collab`, not `wake-byte`.

```powershell
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://media.fillmorechristian.org"
.\scripts\test-migration-readiness.ps1 -RequireIndependentAudio
```

To verify Cloudflare-specific behavior locally, including `_redirects`, `_headers`, and the Pages Function for old podcast query links:

```powershell
npm run build
.\scripts\test-cloudflare-pages-local.ps1
```

To verify the 2.16 GB local audio backup hashes before cancellation:

```powershell
.\scripts\test-migration-readiness.ps1 -VerifyAudioHashes
```

To verify that podcast enclosure URLs are reachable and serving audio metadata:

```powershell
# Fast sample, useful during normal work.
.\scripts\test-podcast-media.ps1 -SampleCount 5
.\scripts\test-migration-readiness.ps1 -VerifyPodcastMedia

# Full enclosure sweep, useful before canceling TheChurchCo or after R2 rewrite.
.\scripts\test-podcast-media.ps1 -All
.\scripts\test-migration-readiness.ps1 -VerifyPodcastMedia -VerifyAllPodcastMedia
```

## Cloudflare Pages Status

The repo is ready for a Cloudflare Pages static deployment. Use:

- Build command: `npm run build`
- Build output directory: `dist`
- Production branch: `main`
- Local Pages config: `wrangler.toml` uses `compatibility_date = "2026-04-17"` so it works with the installed Wrangler 4.82 local runtime.

The build copies only public website assets into `dist` so migration notes, scripts, and export artifacts are not published as part of the production site.

`wrangler` is installed locally, but it was not authenticated on 2026-06-01. Run `wrangler login` or connect the GitHub repo through the Cloudflare dashboard before deployment.

After Cloudflare authentication, the guarded deploy command is:

```powershell
npm run deploy:cloudflare
```

That command refuses the work GitHub owner, requires a clean working tree by default, runs `npm run build`, local readiness, and Cloudflare Pages local preflight, then runs `wrangler pages deploy dist --project-name fillmorechristian-website --branch main` with the current Git commit hash and message. Before authentication, use this rehearsal form:

```powershell
.\scripts\deploy-cloudflare-pages.ps1 -DryRun -AllowDirty
```

If podcast audio has just been migrated to R2, commit and push the generated feed/page changes before running `npm run deploy:cloudflare` so the Cloudflare deployment is tied to a personal-GitHub commit.

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

Build the Cloudflare preserve/import records and cutover plan from the latest snapshot:

```powershell
.\scripts\build-cloudflare-dns-plan.ps1
```

This writes:

- `exports/dns/fillmorechristian.org-cloudflare-preserve-records.csv`
- `exports/dns/fillmorechristian.org-cloudflare-preserve-records.zone`
- `exports/dns/fillmorechristian.org-cloudflare-dns-cutover-plan.md`

The preserve files intentionally keep the Mailgun/Microsoft records and exclude the old TheChurchCo web records. Before changing nameservers, run:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode Before
```

After Cloudflare assigns nameservers and Squarespace is updated, run the after-cutover verifier with the real Cloudflare nameserver names:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode After -ExpectedCloudflareNameservers "name1.ns.cloudflare.com","name2.ns.cloudflare.com"
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
- `https://www.fillmorechristian.org/events.ics` returns the self-hosted Sunday schedule as `text/calendar`.
- `https://www.fillmorechristian.org/contact.vcf` returns the self-hosted church contact card.
- Sermons page shows podcast episodes.
- A known MP3 enclosure from the feed downloads or plays.
- `church@fillmorechristian.org` still receives mail.
- Contact form destination is configured and tested.
- Give link still points to `https://givebutter.com/fillmorechristian`.
