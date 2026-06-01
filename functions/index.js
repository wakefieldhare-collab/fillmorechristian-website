const LEGACY_PODCAST_REDIRECTS = {
  "1085": "/episode/exodus-17-dehydrated/",
  "603": "/episode/be-ready-luke-12/",
  "621": "/episode/luke-13-31-35-gods-desire-and-mission-for-you/",
  "629": "/episode/luke-14-16b-35-following-christ-whatever-the-cost/",
  "632": "/episode/the-danger-of-being-the-older-brother/"
};

export async function onRequest(context) {
  const url = new URL(context.request.url);

  if (url.searchParams.get("post_type") === "podcasts") {
    const targetPath = LEGACY_PODCAST_REDIRECTS[url.searchParams.get("p") || ""];
    if (targetPath) {
      return Response.redirect(new URL(targetPath, url.origin).toString(), 301);
    }
  }

  return context.next();
}
