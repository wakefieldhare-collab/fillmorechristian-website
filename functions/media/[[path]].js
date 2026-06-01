function getMediaKey(context) {
  const parts = context.params.path;
  const key = Array.isArray(parts) ? parts.join("/") : parts || "";
  if (!key || key.startsWith("/") || key.includes("..") || key.includes("\\")) {
    return "";
  }
  return key;
}

function getFallbackContentType(key) {
  const lowerKey = key.toLowerCase();
  if (lowerKey.endsWith(".m4a")) {
    return "audio/mp4";
  }
  if (lowerKey.endsWith(".wav")) {
    return "audio/wav";
  }
  return "audio/mpeg";
}

function parseRangeHeader(rangeHeader, size) {
  if (!rangeHeader) {
    return null;
  }

  const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
  if (!match) {
    return { unsatisfiable: true };
  }

  const startText = match[1];
  const endText = match[2];
  if (!startText && !endText) {
    return { unsatisfiable: true };
  }

  if (!startText) {
    const suffixLength = Number.parseInt(endText, 10);
    if (!Number.isFinite(suffixLength) || suffixLength <= 0) {
      return { unsatisfiable: true };
    }

    const length = Math.min(suffixLength, size);
    return {
      offset: size - length,
      length
    };
  }

  const offset = Number.parseInt(startText, 10);
  const end = endText ? Number.parseInt(endText, 10) : size - 1;
  if (!Number.isFinite(offset) || !Number.isFinite(end) || offset < 0 || end < offset || offset >= size) {
    return { unsatisfiable: true };
  }

  return {
    offset,
    length: Math.min(end, size - 1) - offset + 1
  };
}

function setObjectHeaders(headers, object, key) {
  object.writeHttpMetadata(headers);
  if (!headers.has("Content-Type")) {
    headers.set("Content-Type", getFallbackContentType(key));
  }
  if (object.httpEtag) {
    headers.set("ETag", object.httpEtag);
  }
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  headers.set("X-Content-Type-Options", "nosniff");
}

async function handleMediaRequest(context, key) {
  const { request, env } = context;
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { Allow: "GET, HEAD" }
    });
  }

  if (!env.SERMON_AUDIO) {
    return new Response("Sermon audio binding is not configured", { status: 503 });
  }

  const head = await env.SERMON_AUDIO.head(key);
  if (!head) {
    return new Response("Audio not found", { status: 404 });
  }

  const headers = new Headers();
  setObjectHeaders(headers, head, key);

  const range = parseRangeHeader(request.headers.get("Range"), head.size);
  if (range?.unsatisfiable) {
    headers.set("Content-Range", `bytes */${head.size}`);
    return new Response(null, { status: 416, headers });
  }

  const options = range ? { range } : undefined;
  const object = request.method === "HEAD" ? head : await env.SERMON_AUDIO.get(key, options);
  if (!object) {
    return new Response("Audio not found", { status: 404 });
  }

  if (object !== head) {
    setObjectHeaders(headers, object, key);
  }

  const status = range ? 206 : 200;
  if (range) {
    const rangeEnd = range.offset + range.length - 1;
    headers.set("Content-Range", `bytes ${range.offset}-${rangeEnd}/${head.size}`);
    headers.set("Content-Length", String(range.length));
  } else {
    headers.set("Content-Length", String(head.size));
  }

  return new Response(request.method === "HEAD" ? null : object.body, { status, headers });
}

export async function onRequest(context) {
  const key = getMediaKey(context);
  if (!key) {
    return new Response("Audio not found", { status: 404 });
  }

  return handleMediaRequest(context, key);
}
