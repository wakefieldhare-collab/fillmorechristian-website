/* ============================================
   Events Loader - Renders the self-hosted iCal feed
   ============================================ */

const CHURCH_CALENDAR_URL = 'events.ics';
const CHURCH_CALENDAR_VERSION = '20260604-03';

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
  try {
    const text = await getText(resolveSiteUrl(CHURCH_CALENDAR_URL + '?v=' + CHURCH_CALENDAR_VERSION));
    const events = getUpcomingEvents(parseIcsEvents(text), maxResults);

    if (events.length > 0) {
      renderEvents(container, events);
      return;
    }
  } catch (err) {
    console.error('Error loading local calendar:', err);
  }

  if (!container.querySelector('.event-item')) {
    container.innerHTML = getStaticEventsHtml();
  }
}

function parseIcsEvents(text) {
  const unfoldedLines = [];
  (text || '').split(/\r?\n/).forEach(function(line) {
    if (/^[ \t]/.test(line) && unfoldedLines.length > 0) {
      unfoldedLines[unfoldedLines.length - 1] += line.slice(1);
    } else {
      unfoldedLines.push(line);
    }
  });

  const events = [];
  let current = null;

  unfoldedLines.forEach(function(line) {
    if (line === 'BEGIN:VEVENT') {
      current = {};
      return;
    }

    if (line === 'END:VEVENT') {
      if (current && current.summary && current.start) {
        events.push(current);
      }
      current = null;
      return;
    }

    if (!current) return;

    const separatorIndex = line.indexOf(':');
    if (separatorIndex === -1) return;

    const property = line.slice(0, separatorIndex);
    const value = unescapeIcsText(line.slice(separatorIndex + 1));
    const name = property.split(';')[0].toUpperCase();

    if (name === 'SUMMARY') current.summary = value;
    if (name === 'DESCRIPTION') current.description = value;
    if (name === 'LOCATION') current.location = value;
    if (name === 'RRULE') current.rrule = value;
    if (name === 'DTSTART') current.start = parseIcsDate(value);
    if (name === 'DTEND') current.end = parseIcsDate(value);
    if (name === 'EXDATE') {
      current.exdates = current.exdates || [];
      String(value || '').split(',').forEach(function(exdate) {
        const parsed = parseIcsDate(exdate);
        if (parsed) current.exdates.push(parsed);
      });
    }
  });

  return events;
}

function getUpcomingEvents(events, maxResults) {
  const now = new Date();
  const limit = maxResults || 20;
  const expandedEvents = [];

  (events || []).forEach(function(event) {
    generateUpcomingOccurrences(event, now, limit).forEach(function(occurrence) {
      expandedEvents.push({
        summary: event.summary,
        description: event.description,
        location: event.location,
        start: occurrence.start,
        end: occurrence.end
      });
    });
  });

  return expandedEvents
    .sort(function(a, b) {
      return a.start.getTime() - b.start.getTime();
    })
    .slice(0, limit);
}

function generateUpcomingOccurrences(event, now, limit) {
  if (!event.start) return [];

  const start = new Date(event.start.getTime());
  const end = event.end
    ? new Date(event.end.getTime())
    : new Date(start.getTime() + 60 * 60 * 1000);
  const duration = end.getTime() - start.getTime();

  if (/FREQ=MONTHLY/.test(event.rrule || '')) {
    return generateMonthlyOccurrences(event, start, duration, now, limit);
  }

  if (!/FREQ=WEEKLY/.test(event.rrule || '')) {
    if (end.getTime() <= now.getTime()) {
      return [];
    }
    return [{ start, end }];
  }

  while (end.getTime() <= now.getTime()) {
    start.setDate(start.getDate() + 7);
    end.setDate(end.getDate() + 7);
  }

  const occurrences = [];
  for (let i = 0; i < limit; i += 1) {
    const occurrenceStart = new Date(start.getTime());
    if (!isExcludedOccurrence(event, occurrenceStart)) {
      occurrences.push({
        start: occurrenceStart,
        end: new Date(end.getTime())
      });
    }

    start.setDate(start.getDate() + 7);
    end.setDate(end.getDate() + 7);
  }

  return occurrences.map(function(occurrence) {
    return {
      start: occurrence.start,
      end: new Date(occurrence.start.getTime() + duration)
    };
  });
}

function generateMonthlyOccurrences(event, firstStart, duration, now, limit) {
  const monthlyRule = parseMonthlyByDayRule(event.rrule);
  if (!monthlyRule) {
    return [];
  }

  const occurrences = [];
  let cursor = new Date(firstStart.getFullYear(), firstStart.getMonth(), 1);
  let attempts = 0;

  while (occurrences.length < limit && attempts < limit + 36) {
    const candidate = getNthWeekdayOfMonth(
      cursor.getFullYear(),
      cursor.getMonth(),
      monthlyRule.weekday,
      monthlyRule.ordinal,
      firstStart.getHours(),
      firstStart.getMinutes(),
      firstStart.getSeconds()
    );

    if (candidate && candidate.getTime() >= firstStart.getTime()) {
      const candidateEnd = new Date(candidate.getTime() + duration);
      if (candidateEnd.getTime() > now.getTime() && !isExcludedOccurrence(event, candidate)) {
        occurrences.push({
          start: candidate,
          end: candidateEnd
        });
      }
    }

    cursor.setMonth(cursor.getMonth() + 1);
    attempts += 1;
  }

  return occurrences;
}

function parseMonthlyByDayRule(rrule) {
  const match = String(rrule || '').match(/BYDAY=([1-5])([A-Z]{2})/);
  if (!match) return null;

  const weekdays = {
    SU: 0,
    MO: 1,
    TU: 2,
    WE: 3,
    TH: 4,
    FR: 5,
    SA: 6
  };

  if (typeof weekdays[match[2]] !== 'number') return null;

  return {
    ordinal: Number(match[1]),
    weekday: weekdays[match[2]]
  };
}

function getNthWeekdayOfMonth(year, month, weekday, ordinal, hours, minutes, seconds) {
  const candidate = new Date(year, month, 1, hours, minutes, seconds || 0);
  const delta = (weekday - candidate.getDay() + 7) % 7;
  candidate.setDate(1 + delta + ((ordinal - 1) * 7));

  if (candidate.getMonth() !== month) return null;
  return candidate;
}

function renderEvents(container, events) {
  container.innerHTML = '';

  events.forEach(function(event) {
    const item = document.createElement('div');
    item.className = 'event-item';

    item.innerHTML =
      '<div class="event-date-box">' +
        '<span class="month">' + escapeHtml(formatMonth(event.start)) + '</span>' +
        '<span class="day">' + escapeHtml(String(event.start.getDate())) + '</span>' +
      '</div>' +
      '<div class="event-details">' +
        '<h4>' + escapeHtml(event.summary || 'Church event') + '</h4>' +
        '<span class="event-time">' + escapeHtml(formatEventTime(event.start, event.end)) + '</span>' +
        (event.description ? '<p>' + escapeHtml(event.description) + '</p>' : '') +
        (event.location ? '<p class="event-location">' + escapeHtml(event.location) + '</p>' : '') +
      '</div>';

    container.appendChild(item);
  });
}

function getStaticEventsHtml() {
  return '' +
    '<div class="event-item" data-static-event="true" data-recurring-event="sunday-school">' +
      '<div class="event-date-box event-date-box-recurring"><span class="month">Every</span><span class="day">Sun</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday School</h4>' +
        '<span class="event-time">Every Sunday at 9:00 AM</span>' +
        '<p>Classes for learning Scripture together before worship.</p>' +
      '</div>' +
    '</div>' +
    '<div class="event-item" data-static-event="true" data-recurring-event="first-sunday-fellowship-breakfast">' +
      '<div class="event-date-box event-date-box-recurring"><span class="month">First</span><span class="day">Sun</span></div>' +
      '<div class="event-details">' +
        '<h4>Fellowship Breakfast</h4>' +
        '<span class="event-time">First Sunday of the month at 9:45 AM - 10:10 AM</span>' +
        '<p>Join us for fellowship breakfast before worship on the first Sunday of each month.</p>' +
      '</div>' +
    '</div>' +
    '<div class="event-item" data-static-event="true" data-recurring-event="sunday-worship">' +
      '<div class="event-date-box event-date-box-recurring"><span class="month">Every</span><span class="day">Sun</span></div>' +
      '<div class="event-details">' +
        '<h4>Sunday Worship</h4>' +
        '<span class="event-time">Every Sunday at 10:00 AM</span>' +
        '<p>Gather with us for prayer, singing, communion, and preaching from Scripture.</p>' +
      '</div>' +
    '</div>' +
    '<div class="event-item" data-static-event="true" data-special-event="community-worship-duncan-park">' +
      '<div class="event-date-box"><span class="month">Jun</span><span class="day">21</span></div>' +
      '<div class="event-details">' +
        '<h4>Community Worship Service at Duncan Park</h4>' +
        '<span class="event-time">Sunday, June 21 at 10:00 AM</span>' +
        '<p>No regular Sunday School or Sunday worship at Fillmore Christian Church that morning. Join the community worship service at Duncan Park in Savannah, Missouri.</p>' +
      '</div>' +
    '</div>';
}

function isExcludedOccurrence(event, occurrenceStart) {
  return (event.exdates || []).some(function(exdate) {
    return sameLocalMinute(exdate, occurrenceStart);
  });
}

function sameLocalMinute(a, b) {
  return a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate() &&
    a.getHours() === b.getHours() &&
    a.getMinutes() === b.getMinutes();
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

function parseIcsDate(value) {
  const match = String(value || '').match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?)?/);
  if (!match) return null;

  return new Date(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4] || '0'),
    Number(match[5] || '0'),
    Number(match[6] || '0')
  );
}

function formatMonth(date) {
  return date.toLocaleDateString('en-US', { month: 'short' });
}

function formatEventTime(start, end) {
  const dateText = start.toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric'
  });
  const startText = start.toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true
  });
  const endText = end.toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true
  });

  return dateText + ' at ' + startText + ' - ' + endText;
}

function unescapeIcsText(value) {
  return String(value || '')
    .replace(/\\n/gi, '\n')
    .replace(/\\,/g, ',')
    .replace(/\\;/g, ';')
    .replace(/\\\\/g, '\\');
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str || ''));
  return div.innerHTML;
}
