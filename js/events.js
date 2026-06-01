/* ============================================
   Events Loader - Fetches from Google Calendar
   ============================================

   HOW IT WORKS:
   This script fetches upcoming events from a public Google Calendar
   and displays them on the website.

   SETUP:
   1. Create a Google Calendar for the church
   2. Make it public (Settings > Access permissions > Make available to public)
   3. Get the Calendar ID (Settings > Integrate calendar > Calendar ID)
   4. Get a Google API key from https://console.cloud.google.com
      - Create a project, enable Google Calendar API, create an API key
      - Restrict the key to Calendar API and your domain
   5. Set both values below

   If no API key is configured, the page will show a Google Calendar embed instead.
*/

// *** CONFIGURE YOUR GOOGLE CALENDAR HERE ***
const GOOGLE_CALENDAR_ID = ''; // e.g., 'your-church@group.calendar.google.com'
const GOOGLE_API_KEY = '';      // e.g., 'AIzaSy...'

document.addEventListener('DOMContentLoaded', function() {
  // Load events on homepage upcoming events section
  const upcomingContainer = document.getElementById('upcoming-events');
  if (upcomingContainer) {
    loadUpcomingEvents(upcomingContainer, 5);
  }

  // Load events on the full events page
  const eventsPageContainer = document.getElementById('events-full-list');
  if (eventsPageContainer) {
    loadUpcomingEvents(eventsPageContainer, 20);
  }
});

async function loadUpcomingEvents(container, maxResults) {
  if (!GOOGLE_CALENDAR_ID || !GOOGLE_API_KEY) {
    // Show placeholder if not configured
    container.innerHTML = getPlaceholderEventsHtml();
    return;
  }

  container.innerHTML = '<div class="events-empty">Loading events...</div>';

  try {
    const now = new Date().toISOString();
    const url = 'https://www.googleapis.com/calendar/v3/calendars/' +
      encodeURIComponent(GOOGLE_CALENDAR_ID) +
      '/events?key=' + GOOGLE_API_KEY +
      '&timeMin=' + now +
      '&maxResults=' + maxResults +
      '&singleEvents=true&orderBy=startTime';

    const response = await fetch(url);
    const data = await response.json();

    if (data.items && data.items.length > 0) {
      renderEvents(container, data.items);
    } else {
      container.innerHTML = '<div class="events-empty">No upcoming events at this time. Check back soon!</div>';
    }
  } catch (err) {
    console.error('Error loading events:', err);
    container.innerHTML = '<div class="events-empty">Unable to load events. Please try again later.</div>';
  }
}

function renderEvents(container, events) {
  container.innerHTML = '';

  events.forEach(function(event) {
    const start = event.start.dateTime || event.start.date;
    const date = new Date(start);

    const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];

    const item = document.createElement('div');
    item.className = 'event-item';

    let timeStr = '';
    if (event.start.dateTime) {
      timeStr = date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
    } else {
      timeStr = 'All Day';
    }

    item.innerHTML =
      '<div class="event-date-box">' +
        '<span class="month">' + months[date.getMonth()] + '</span>' +
        '<span class="day">' + date.getDate() + '</span>' +
      '</div>' +
      '<div class="event-details">' +
        '<h4>' + escapeHtml(event.summary || 'Untitled Event') + '</h4>' +
        '<span class="event-time">' + timeStr + '</span>' +
        (event.description ? '<p style="margin-top:0.3em;color:#666;font-size:0.9rem;">' + escapeHtml(event.description.substring(0, 150)) + '</p>' : '') +
      '</div>';

    container.appendChild(item);
  });
}

function getPlaceholderEventsHtml() {
  // Show some placeholder events until Google Calendar is configured
  return '' +
    '<div class="event-item">' +
      '<div class="event-date-box"><span class="month">SUN</span><span class="day">—</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday Worship</h4>' +
        '<span class="event-time">Every Sunday at 10:00 AM</span>' +
      '</div>' +
    '</div>' +
    '<div class="event-item">' +
      '<div class="event-date-box"><span class="month">SUN</span><span class="day">—</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday School</h4>' +
        '<span class="event-time">Every Sunday at 9:00 AM</span>' +
      '</div>' +
    '</div>' +
    '<p style="text-align:center;margin-top:1em;font-size:0.85rem;color:#999;">Events will auto-populate once Google Calendar is connected. See <code>js/events.js</code> for setup.</p>';
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str));
  return div.innerHTML;
}
