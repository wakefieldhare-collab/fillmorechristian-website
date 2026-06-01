# Cloudflare DNS Cutover Plan for fillmorechristian.org

Generated: 2026-06-01 18:05:07 -05:00

Source snapshot: `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-20260601-164552-records.csv`

## Import/Preserve Before Nameserver Change

Import or manually create the records in:

- `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv`
- `C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-cloudflare-preserve-records.zone`

These records intentionally exclude the old TheChurchCo website records. They preserve mail and verification records only.

- CNAME `334xc4sml6cf.fillmorechristian.org` -> `gv-ujhethalu73pqt.dv.googlehosted.com`
- CNAME `4jb3ni34htue.fillmorechristian.org` -> `gv-xvljhthdwk5dxh.dv.googlehosted.com`
- CNAME `cbsw2pw4sdud.fillmorechristian.org` -> `gv-6xwzpofnvqguxs.dv.googlehosted.com`
- MX `fillmorechristian.org` priority `10` -> `mxa.mailgun.org`
- MX `fillmorechristian.org` priority `10` -> `mxb.mailgun.org`
- TXT `fillmorechristian.org` -> `MS=ms48673064`
- TXT `fillmorechristian.org` -> `v=spf1 include:mailgun.org ~all`
- TXT `pic._domainkey.fillmorechristian.org` -> `k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDMspMJXAZ/D2ygNZBnGbLY5Z9DjNaNiLDjKY79O1JYgtYlkOERm5SVNOb1nKavNA98hqTLLN+1N7LQGoaeqY0O8ddDa8NclV57cTekdu4by/fcKN+8zycaOE2HRH9hZP1RLNmandRuUQfmTYMrXIWrjBU0xaQdbXZHMP0pN5FuQIDAQAB`

## Replace During Cloudflare Pages Setup

Do not recreate these old website records in Cloudflare:

- A `fillmorechristian.org` -> `77.83.141.16`
- CNAME `www.fillmorechristian.org` -> `ssl.thechurchco.com`

Instead, let Cloudflare Pages add or verify custom domains for:

- `www.fillmorechristian.org`
- `fillmorechristian.org`

Expected Pages project name: `fillmorechristian-website`

## Manual Dashboard Cutover Checklist

In Cloudflare DNS > Records, verify or create these website records:

- CNAME `fillmorechristian.org` -> `fillmorechristian-website.pages.dev` with proxy enabled
- CNAME `www.fillmorechristian.org` -> `fillmorechristian-website.pages.dev` with proxy enabled

Remove or replace these old website records if Cloudflare imported them:

- A `fillmorechristian.org` -> `77.83.141.16`
- CNAME `www.fillmorechristian.org` -> `ssl.thechurchco.com`

In Squarespace Domains, replace all current nameservers with:

- `eric.ns.cloudflare.com`
- `sky.ns.cloudflare.com`

## Verify R2 Audio Through Pages

- The Cloudflare Pages project binds the `fillmore-christian-sermons` R2 bucket as `SERMON_AUDIO`.
- Podcast enclosure URLs should use `https://www.fillmorechristian.org/media/<object-key>`.
- HTML audio players use same-origin `/media/<object-key>` paths so previews and the production custom domain share the same function route.
- After nameserver cutover, verify sampled and then all public media URLs before canceling TheChurchCo.

## Verify

Before nameserver change:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode Before
```

After Cloudflare gives assigned nameservers and Squarespace is updated:

```powershell
.\scripts\test-dns-cutover.ps1 -Mode After -ExpectedCloudflareNameservers "eric.ns.cloudflare.com","sky.ns.cloudflare.com"
```

Cloudflare assigned nameservers:

- `eric.ns.cloudflare.com`
- `sky.ns.cloudflare.com`

Cloudflare Pages custom domains for fillmorechristian.org and www.fillmorechristian.org should be attached to fillmorechristian-website before the nameserver change.

Only cancel TheChurchCo after website, feed, media, and mail checks pass.
