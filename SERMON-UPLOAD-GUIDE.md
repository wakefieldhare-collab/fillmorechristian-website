# Sermon Upload Guide for Caleb

This site publishes sermons from the FCC website repo and serves podcast audio from Cloudflare R2.

Repo folder:

```powershell
C:\Users\wakef\Documents\AI-Projects\fcc-website
```

## What you need

- The sermon audio file, usually an `.mp3`.
- The sermon title.
- The sermon date.
- Optional: a short description or Scripture reference.
- Cloudflare/Wrangler login on this computer for the R2 upload.

## Add a Sermon

Open PowerShell in the repo folder:

```powershell
cd "C:\Users\wakef\Documents\AI-Projects\fcc-website"
```

Run the add command:

```powershell
.\scripts\add-podcast-episode.ps1 `
  -AudioPath "C:\Path\To\Sermon.mp3" `
  -Title "Sermon Title" `
  -Date "2026-06-07" `
  -Description "John 2:13-22" `
  -UploadR2 `
  -Bucket "fillmore-christian-sermons"
```

The script will:

- Copy the audio into the local podcast audio archive.
- Update all podcast feed files:
  - `podcast-category/fillmore-christian/feed/podcast`
  - `podcast.xml`
  - `feed.xml`
- Update the sermon archive page.
- Create the episode page.
- Update the homepage and podcast page latest-message cards.
- Update the R2 audio manifest.
- Upload the new audio file to Cloudflare R2 when `-UploadR2` is included.
- Build the `dist` folder for deployment.

## Verify Locally

After the script finishes, run:

```powershell
npm run build
.\scripts\test-migration-readiness.ps1 -RequireIndependentAudio
```

If the new audio has already been uploaded to R2, also run a public media check:

```powershell
.\scripts\test-podcast-media.ps1 -SampleCount 1
```

## Publish the Website

Commit and push the changes:

```powershell
git status --short
git add .
git commit -m "Add YYYY-MM-DD sermon audio"
git push origin main
```

Cloudflare Pages deploys from the GitHub `main` branch.

## Confirm After Deploy

After Cloudflare finishes deploying, check:

- Sermons page: `https://www.fillmorechristian.org/sermons.html`
- Podcast page: `https://www.fillmorechristian.org/podcast.html`
- Apple-compatible feed: `https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast`
- New episode page from the script output.

Run the production media sample check:

```powershell
.\scripts\test-podcast-media.ps1 -SampleCount 3
```

## If Cloudflare Is Not Logged In

Run:

```powershell
npx wrangler login
```

Then rerun the add command with `-UploadR2`.

## Common Fixes

- To correct a title or description, rerun `add-podcast-episode.ps1` with the same audio file and the corrected metadata. It replaces the matching episode instead of adding a duplicate.
- To choose a specific page URL, add `-Slug "custom-episode-url-slug"`.
- To choose a specific audio filename, add `-FileName "YYYY-MM-DD-Short-Name.mp3"`.
- If the script says the audio is not public, make sure `-UploadR2 -Bucket "fillmore-christian-sermons"` was used and that Wrangler is logged in.
