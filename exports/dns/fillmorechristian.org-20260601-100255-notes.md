# DNS Snapshot for fillmorechristian.org

Generated: 2026-06-01 10:02:57 -05:00

CSV: C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-20260601-100255-records.csv

## Current Nameservers

- ns-cloud-d1.googledomains.com
- ns-cloud-d2.googledomains.com
- ns-cloud-d3.googledomains.com
- ns-cloud-d4.googledomains.com

## Records To Preserve During Cloudflare Cutover

### Mail

- MX fillmorechristian.org priority 10 -> mxa.mailgun.org
- MX fillmorechristian.org priority 10 -> mxb.mailgun.org
- TXT fillmorechristian.org -> MS=ms48673064
- TXT fillmorechristian.org -> v=spf1 include:mailgun.org ~all

### Current Website Records

- A fillmorechristian.org -> 77.83.141.16
- CNAME www.fillmorechristian.org -> ssl.thechurchco.com

## Cloudflare Cutover Notes

- Preserve MX and TXT records before changing nameservers.
- Replace the current TheChurchCo website records with Cloudflare Pages custom-domain records when Cloudflare provides them.
- Re-run this snapshot immediately before the final nameserver change in case Squarespace DNS has changed.
