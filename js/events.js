/* ============================================
   Events Loader - Fetches from Google Calendar
   ============================================ */

const GOOGLE_CALENDAR_ID = '';
const GOOGLE_API_KEY = '';

document.addEventListener('DOMContentLoaded', function() {
  const upcomingContainer = document.getElementById('upcoming-events');
  if (upcomingContainer) {
    loadUpcomingEvents(upcomingContainer, 5);
  }

  const eventsPageContainer = document.getElementById('events-full-list');
  if (eventsPageContainer) {
    loadUpcomingEvents(eventsPageContainer, 20);
  }
});

async function loadUpcomingEvents(container, maxResults) {
  if (!GOOGLE_CALENDAR_ID || !GOOGLE_API_KEY) {
    if (!container.querySelector('.event-item')) {
      container.innerHTML = getStaticEventsHtml();
    }
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

    const text = await getText(url);
    const data = JSON.parse(text);

    if (data.items && data.items.length > 0) {
      renderEvents(container, data.items);
    } else {
      container.innerHTML = getStaticEventsHtml();
    }
  } catch (err) {
    console.error('Error loading events:', err);
    if (!container.querySelector('.event-item')) {
      container.innerHTML = getStaticEventsHtml();
    }
  }
}

function renderEvents(container, events) {
  container.innerHTML = '';

  events.forEach(function(event) {
    const start = event.start.dateTime || event.start.date;
    const date = new Date(start);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const item = document.createElement('div');
    item.className = 'event-item';

    const timeStr = event.start.dateTime
      ? date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
      : 'All day';

    item.innerHTML =
      '<div class="event-date-box">' +
        '<span class="month">' + months[date.getMonth()] + '</span>' +
        '<span class="day">' + date.getDate() + '</span>' +
      '</div>' +
      '<div class="event-details">' +
        '<h4>' + escapeHtml(event.summary || 'Untitled event') + '</h4>' +
        '<span class="event-time">' + escapeHtml(timeStr) + '</span>' +
        (event.description ? '<p>' + escapeHtml(event.description.substring(0, 150)) + '</p>' : '') +
      '</div>';

    container.appendChild(item);
  });
}

function getStaticEventsHtml() {
  return '' +
    '<div class="event-item" data-static-event="true">' +
      '<div class="event-date-box"><span class="month">Sun</span><span class="day">9</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday School</h4>' +
        '<span class="event-time">Every Sunday at 9:00 AM</span>' +
        '<p>Classes for learning Scripture together before worship.</p>' +
      '</div>' +
    '</div>' +
    '<div class="event-item" data-static-event="true">' +
      '<div class="event-date-box"><span class="month">Sun</span><span class="day">10</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday Worship</h4>' +
        '<span class="event-time">Every Sunday at 10:00 AM</span>' +
        '<p>Gather with us for prayer, singing, communion, and preaching from Scripture.</p>' +
      '</div>' +
    '</div>';
}

function getText(url) {
  if (typeof window.fetch === 'function') {
    return window.fetch(url).then(function(response) {
      if (!response.ok) throw new Error('Calendar request failed: ' + response.status);
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
        reject(new Error('Calendar request failed: ' + request.status));
      }
    };
    request.onerror = function() {
      reject(new Error('Calendar request failed.'));
    };
    request.send();
  });
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str || ''));
  return div.innerHTML;
}
