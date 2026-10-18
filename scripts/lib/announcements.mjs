const escapeHtml = value => String(value).replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[character]);

export function validateAnnouncementData(data) {
  if (data?.schema_version !== 1 || !/^\d{4}-\d{2}-\d{2}$/.test(data.service_date || '') ||
      !Array.isArray(data.announcements)) throw new Error('Invalid announcement data.');
  for (const item of data.announcements) {
    if (!item || !['title', 'when', 'details'].every(key => typeof item[key] === 'string' && item[key].trim())) {
      throw new Error('Every announcement needs a title, date and details.');
    }
    if (item.url && new URL(item.url).protocol !== 'https:') throw new Error('Announcement links must use HTTPS.');
  }
}

function formatDate(value, weekday = true) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) return null;
  return new Intl.DateTimeFormat('en-US', {
    ...(weekday ? { weekday: 'long' } : {}), month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC'
  }).format(new Date(value + 'T12:00:00Z'));
}

export function announcementCards(data, limit) {
  validateAnnouncementData(data);
  const items = Number.isFinite(limit) ? data.announcements.slice(0, limit) : data.announcements;
  if (!items.length) return '<p class="announcements-empty">There are no current announcements. Please check back after Sunday worship.</p>';
  return items.map(item => '<article class="announcement-card">' +
    '<p class="announcement-when">' + escapeHtml(item.when) + '</p>' +
    '<h3>' + escapeHtml(item.title) + '</h3>' +
    '<p>' + escapeHtml(item.details) + '</p>' +
    (item.location ? '<p class="announcement-location">' + escapeHtml(item.location) + '</p>' : '') +
    (item.url ? '<a class="announcement-link" href="' + escapeHtml(item.url) + '" target="_blank" rel="noopener">' + escapeHtml(item.link_label || 'Learn more') + '</a>' : '') +
    '</article>').join('\n');
}

export function renderAnnouncementsPage(html, data) {
  validateAnnouncementData(data);
  return html.replace(/(<div\b[^>]*\bdata-announcements-list\b[^>]*>)([\s\S]*?)(<\/div>)/g, (_, open, content, close) => {
    const limit = /data-announcements-limit="(\d+)"/.exec(open);
    const fallback = /<p\b[^>]*data-announcements-fallback\b[^>]*>[\s\S]*?<\/p>/.exec(content)?.[0] || '';
    return open + '\n' + announcementCards(data, limit ? Number(limit[1]) : undefined) + '\n' + fallback + '\n' + close;
  }).replace(/(<span\b[^>]*data-announcements-service-date[^>]*>)[\s\S]*?(<\/span>)/g,
    (_, open, close) => open + escapeHtml(formatDate(data.service_date)) + close)
    .replace(/(<p\b[^>]*data-announcements-updated[^>]*>)[\s\S]*?(<\/p>)/g,
      (_, open, close) => open + escapeHtml(data.updated_at ? 'Updated ' + formatDate(data.updated_at, false) : 'Updated weekly') + close);
}
