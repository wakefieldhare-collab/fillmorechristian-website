# Cloudflare DNS Cutover Plan for fillmorechristian.org

Generated: 2026-06-01 10:58:08 -05:00

Source snapshot: `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv`

## Import/Preserve Before Nameserver Change

Import or manually create the records in:

- `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv`
- `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-cloudflare-preserve-records.zone`

These records intentionally exclude the old TheChurchCo website records. They preserve mail and verification records only.

- MX `fillmorechristian.org` priority `10` -> `mxa.mailgun.org`
- MX `fillmorechristian.org` priority `10` -> `mxb.mailgun.org`
- TXT `fillmorechristian.org` -> `MS=ms48673064`
- TXT `fillmorechristian.org` -> `v=spf1 include:mailgun.org ~all`

## Replace During Cloudflare Pages Setup

Do not recreate these old website records in Cloudflare:


Instead, let Cloudflare Pages add or verify custom domains for:

- `www.fillmorechristian.org`
- `fillmorechristian.org`

Expected Pages project name: `fillmorechristian-website`

## Verify

Before nameserver change:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode Before
```

After Cloudflare gives assigned nameservers and Squarespace is updated:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode After -ExpectedCloudflareNameservers "name1.ns.cloudflare.com","name2.ns.cloudflare.com"
```

Only cancel TheChurchCo after website, feed, media, and mail checks pass.
