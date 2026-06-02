const PODCAST_FEED_PATH = 'podcast-category/fillmore-christian/feed/podcast';
const PODCAST_LATEST_LIMIT = 3;

document.addEventListener('DOMContentLoaded', function() {
  const list = document.getElementById('podcast-latest-list');
  if (!list) return;

  loadLatestPodcastMessages(list);
});

async function loadLatestPodcastMessages(list) {
  try {
    const text = await getPodcastText(resolvePodcastUrl(PODCAST_FEED_PATH));
    const xml = new DOMParser().parseFromString(text, 'text/xml');
    const items = Array.from(xml.querySelectorAll('item'))
      .map(parsePodcastItem)
      .filter(function(item) { return item.title; })
      .slice(0, PODCAST_LATEST_LIMIT);

    if (items.length === 0) {
      if (hasStaticLatestCards(list)) return;
      list.innerHTML = '<div class="podcast-latest-card podcast-latest-loading"><p>Latest messages will appear here as the podcast feed is updated.</p></div>';
      return;
    }

    list.innerHTML = items.map(renderPodcastItem).join('');
  } catch (err) {
    if (hasStaticLatestCards(list)) return;
    list.innerHTML = '<div class="podcast-latest-card podcast-latest-loading"><p>Latest messages are unavailable right now. Open the full archive for the sermon list.</p></div>';
  }
}

function hasStaticLatestCards(list) {
  return !!list.querySelector('[data-static-podcast-latest="true"]');
}

function parsePodcastItem(item) {
  const enclosure = item.querySelector('enclosure');
  const rawDate = getPodcastElementText(item, 'pubDate');
  const audioUrl = enclosure ? enclosure.getAttribute('url') || '' : '';
  const pageAudioUrl = toPageMediaUrl(audioUrl);
  const audioSizeLabel = enclosure ? formatPodcastFileSize(enclosure.getAttribute('length')) : '';

  return {
    title: cleanPodcastText(getPodcastElementText(item, 'title')),
    date: formatPodcastDate(rawDate),
    speaker: cleanPodcastSpeaker(getPodcastElementText(item, 'itunes\\:author') || getPodcastElementText(item, 'author')),
    episodeHref: getEpisodeHref(getPodcastElementText(item, 'link')),
    audioUrl: pageAudioUrl,
    audioType: getPodcastAudioType(pageAudioUrl),
    audioSizeLabel
  };
}

function renderPodcastItem(item) {
  const title = escapePodcastHtml(item.title || 'Untitled message');
  const meta = [item.date, item.speaker, item.audioSizeLabel ? 'Audio ' + item.audioSizeLabel : ''].filter(Boolean).map(escapePodcastHtml).join(' &middot; ');
  const titleMarkup = item.episodeHref
    ? '<h3><a href="' + escapePodcastHtml(item.episodeHref) + '">' + title + '</a></h3>'
    : '<h3>' + title + '</h3>';
  const audioMarkup = item.audioUrl
    ? '<audio controls preload="none"><source src="' + escapePodcastHtml(item.audioUrl) + '" type="' + escapePodcastHtml(item.audioType) + '">Your browser does not support audio playback.</audio>'
    : '<p class="sermon-audio-missing">Audio is not attached to this archived feed item yet.</p>';
  const actions = [
    item.episodeHref ? '<a href="' + escapePodcastHtml(item.episodeHref) + '" class="btn btn-outline">Open Message</a>' : '',
    item.audioUrl ? '<a href="' + escapePodcastHtml(item.audioUrl) + '" class="btn btn-outline" download>Download Audio</a>' : ''
  ].filter(Boolean).join('');

  return '<article class="podcast-latest-card">' +
    titleMarkup +
    (meta ? '<p class="sermon-meta">' + meta + '</p>' : '') +
    audioMarkup +
    (actions ? '<div class="podcast-latest-actions">' + actions + '</div>' : '') +
    '</article>';
}

function resolvePodcastUrl(path) {
  const pagePath = window.location.pathname;
  const basePath = pagePath.endsWith('/')
    ? pagePath
    : pagePath.substring(0, pagePath.lastIndexOf('/') + 1);
  return new URL(path, window.location.origin + basePath).toString();
}

function getPodcastText(url) {
  return window.fetch(url).then(function(response) {
    if (!response.ok) throw new Error('Podcast feed request failed: ' + response.status);
    return response.text();
  });
}

function getPodcastElementText(parent, tagName) {
  const el = parent.querySelector(tagName);
  return el ? el.textContent.trim() : '';
}

function getEpisodeHref(url) {
  if (!url) return '';

  try {
    const parsed = new URL(url, window.location.origin);
    const match = parsed.pathname.match(/\/episode\/([^/]+)\/?$/);
    return match ? 'episode/' + match[1] + '/' : '';
  } catch (err) {
    return '';
  }
}

function toPageMediaUrl(url) {
  if (!url) return '';

  try {
    const parsed = new URL(url, window.location.origin);
    if (parsed.hostname === 'www.fillmorechristian.org' && parsed.pathname.startsWith('/media/')) {
      return parsed.pathname + parsed.search;
    }
    return parsed.toString();
  } catch (err) {
    return url;
  }
}

function formatPodcastDate(dateStr) {
  if (!dateStr) return '';
  const date = new Date(dateStr);
  if (Number.isNaN(date.getTime())) return dateStr;
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
}

function getPodcastAudioType(url) {
  const lower = (url || '').toLowerCase();
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return 'audio/mpeg';
}

function formatPodcastFileSize(bytesText) {
  const bytes = Number(bytesText);
  if (!Number.isFinite(bytes) || bytes <= 0) return '';
  if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
  if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + ' MB';
  if (bytes >= 1024) return Math.round(bytes / 1024) + ' KB';
  return String(bytes) + ' bytes';
}

function cleanPodcastText(str) {
  return (str || '')
    .replace(/\s+/g, ' ')
    .trim();
}

function cleanPodcastSpeaker(str) {
  const speaker = cleanPodcastText(str);
  if (!speaker || /^thechurchco/i.test(speaker)) return 'Fillmore Christian';
  return speaker;
}

function escapePodcastHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str || ''));
  return div.innerHTML;
}
