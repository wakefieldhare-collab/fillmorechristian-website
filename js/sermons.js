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
  const yearFilter = document.getElementById('sermon-year');
  const sortControl = document.getElementById('sermon-sort');
  const audioOnly = document.getElementById('sermon-audio-only');
  const clearButton = document.getElementById('sermon-clear');
  const shareButton = document.getElementById('sermon-share-link');
  const staticCards = Array.from(container.querySelectorAll('.sermon-item'));

  if (staticCards.length > 0) {
    initializeStaticArchive(container, staticCards, search, yearFilter, sortControl, audioOnly, clearButton, shareButton);
    return;
  }

  if (search) {
    search.addEventListener('input', function() {
      renderSermons(container, filterSermons(search.value, yearFilter ? yearFilter.value : '', audioOnly ? audioOnly.checked : false), sortControl ? sortControl.value : 'newest');
    });
  }

  if (yearFilter) {
    yearFilter.addEventListener('change', function() {
      renderSermons(container, filterSermons(search ? search.value : '', yearFilter.value, audioOnly ? audioOnly.checked : false), sortControl ? sortControl.value : 'newest');
    });
  }

  if (sortControl) {
    sortControl.addEventListener('change', function() {
      renderSermons(container, filterSermons(search ? search.value : '', yearFilter ? yearFilter.value : '', audioOnly ? audioOnly.checked : false), sortControl.value);
    });
  }

  if (audioOnly) {
    audioOnly.addEventListener('change', function() {
      renderSermons(container, filterSermons(search ? search.value : '', yearFilter ? yearFilter.value : '', audioOnly.checked), sortControl ? sortControl.value : 'newest');
    });
  }

  if (clearButton) {
    clearButton.addEventListener('click', function() {
      if (search) search.value = '';
      if (yearFilter) yearFilter.value = '';
      if (sortControl) sortControl.value = 'newest';
      if (audioOnly) audioOnly.checked = false;
      renderSermons(container, filterSermons('', '', false), 'newest');
      if (search) search.focus();
    });
  }

  if (PODCAST_RSS_URL) {
    loadFromRSS(container);
  } else if (LOCAL_SERMONS.length > 0) {
    allSermons = LOCAL_SERMONS;
    populateYearFilter(yearFilter, allSermons.map(function(sermon) { return sermon.year; }));
    renderSermons(container, filterSermons(search ? search.value : '', yearFilter ? yearFilter.value : '', audioOnly ? audioOnly.checked : false), sortControl ? sortControl.value : 'newest');
  } else {
    container.innerHTML = '<div class="sermons-loading">' +
      '<p>Sermons will appear here once the podcast RSS feed is configured.</p>' +
      '</div>';
  }
});

function initializeStaticArchive(container, cards, search, yearFilter, sortControl, audioOnly, clearButton, shareButton) {
  const emptyMessage = document.createElement('div');
  emptyMessage.className = 'sermons-loading';
  emptyMessage.setAttribute('data-static-empty', 'true');
  emptyMessage.hidden = true;
  emptyMessage.innerHTML = '<p>No sermons matched your search.</p>';
  container.appendChild(emptyMessage);
  populateYearFilter(yearFilter, cards.map(function(card) {
    return card.getAttribute('data-year') || '';
  }));
  applyArchiveStateFromUrl(search, yearFilter, sortControl, audioOnly);

  function applyFilter(options) {
    const shouldUpdateUrl = !options || options.updateUrl !== false;
    const needle = search ? search.value.trim().toLowerCase() : '';
    const selectedYear = yearFilter ? yearFilter.value : '';
    const selectedSort = sortControl ? sortControl.value : 'newest';
    const requireAudio = audioOnly ? audioOnly.checked : false;
    let visible = 0;

    sortCards(cards, selectedSort).forEach(function(card) {
      container.insertBefore(card, emptyMessage);
      const haystack = card.getAttribute('data-search') || card.textContent.toLowerCase();
      const cardYear = card.getAttribute('data-year') || '';
      const cardHasAudio = card.getAttribute('data-has-audio') !== 'false';
      const matchedSearch = !needle || haystack.indexOf(needle) !== -1;
      const matchedYear = !selectedYear || cardYear === selectedYear;
      const matchedAudio = !requireAudio || cardHasAudio;
      const matched = matchedSearch && matchedYear && matchedAudio;
      card.hidden = !matched;
      if (matched) visible += 1;
    });

    emptyMessage.hidden = visible !== 0;
    updateCount(visible, cards.length);
    if (shouldUpdateUrl) {
      updateArchiveUrl(search, yearFilter, sortControl, audioOnly);
    }
    updateArchiveShareLink(shareButton);
  }

  if (search) {
    search.addEventListener('input', applyFilter);
  }

  if (yearFilter) {
    yearFilter.addEventListener('change', applyFilter);
  }

  if (sortControl) {
    sortControl.addEventListener('change', applyFilter);
  }

  if (audioOnly) {
    audioOnly.addEventListener('change', applyFilter);
  }

  if (clearButton) {
    clearButton.addEventListener('click', function() {
      if (search) search.value = '';
      if (yearFilter) yearFilter.value = '';
      if (sortControl) sortControl.value = 'newest';
      if (audioOnly) audioOnly.checked = false;
      applyFilter();
      if (search) search.focus();
    });
  }

  applyFilter({ updateUrl: false });
}

function applyArchiveStateFromUrl(search, yearFilter, sortControl, audioOnly) {
  if (typeof URLSearchParams === 'undefined') return;

  const params = new URLSearchParams(window.location.search || '');
  const query = params.get('q') || '';
  const year = params.get('year') || '';
  const sort = params.get('sort') || '';
  const audio = params.get('audio') || '';

  if (search && query) {
    search.value = query;
  }
  if (yearFilter && year && Array.from(yearFilter.options).some(function(option) { return option.value === year; })) {
    yearFilter.value = year;
  }
  if (sortControl && ['newest', 'oldest', 'title'].indexOf(sort) !== -1) {
    sortControl.value = sort;
  }
  if (audioOnly && audio === '1') {
    audioOnly.checked = true;
  }
}

function updateArchiveUrl(search, yearFilter, sortControl, audioOnly) {
  if (typeof URLSearchParams === 'undefined' || !window.history || typeof window.history.replaceState !== 'function') {
    return;
  }

  const params = new URLSearchParams(window.location.search || '');
  const query = search ? search.value.trim() : '';
  const year = yearFilter ? yearFilter.value : '';
  const sort = sortControl ? sortControl.value : 'newest';
  const requireAudio = audioOnly ? audioOnly.checked : false;

  setArchiveParam(params, 'q', query);
  setArchiveParam(params, 'year', year);
  setArchiveParam(params, 'sort', sort && sort !== 'newest' ? sort : '');
  setArchiveParam(params, 'audio', requireAudio ? '1' : '');

  const nextQuery = params.toString();
  const nextUrl = window.location.pathname + (nextQuery ? '?' + nextQuery : '') + window.location.hash;
  window.history.replaceState({}, '', nextUrl);
}

function updateArchiveShareLink(shareButton) {
  if (!shareButton) return;
  shareButton.setAttribute('data-copy-value', window.location.href);
}

function setArchiveParam(params, name, value) {
  if (value) {
    params.set(name, value);
  } else {
    params.delete(name);
  }
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
      const speaker = cleanSpeaker(cleanText(getItunesAuthor(item)));

      return {
        title,
        date: formatPubDate(rawDate),
        year: getYear(rawDate),
        rawDate,
        speaker,
        linkUrl: getEpisodeHref(cleanText(getElementText(item, 'link'))),
        audioUrl,
        audioType: getAudioType(audioUrl),
        description,
        searchText: [title, description, rawDate, speaker].join(' ').toLowerCase()
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

function filterSermons(query, year, audioOnly) {
  const needle = query.trim().toLowerCase();
  const selectedYear = year || '';
  return allSermons.filter(function(sermon) {
    const matchedSearch = !needle || sermon.searchText.indexOf(needle) !== -1;
    const matchedYear = !selectedYear || sermon.year === selectedYear;
    const matchedAudio = !audioOnly || !!sermon.audioUrl;
    return matchedSearch && matchedYear && matchedAudio;
  });
}

function renderSermons(container, sermons, sortMode) {
  container.innerHTML = '';
  const sortedSermons = sortSermons(sermons, sortMode || 'newest');
  updateCount(sortedSermons.length, allSermons.length);

  if (sortedSermons.length === 0) {
    container.innerHTML = '<div class="sermons-loading"><p>No sermons matched your search.</p></div>';
    return;
  }

  sortedSermons.forEach(function(sermon) {
    const card = document.createElement('article');
    card.className = 'sermon-item' + (sermon.audioUrl ? '' : ' no-audio');
    card.setAttribute('data-has-audio', sermon.audioUrl ? 'true' : 'false');
    if (sermon.year) {
      card.setAttribute('data-year', sermon.year);
    }

    const title = escapeHtml(sermon.title || 'Untitled sermon');
    let html = sermon.linkUrl
      ? '<h3><a href="' + escapeHtml(sermon.linkUrl) + '">' + title + '</a></h3>'
      : '<h3>' + title + '</h3>';
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
      html += '<div class="sermon-actions"><a href="' + escapeHtml(sermon.audioUrl) + '" class="sermon-download" download>Download Audio</a></div>';
    } else {
      html += '<p class="sermon-audio-missing">Audio is not attached to this archived feed item yet.</p>';
    }

    card.innerHTML = html;
    container.appendChild(card);
  });
}

function sortCards(cards, sortMode) {
  return cards.slice().sort(function(a, b) {
    if (sortMode === 'oldest') {
      return getCardTimestamp(a) - getCardTimestamp(b);
    }
    if (sortMode === 'title') {
      return getCardTitle(a).localeCompare(getCardTitle(b));
    }
    return getCardTimestamp(b) - getCardTimestamp(a);
  });
}

function getCardTimestamp(card) {
  const value = Number(card.getAttribute('data-sort-date') || '0');
  return Number.isFinite(value) ? value : 0;
}

function getCardTitle(card) {
  return card.getAttribute('data-title') || '';
}

function sortSermons(sermons, sortMode) {
  return sermons.slice().sort(function(a, b) {
    if (sortMode === 'oldest') {
      return getSermonTimestamp(a) - getSermonTimestamp(b);
    }
    if (sortMode === 'title') {
      return (a.title || '').toLowerCase().localeCompare((b.title || '').toLowerCase());
    }
    return getSermonTimestamp(b) - getSermonTimestamp(a);
  });
}

function getSermonTimestamp(sermon) {
  if (!sermon.rawDate) return 0;
  const timestamp = new Date(sermon.rawDate).getTime();
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function populateYearFilter(yearFilter, years) {
  if (!yearFilter) return;

  const currentValue = yearFilter.value;
  const uniqueYears = Array.from(new Set((years || []).filter(Boolean))).sort().reverse();
  yearFilter.innerHTML = '<option value="">All years</option>';
  uniqueYears.forEach(function(year) {
    const option = document.createElement('option');
    option.value = year;
    option.textContent = year;
    yearFilter.appendChild(option);
  });

  if (uniqueYears.indexOf(currentValue) !== -1) {
    yearFilter.value = currentValue;
  }
}

function updateCount(visible, total) {
  const count = document.getElementById('sermon-count');
  if (!count) return;

  if (!total) {
    count.textContent = '';
    return;
  }

  count.textContent = visible === total
    ? 'Showing all ' + total + ' archived messages'
    : 'Showing ' + visible + ' of ' + total + ' archived messages';
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

function getYear(dateStr) {
  if (!dateStr) return '';
  const date = new Date(dateStr);
  if (Number.isNaN(date.getTime())) return '';
  return String(date.getFullYear());
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

function cleanSpeaker(str) {
  const speaker = (str || '').replace(/\s+/g, ' ').trim();
  if (!speaker || /^thechurchco/i.test(speaker)) return 'Fillmore Christian';
  return speaker;
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
