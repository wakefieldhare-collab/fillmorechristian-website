# Review queue: Sunday School end times

Tier: 2, public schedule and calendar recurrence change.
Owner: Codex session 01a14eed-2cf4-7211-b050-77209fa266a2.
Source commit: a9afab9782613282e07a8e535164ce7c810b8496.
Reviewer: independent agent /root/review_oct4.
Review due: October 19, 2026.
Last verification: October 18, 2026.
Status: closed. Independent review passed and production verified October 18, 2026.
Authority: Wakefield requested all Sunday School times end at 9:50 AM, except 9:45 AM on Fellowship Breakfast Sundays.
Scope: five public pages, contact card, metadata, schema, recurring calendar, JavaScript fallback and monthly recurrence expansion. Regular second-through-fifth Sundays end at 9:50; first Sundays end at 9:45. Existing exclusions preserved.
Checks: 49 classes across a year; canceled classes, fifth Sundays and exact class-end cutoff. All five pages at 375, 768, 1280 pixels rendered and new schedule text passed line-wrap checks.
Rollback: source 671e5a1936ae5f8ca3a2098ce062f7046f5ede49; prior immutable deployment https://f2b0906e.fillmorechristian-website.pages.dev remains available.
Deployment: https://2b7d0171.fillmorechristian-website.pages.dev
Production readback: Home, Visit, About, Contact and Events schedule sections match the candidate. events.ics, contact.vcf, js/events.js, css/style.css and announcements.json match candidate output after newline normalization. All ten URLs return HTTP 200. Five current October 18 announcements preserved.
Verification: C:\codex-work\fcc-school-live-verification.json
Visual review: C:\codex-work\fcc-school-render-review.jpg
Next action: none for the website correction.
Continuity: this release record is tracked in the website repository and linked from SETUP-GUIDE.md. The separate church wiki is held by another active writer; no concurrent wiki edits made.
