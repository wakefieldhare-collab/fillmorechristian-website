# Fillmore Christian Website Migration Runbook

Last updated: 2026-06-02

## Current Facts

- Domain: `fillmorechristian.org`
- Current registrar/DNS account: Squarespace Domains / former Google Domains
- Cloudflare assigned nameservers: `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`
- Current public DNS: Cloudflare DNS is authoritative, and the latest recursive DNS cache report found no stale Squarespace/TheChurchCo answers.
- Current website host: Cloudflare Pages project `fillmorechristian-website`
- Current public `www` target in Cloudflare DNS: proxied Pages custom domain
- Cloudflare DNS records are prepared and API-verified: the old TheChurchCo web records are removed inside Cloudflare, the apex and `www` Pages CNAMEs are present, and mail/SPF/DMARC/DKIM/verification records are preserved.
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
3. Add `fillmorechristian.org` to Cloudflare DNS and import/verify existing DNS records. Done.
4. Point Squarespace nameservers to Cloudflare nameservers so Cloudflare DNS becomes active. Done.
5. Verify `www`, apex, email MX, contact form, and the legacy podcast feed URL. Done.
6. Transfer registrar from Squarespace to Cloudflare Registrar. Waiting for the Squarespace transfer authorization code sent to the registrant contact, `church@fillmorechristian.org`.
7. TheChurchCo website/podcast hosting is cancellation-ready after the 2026-06-02 full-media production receipt. Keep the receipt with the migration records.

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

TheChurchCo website/podcast hosting is cancellation-ready now that the audio files are backed up, the FCC-owned feed is verified in production, recursive DNS cache is clear, and the R2-backed `/media` route has passed a public media sweep.

Export status on 2026-06-01:

- Feed items: 73
- Unique downloaded audio files: 70
- Audio backup size: about 2.16 GB
- Two feed items currently have no audio enclosure in ChurchCo.
- Two July 2023 feed items point to the same MP3, so only one local file was downloaded for that shared enclosure.
- Backup folder: `exports/thechurchco-podcast/audio/`
- Download verification inventory: `exports/thechurchco-podcast/audio-inventory.csv` with SHA-256 hashes for the 70 local audio files.

## Podcast Independence Plan

Current state is safe for production traffic and cancellation-ready for TheChurchCo website/podcast hosting:

- The RSS feed is preserved locally and will continue to publish from `www.fillmorechristian.org`.
- The historical MP3 files are backed up locally and hash-inventoried.
- Podcast artwork is hosted by the static site at `https://www.fillmorechristian.org/images/podcast-cover.jpg`.
- The Cloudflare Pages feed enclosures now point to `https://www.fillmorechristian.org/media/...`; after DNS cutover those URLs are served by the Pages Function backed by the FCC R2 bucket.
- Before DNS cutover, the same R2-backed media route can be verified on `https://fillmorechristian-website.pages.dev/media/...`.

Cloudflare R2 is the selected long-term audio host. It keeps the church infrastructure under the same Cloudflare account as the website and domain while preserving the existing Apple Podcasts feed URL.

Prepared scripts for the R2 path:

```powershell
# Build the deterministic object manifest first. This validates local files,
# inventory hashes, duplicate feed references, object keys, and public URLs.
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://www.fillmorechristian.org/media"

# Safe pre-auth rehearsal. This does not contact Cloudflare.
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons -DryRun

# After `wrangler login` and R2 bucket creation:
.\scripts\upload-podcast-audio-to-r2.ps1 -Bucket fillmore-christian-sermons

# Verify R2 received the uploaded files. Use -All before canceling TheChurchCo.
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -SampleCount 5
.\scripts\test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -VerifyHashes

# After DNS cutover makes www.fillmorechristian.org point to Cloudflare Pages:
.\scripts\test-r2-public-audio.ps1 -SampleCount 5
.\scripts\test-r2-public-audio.ps1 -All

# Before DNS cutover, verify the same R2 objects through the Pages preview route:
npm run verify:r2-pages-audio
npm run verify:r2-pages-audio -- -All

# The feed has already been rewritten to the owned Pages media route:
.\scripts\rewrite-podcast-audio-urls.ps1 -BaseAudioUrl "https://www.fillmorechristian.org/media"
```

The guarded one-command local preparation path is:

```powershell
npm run migrate:cloudflare-audio -- -DryRun

# With authenticated Wrangler, R2 upload, Pages R2 binding, and a clean tree:
npm run migrate:cloudflare-audio -- -CreateBucket
```

The active media path is the Cloudflare Pages Function route `/media/<object-key>`, backed by the `SERMON_AUDIO` R2 binding in `wrangler.toml`.

After Squarespace nameservers have been changed to Cloudflare, the guarded continuation command is:

```powershell
npm run complete:cloudflare-cutover
```

It verifies Cloudflare nameservers, runs the post-cutover DNS gate, verifies the R2-backed Pages `/media/` URLs, and then runs strict independent-audio readiness checks. If DNS is still propagating, use `npm run complete:cloudflare-cutover -- -WaitForDns`.

For the final production receipt before canceling anything, use the combined verifier:

```powershell
npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia
```

This runs the Cloudflare cutover verifier, the domain-transfer safety gate, the recursive DNS cache-clear gate, and the TheChurchCo cancellation gate in order. It verifies both `https://www.fillmorechristian.org/` and `https://fillmorechristian.org/`, writes a timestamped non-secret Markdown and JSON report under `exports/cutover/`, stops on the first failed gate, and explicitly says not to cancel TheChurchCo or disable Squarespace auto-renew until the report passes.

For the click-by-click cancellation handoff, use the read-only checklist:

```powershell
npm run cutover:thechurchco-cancellation-checklist
```

It reads the latest production and recursive DNS-cache receipts, refuses to call cancellation safe unless the latest receipt is a full-media PASS with green DNS-cache and TheChurchCo cancellation steps, and prints the exact post-cancellation verifier to run.

After TheChurchCo website/podcast hosting is canceled, or after the Cloudflare Registrar transfer is started, rerun the named post-cancellation gate:

```powershell
npm run verify:post-cancellation
```

This reruns the full-media production verifier and preserves the reminder to keep Squarespace auto-renew enabled until Cloudflare Registrar shows the transfer in progress or complete.

The migration command refuses the work GitHub owner, requires `https://` audio URLs, verifies Cloudflare authentication, can create the R2 bucket, uploads and hash-verifies all 70 audio objects, rewrites all three RSS feeds to `https://www.fillmorechristian.org/media`, regenerates episode pages/sermon archive/homepage latest-sermon links, builds `dist`, and runs strict local readiness plus the Cloudflare Pages local preflight. Use `npm run complete:cloudflare-cutover` and `npm run verify:cancel-thechurchco` before cancellation for a full production media sweep.

After rewriting enclosure URLs, re-run local verification and push the RSS changes before canceling TheChurchCo.

R2 preparation status on 2026-06-02:

- `exports/thechurchco-podcast/r2-audio-manifest.csv` maps 70 local objects to 71 RSS enclosure references.
- The manifest totals 2,315,228,157 bytes and includes the intended `https://www.fillmorechristian.org/media/...` public URLs.
- R2 is enabled in the Cloudflare account, bucket `fillmore-christian-sermons` exists, and all 70 audio objects were uploaded to Standard storage on June 1, 2026.
- `scripts/test-r2-audio-upload.ps1 -Bucket fillmore-christian-sermons -All -VerifyHashes` downloaded and SHA-256 verified all 70 R2 objects after upload.
- `npm run verify:r2-pages-audio` verifies the same objects through `https://fillmorechristian-website.pages.dev/media/...` before production DNS cutover.
- `scripts/test-r2-public-audio.ps1` verifies the public `www.fillmorechristian.org/media/...` URLs from the manifest after DNS cutover.
- The remaining registrar blocker is the Squarespace transfer authorization code. In Squarespace Domains, click `Request transfer code` if needed, check `church@fillmorechristian.org`, then enter the code in Cloudflare Dashboard > Domains > Transfers to start the Cloudflare Registrar transfer.
- The cancellation blocker is cleared: `fillmorechristian.org-production-cutover-20260602-070754.md` passed with all podcast media verified, recursive DNS cache clear, and TheChurchCo cancellation readiness green.
- The cancellation handoff command is `npm run cutover:thechurchco-cancellation-checklist`; run it from the repo before clicking any final TheChurchCo billing cancellation control.
- After canceling TheChurchCo website/podcast hosting, run `npm run verify:post-cancellation` and keep the generated receipt with the cutover records.

Current registrar checklist:

```powershell
npm run cutover:registrar-checklist
```

Podcast metadata cleanup can be run as one guarded command:

```powershell
npm run refresh:podcast-content
```

That wrapper normalizes the feed, regenerates episode pages, updates the sermon archive, updates the homepage latest-sermon block, updates the podcast page latest-message fallback cards, and builds `dist`.

The individual commands remain available when you need to run one step:

```powershell
.\scripts\normalize-podcast-metadata.ps1
.\scripts\render-static-episodes.ps1
.\scripts\render-static-sermons.ps1
.\scripts\render-homepage-latest-sermon.ps1
.\scripts\render-podcast-latest.ps1
```

This keeps old ChurchCo account author values such as `thechurchcodaniel` out of the public RSS feed and sermon archive, and it creates one static page for every feed episode so old `/episode/.../` links remain useful after the static-site cutover.

The episode renderer also writes `exports/thechurchco-podcast/legacy-podcast-redirects.csv`, `functions/index.js`, and `_routes.json`. Those preserve the older WordPress-style podcast links such as `/?post_type=podcasts&p=603` by redirecting them to the generated `/episode/.../` page when the site is deployed on Cloudflare Pages.

## Public Staging Deployment

GitHub Pages staging is enabled from `main`:

- URL: `https://wakefieldhare-collab.github.io/fillmorechristian-website/`
- Purpose: public preview and QA before Cloudflare DNS cutover.
- Deployment: `.github/workflows/pages.yml` builds with `npm run build` and publishes `dist`, matching the Cloudflare Pages output directory.
- Safety gate: deploy waits for a Windows readiness job that runs `npm run build` and `scripts/test-migration-readiness.ps1 -SkipRemote -SkipLocalAudioBackup`. The skip applies only to the large local audio backup folder that is intentionally not checked into GitHub; local cancellation checks still run without that skip.
- Limitation: Cloudflare `_redirects`, `_headers`, `_routes.json`, and Pages Functions are not honored by GitHub Pages. Treat this as staging only, not final production.

## Preflight Checks

For a quick read-only status snapshot that shows the personal GitHub owner, Squarespace renewal timing, local feed/audio/R2 coverage, staging, DNS, and the next authorization blocker:

```powershell
npm run status:migration
```

Run the readiness check before any production DNS or podcast cutover:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1
```

The readiness script also checks that the `origin` remote and active `gh` account are using `wakefieldhare-collab`, not `wake-byte`.

```powershell
.\scripts\build-r2-audio-manifest.ps1 -BaseAudioUrl "https://www.fillmorechristian.org/media"
.\scripts\test-migration-readiness.ps1 -RequireIndependentAudio
npm run verify:r2-pages-audio
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

Before canceling TheChurchCo, run the stricter cancellation gate against production:

```powershell
npm run verify:cancel-thechurchco -- -VerifyAllPodcastMedia
```

This gate is expected to fail until Cloudflare nameservers are active, recursive DNS caches no longer return old Squarespace/TheChurchCo answers, the static site is live at `https://www.fillmorechristian.org`, mail DNS is preserved, and the production podcast feed has been rewritten so all audio enclosures use `https://www.fillmorechristian.org/media/...` instead of TheChurchCo.

The preferred final command is the combined report-writing wrapper:

```powershell
npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia
```

It includes the cancellation gate above plus the DNS cutover and domain-transfer gates, and it leaves a local report in `exports/cutover/`.

## Cloudflare Pages Status

Cloudflare Pages project status on 2026-06-01:

- Project: `fillmorechristian-website`
- Production preview URL: `https://fillmorechristian-website.pages.dev/`
- First deployed commit: `4431150 Add copyable calendar feed link`
- Latest deployed commit: run `npm run status:migration` or `git log -1 --oneline` after deployment.
- Custom domains `fillmorechristian.org` and `www.fillmorechristian.org` are attached to the Pages project and active. Public traffic is on Cloudflare DNS; only recursive resolver cache drainage can temporarily show older answers.
- Current deployment source is the local guarded `npm run deploy:cloudflare` command, not a Cloudflare-connected GitHub integration.
- The deployment publishes `_headers`, `_redirects`, `_routes.json`, and the generated Pages Function bundle.

For future Cloudflare Pages deployments, use:

- Build command: `npm run build`
- Build output directory: `dist`
- Production branch: `main`
- Local Pages config: `wrangler.toml` uses `compatibility_date = "2026-04-17"` so it works with the installed Wrangler 4.82 local runtime.

The build copies only public website assets into `dist` so migration notes, scripts, and export artifacts are not published as part of the production site.

`wrangler` is installed locally and authenticated to `wakefield.hare@gmail.com` as of 2026-06-01.

The guarded deploy command is:

```powershell
npm run deploy:cloudflare
```

That command refuses the work GitHub owner, requires a clean working tree by default, requires `HEAD` to be pushed to the personal repo's `origin/main`, verifies Pages access through the available Wrangler OAuth session, runs `npm run build`, local readiness, and Cloudflare Pages local preflight, then runs `wrangler pages deploy dist --project-name fillmorechristian-website --branch main` with the current Git commit hash and message. For a rehearsal without publishing, use:

```powershell
.\scripts\deploy-cloudflare-pages.ps1 -DryRun -AllowDirty
```

Use `-AllowUnpushed` only for a deliberate local-only deployment. Normal production deploys should stay tied to `wakefieldhare-collab/fillmorechristian-website` on `main`.

If podcast audio has just been migrated to R2, commit and push the generated feed/page changes before running `npm run deploy:cloudflare` so the Cloudflare deployment is tied to a personal-GitHub commit.

## Cloudflare DNS Cutover Records

Status on 2026-06-01: these records have already been applied and API-verified inside Cloudflare. The public internet will not use them until Squarespace nameservers are replaced with Cloudflare's assigned nameservers.

Before changing nameservers, screenshot/export all current Squarespace DNS records. At minimum preserve:

- MX: `@` -> `mxa.mailgun.org`, priority 10
- MX: `@` -> `mxb.mailgun.org`, priority 10
- TXT: `@` -> `v=spf1 include:mailgun.org ~all`
- TXT: `@` -> `MS=ms48673064`
- TXT: `_dmarc` -> `v=DMARC1; p=none; rua=mailto:church@fillmorechristian.org`
- TXT: `pic._domainkey` DKIM
- CNAME: `cbsw2pw4sdud` -> `gv-6xwzpofnvqguxs.dv.googlehosted.com`
- CNAME: `4jb3ni34htue` -> `gv-xvljhthdwk5dxh.dv.googlehosted.com`
- CNAME: `334xc4sml6cf` -> `gv-ujhethalu73pqt.dv.googlehosted.com`

For Cloudflare Pages, use the Pages custom-domain instructions generated by Cloudflare. Typically:

- `www` -> Cloudflare Pages custom domain target
- Apex `fillmorechristian.org` -> Cloudflare Pages apex custom domain setup

For independent sermon audio, use the Pages `/media/<object-key>` route backed by the `SERMON_AUDIO` R2 bucket binding. Verify sampled and then all public `https://www.fillmorechristian.org/media/...` URLs before canceling TheChurchCo.

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

The preserve files intentionally keep the Mailgun/Microsoft/DMARC/DKIM/Google verification records and exclude the old TheChurchCo web records. The Cloudflare API apply has already been run successfully. Before changing nameservers, a final public pre-cutover check can still be run:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode Before
```

Preview the exact Cloudflare DNS records that were preserved and replaced:

```powershell
npm run apply:cloudflare-dns
```

To apply those records through the Cloudflare API instead of clicking in the dashboard, create a Cloudflare API token at `https://dash.cloudflare.com/profile/api-tokens` with these permissions for `fillmorechristian.org`:

- Zone:Read
- Zone:DNS Edit

If the Cloudflare DNS record set ever needs to be re-applied, set `CLOUDFLARE_API_TOKEN` or `CF_API_TOKEN` to that token, then run:

```powershell
npm run apply:cloudflare-dns -- -Apply
```

On successful API verification, this writes a non-secret receipt at `exports/dns/fillmorechristian.org-cloudflare-dns-verification.json`. The migration status command uses that receipt to report the last verified Cloudflare DNS state without requiring the API token to remain in the shell.

Security cleanup: the temporary Cloudflare user API token named `FCC` was revoked in the Cloudflare dashboard on 2026-06-02 after `npm run verify:post-cancellation` passed. If a new temporary token is created later, revoke it after the required verifier passes.

After Cloudflare assigns nameservers and Squarespace is updated, run the after-cutover verifier with the real Cloudflare nameserver names:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode After -ExpectedCloudflareNameservers "name1.ns.cloudflare.com","name2.ns.cloudflare.com"
```

Latest public snapshot before cutover on 2026-06-01 found:

- Cloudflare zone: `fillmorechristian.org` exists and is now active.
- Cloudflare-assigned nameservers: `eric.ns.cloudflare.com` and `sky.ns.cloudflare.com`.
- Pages custom domains: `fillmorechristian.org` and `www.fillmorechristian.org` are attached and active.
- Cloudflare DNS records: prepared, API-verified, and authoritative through Cloudflare nameservers; stale recursive caches may still temporarily show the old values listed below.
- R2 audio: the Pages `/media/` route is deployed with an R2 binding and has been fully verified through production `www.fillmorechristian.org/media/...`.
- NS: `ns-cloud-d1.googledomains.com` through `ns-cloud-d4.googledomains.com`
- A: `fillmorechristian.org` -> `77.83.141.16`
- CNAME: `www.fillmorechristian.org` -> `ssl.thechurchco.com`
- MX: `fillmorechristian.org` -> `mxa.mailgun.org`, priority 10
- MX: `fillmorechristian.org` -> `mxb.mailgun.org`, priority 10
- TXT: `v=spf1 include:mailgun.org ~all`
- TXT: `MS=ms48673064`
- TXT: `_dmarc.fillmorechristian.org` -> `v=DMARC1; p=none; rua=mailto:church@fillmorechristian.org` is prepared for Cloudflare because the current public DNS snapshot does not include DMARC.
- TXT: `pic._domainkey.fillmorechristian.org` -> Mailgun DKIM key
- CNAME: `cbsw2pw4sdud.fillmorechristian.org` -> `gv-6xwzpofnvqguxs.dv.googlehosted.com`
- CNAME: `4jb3ni34htue.fillmorechristian.org` -> `gv-xvljhthdwk5dxh.dv.googlehosted.com`
- CNAME: `334xc4sml6cf.fillmorechristian.org` -> `gv-ujhethalu73pqt.dv.googlehosted.com`

## Registrar Transfer To Cloudflare

Cloudflare requires the domain to be active on Cloudflare DNS before transferring registration. After DNS is active:

Run the transfer safety gate before starting the Cloudflare Registrar transfer or disabling Squarespace auto-renew:

```powershell
npm run verify:domain-transfer
```

This is expected to fail until Cloudflare nameservers are active, the old TheChurchCo website DNS records are gone, mail records are preserved, and the production apex/www website plus feed are live. Do not disable Squarespace auto-renew merely because the gate passes; keep it enabled until the Cloudflare Registrar transfer is visibly underway or complete.

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
