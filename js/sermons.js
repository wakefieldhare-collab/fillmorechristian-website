/* ============================================
   Sermon Loader - Fetches from podcast RSS feed
   ============================================ */

const PODCAST_RSS_URL = 'podcast-category/fillmore-christian/feed/podcast';
const LOCAL_SERMONS = [];

let allSermons = [];

document.addEventListener('DOMContentLoaded', function() {
  const container = document.getElementById('sermons-container');
  if (!container) return;

  const search = document.getElementById('sermon-search');
  const staticCards = Array.from(container.querySelectorAll('.sermon-item'));

  if (staticCards.length > 0) {
    initializeStaticArchive(container, staticCards, search);
    return;
  }

  if (search) {
    search.addEventListener('input', function() {
      renderSermons(container, filterSermons(search.value));
    });
  }

  if (PODCAST_RSS_URL) {
    loadFromRSS(container);
  } else if (LOCAL_SERMONS.length > 0) {
    allSermons = LOCAL_SERMONS;
    renderSermons(container, allSermons);
  } else {
    container.innerHTML = '<div class="sermons-loading">' +
      '<p>Sermons will appear here once the podcast RSS feed is configured.</p>' +
      '</div>';
  }
});

function initializeStaticArchive(container, cards, search) {
  const emptyMessage = document.createElement('div');
  emptyMessage.className = 'sermons-loading';
  emptyMessage.setAttribute('data-static-empty', 'true');
  emptyMessage.hidden = true;
  emptyMessage.innerHTML = '<p>No sermons matched your search.</p>';
  container.appendChild(emptyMessage);

  function applyFilter() {
    const needle = search ? search.value.trim().toLowerCase() : '';
    let visible = 0;

    cards.forEach(function(card) {
      const haystack = card.getAttribute('data-search') || card.textContent.toLowerCase();
      const matched = !needle || haystack.indexOf(needle) !== -1;
      card.hidden = !matched;
      if (matched) visible += 1;
    });

    emptyMessage.hidden = visible !== 0;
    updateCount(visible, cards.length);
  }

  if (search) {
    search.addEventListener('input', applyFilter);
  }

  applyFilter();
}

async function loadFromRSS(container) {
  container.innerHTML = '<div class="sermons-loading"><p>Loading sermons...</p></div>';

  try {
    const text = await getText(resolveSiteUrl(PODCAST_RSS_URL));
    const parser = new DOMParser();
    const xml = parser.parseFromString(text, 'text/xml');
    const items = Array.from(xml.querySelectorAll('item'));

    allSermons = items.map(function(item) {
      const enclosure = item.querySelector('enclosure');
      const rawDate = cleanText(getElementText(item, 'pubDate'));
      const title = cleanText(getElementText(item, 'title'));
      const description = cleanDescription(cleanText(stripHtml(getElementText(item, 'description') || getElementText(item, 'itunes\\:summary') || '')));
      const audioUrl = enclosure ? enclosure.getAttribute('url') || '' : '';

      return {
        title,
        date: formatPubDate(rawDate),
        rawDate,
        speaker: cleanText(getItunesAuthor(item) || 'Fillmore Christian'),
        audioUrl,
        audioType: getAudioType(audioUrl),
        description,
        searchText: [title, description, rawDate].join(' ').toLowerCase()
      };
    });

    renderSermons(container, allSermons);
  } catch (err) {
    console.error('Error loading sermons:', err);
    container.innerHTML = '<div class="sermons-loading">' +
      '<p>Unable to load sermons at this time. Please try again later.</p>' +
      '</div>';
    updateCount(0, 0);
  }
}

function filterSermons(query) {
  const needle = query.trim().toLowerCase();
  if (!needle) return allSermons;
  return allSermons.filter(function(sermon) {
    return sermon.searchText.indexOf(needle) !== -1;
  });
}

function renderSermons(container, sermons) {
  container.innerHTML = '';
  updateCount(sermons.length, allSermons.length);

  if (sermons.length === 0) {
    container.innerHTML = '<div class="sermons-loading"><p>No sermons matched your search.</p></div>';
    return;
  }

  sermons.forEach(function(sermon) {
    const card = document.createElement('article');
    card.className = 'sermon-item' + (sermon.audioUrl ? '' : ' no-audio');

    let html = '<h3>' + escapeHtml(sermon.title || 'Untitled sermon') + '</h3>';
    html += '<div class="sermon-meta">';
    html += '<span>' + escapeHtml(sermon.date || sermon.rawDate || '') + '</span>';
    if (sermon.speaker) {
      html += ' &middot; <span>' + escapeHtml(sermon.speaker) + '</span>';
    }
    html += '</div>';

    if (sermon.description) {
      const desc = sermon.description.length > 240
        ? sermon.description.substring(0, 240) + '...'
        : sermon.description;
      html += '<p class="sermon-description">' + escapeHtml(desc) + '</p>';
    }

    if (sermon.audioUrl) {
      html += '<audio controls preload="none"><source src="' + escapeHtml(sermon.audioUrl) + '" type="' + escapeHtml(sermon.audioType) + '">Your browser does not support audio playback.</audio>';
    } else {
      html += '<p class="sermon-audio-missing">Audio is not attached to this archived feed item yet.</p>';
    }

    card.innerHTML = html;
    container.appendChild(card);
  });
}

function updateCount(visible, total) {
  const count = document.getElementById('sermon-count');
  if (!count) return;

  if (!total) {
    count.textContent = '';
    return;
  }

  count.textContent = visible === total
    ? total + ' archived messages'
    : visible + ' of ' + total + ' archived messages';
}

function getElementText(parent, tagName) {
  const el = parent.querySelector(tagName);
  return el ? el.textContent.trim() : '';
}

function resolveSiteUrl(path) {
  const pagePath = window.location.pathname;
  const basePath = pagePath.endsWith('/')
    ? pagePath
    : pagePath.substring(0, pagePath.lastIndexOf('/') + 1);
  return new URL(path, window.location.origin + basePath).toString();
}

function getText(url) {
  if (typeof window.fetch === 'function') {
    return window.fetch(url).then(function(response) {
      if (!response.ok) throw new Error('RSS request failed: ' + response.status);
      return response.text();
    });
  }

  return new Promise(function(resolve, reject) {
    const request = new XMLHttpRequest();
    request.open('GET', url, true);
    request.onreadystatechange = function() {
      if (request.readyState !== 4) return;
      if (request.status >= 200 && request.status < 300) {
        resolve(request.responseText);
      } else {
        reject(new Error('RSS request failed: ' + request.status));
      }
    };
    request.onerror = function() {
      reject(new Error('RSS request failed.'));
    };
    request.send();
  });
}

function getItunesAuthor(item) {
  const itunesAuthor = item.querySelector('itunes\\:author, author');
  return itunesAuthor ? itunesAuthor.textContent.trim() : '';
}

function formatPubDate(dateStr) {
  if (!dateStr) return '';
  const date = new Date(dateStr);
  if (Number.isNaN(date.getTime())) return dateStr;
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
}

function getAudioType(url) {
  const lower = (url || '').toLowerCase();
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return 'audio/mpeg';
}

function cleanText(str) {
  return (str || '')
    .replace(/\u00e2\u20ac\u201c/g, '-')
    .replace(/\u00e2\u20ac\u201d/g, '-')
    .replace(/\u00e2\u20ac\u2122/g, "'")
    .replace(/\u00e2\u20ac\u0153/g, '"')
    .replace(/\u00e2\u20ac\u009d/g, '"')
    .replace(/\s+/g, ' ')
    .trim();
}

function cleanDescription(str) {
  const text = str || '';
  return /^description(\s+description)*$/i.test(text) ? '' : text;
}

function stripHtml(str) {
  const tmp = document.createElement('div');
  tmp.innerHTML = str;
  return tmp.textContent || tmp.innerText || '';
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str || ''));
  return div.innerHTML;
}
