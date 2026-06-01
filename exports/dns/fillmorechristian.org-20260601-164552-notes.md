# DNS Snapshot for fillmorechristian.org

Generated: 2026-06-01 16:45:55 -05:00

CSV: C:\Users\wakef\Documents\AI-Projects\fcc-website\exports\dns\fillmorechristian.org-20260601-164552-records.csv

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
- TXT pic._domainkey.fillmorechristian.org -> k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDMspMJXAZ/D2ygNZBnGbLY5Z9DjNaNiLDjKY79O1JYgtYlkOERm5SVNOb1nKavNA98hqTLLN+1N7LQGoaeqY0O8ddDa8NclV57cTekdu4by/fcKN+8zycaOE2HRH9hZP1RLNmandRuUQfmTYMrXIWrjBU0xaQdbXZHMP0pN5FuQIDAQAB

### Verification CNAMEs

- CNAME 334xc4sml6cf.fillmorechristian.org -> gv-ujhethalu73pqt.dv.googlehosted.com
- CNAME 4jb3ni34htue.fillmorechristian.org -> gv-xvljhthdwk5dxh.dv.googlehosted.com
- CNAME cbsw2pw4sdud.fillmorechristian.org -> gv-6xwzpofnvqguxs.dv.googlehosted.com

### Current Website Records

- A fillmorechristian.org -> 77.83.141.16
- CNAME www.fillmorechristian.org -> ssl.thechurchco.com

## Cloudflare Cutover Notes

- Preserve MX, TXT, and verification CNAME records before changing nameservers.
- Replace the current TheChurchCo website records with Cloudflare Pages custom-domain records when Cloudflare provides them.
- Re-run this snapshot immediately before the final nameserver change in case Squarespace DNS has changed.
