/* ============================================
   Sermon Loader - Fetches from podcast RSS feed
   ============================================

   HOW IT WORKS:
   This script fetches the church's podcast RSS feed and displays
   sermon episodes with audio players on the website.

   SETUP:
   1. Set your podcast RSS feed URL below (from Spotify for Podcasters, etc.)
   2. The script will auto-load and display all episodes

   If no RSS feed is configured yet, it shows sample placeholder sermons.
*/

// The legacy ChurchCo/Apple Podcasts feed path is preserved on the static site.
const PODCAST_RSS_URL = '/podcast-category/fillmore-christian/feed/podcast';

// Fallback: If no RSS feed is set, use local sermon data
const LOCAL_SERMONS = [
  // Add sermons here manually if not using an RSS feed:
  // { title: 'Sermon Title', date: '2026-03-15', speaker: 'Wakefield Hare', audioUrl: 'path/to/audio.mp3', description: 'Brief description' },
];

document.addEventListener('DOMContentLoaded', function() {
  const container = document.getElementById('sermons-container');
  if (!container) return;

  if (PODCAST_RSS_URL) {
    loadFromRSS(container);
  } else if (LOCAL_SERMONS.length > 0) {
    renderSermons(container, LOCAL_SERMONS);
  } else {
    container.innerHTML = '<div class="sermons-loading">' +
      '<p>Sermons will appear here once the podcast RSS feed is configured.</p>' +
      '<p style="margin-top:0.5em;font-size:0.9rem;">See the setup guide in <code>js/sermons.js</code> for instructions.</p>' +
      '</div>';
  }
});

async function loadFromRSS(container) {
  container.innerHTML = '<div class="sermons-loading"><p>Loading sermons...</p></div>';

  try {
    // Use a CORS proxy for client-side RSS fetching
    // Option 1: Direct fetch (works if RSS host allows CORS)
    let response;
    try {
      response = await fetch(PODCAST_RSS_URL);
    } catch (e) {
      // Option 2: Use allorigins proxy as fallback
      const proxyUrl = 'https://api.allorigins.win/raw?url=' + encodeURIComponent(PODCAST_RSS_URL);
      response = await fetch(proxyUrl);
    }

    const text = await response.text();
    const parser = new DOMParser();
    const xml = parser.parseFromString(text, 'text/xml');
    const items = xml.querySelectorAll('item');

    const sermons = [];
    items.forEach(function(item) {
      const enclosure = item.querySelector('enclosure');
      sermons.push({
        title: getElementText(item, 'title'),
        date: formatPubDate(getElementText(item, 'pubDate')),
        rawDate: getElementText(item, 'pubDate'),
        speaker: getItunesAuthor(item) || 'Fillmore Christian Church',
        audioUrl: enclosure ? enclosure.getAttribute('url') : '',
        description: getElementText(item, 'description') || getElementText(item, 'itunes\\:summary') || ''
      });
    });

    if (sermons.length === 0) {
      container.innerHTML = '<div class="sermons-loading"><p>No sermons found in the feed.</p></div>';
    } else {
      renderSermons(container, sermons);
    }
  } catch (err) {
    console.error('Error loading sermons:', err);
    container.innerHTML = '<div class="sermons-loading">' +
      '<p>Unable to load sermons at this time. Please try again later.</p>' +
      '</div>';
  }
}

function renderSermons(container, sermons) {
  container.innerHTML = '';

  sermons.forEach(function(sermon) {
    const card = document.createElement('div');
    card.className = 'sermon-item';

    let html = '<h3>' + escapeHtml(sermon.title) + '</h3>';
    html += '<div class="sermon-meta">';
    html += '<span>' + escapeHtml(sermon.date || sermon.rawDate || '') + '</span>';
    if (sermon.speaker) {
      html += ' &middot; <span>' + escapeHtml(sermon.speaker) + '</span>';
    }
    html += '</div>';

    if (sermon.description) {
      // Truncate long descriptions
      const desc = sermon.description.length > 200
        ? sermon.description.substring(0, 200) + '...'
        : sermon.description;
      html += '<p class="sermon-description">' + escapeHtml(stripHtml(desc)) + '</p>';
    }

    if (sermon.audioUrl) {
      html += '<audio controls preload="none"><source src="' + escapeHtml(sermon.audioUrl) + '" type="audio/mpeg">Your browser does not support audio playback.</audio>';
    }

    card.innerHTML = html;
    container.appendChild(card);
  });
}

// Helper functions
function getElementText(parent, tagName) {
  const el = parent.querySelector(tagName);
  return el ? el.textContent.trim() : '';
}

function getItunesAuthor(item) {
  // Try itunes:author first, then author
  const itunesAuthor = item.querySelector('itunes\\:author, author');
  return itunesAuthor ? itunesAuthor.textContent.trim() : '';
}

function formatPubDate(dateStr) {
  if (!dateStr) return '';
  try {
    const date = new Date(dateStr);
    return date.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    });
  } catch (e) {
    return dateStr;
  }
}

function stripHtml(str) {
  const tmp = document.createElement('div');
  tmp.innerHTML = str;
  return tmp.textContent || tmp.innerText || '';
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str));
  return div.innerHTML;
}
