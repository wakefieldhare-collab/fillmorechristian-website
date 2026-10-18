import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const root = new URL('../', import.meta.url);
const context = vm.createContext({ document: { addEventListener() {} }, console });
vm.runInContext(fs.readFileSync(new URL('js/events.js', root), 'utf8'), context);
const events = context.parseIcsEvents(fs.readFileSync(new URL('events.ics', root), 'utf8'));
const schools = events.filter(event => event.summary === 'Sunday School');
assert.equal(schools.length, 2);
const occurrences = schools.flatMap(event => context.generateUpcomingOccurrences(event, new Date(2026, 5, 1), 100));
// Verify every Sunday in a full year, including five-Sunday months and DST changes.
let checked = 0;
for (let date = new Date(2026, 5, 7); date < new Date(2027, 5, 1); date.setDate(date.getDate() + 7)) {
  const key = `${date.getFullYear()}-${date.getMonth()+1}-${date.getDate()}`;
  const found = occurrences.filter(event => event.start.getFullYear() === date.getFullYear() && event.start.getMonth() === date.getMonth() && event.start.getDate() === date.getDate());
  const cancelled = ['2026-6-21', '2026-8-2', '2026-10-4'].includes(key);
  assert.equal(found.length, cancelled ? 0 : 1, `one class per Sunday: ${key}`);
  if (cancelled) continue;
  assert.equal(found[0].start.getHours(), 9, key);
  assert.equal(found[0].start.getMinutes(), 0, key);
  assert.equal(found[0].end.getHours(), 9, key);
  assert.equal(found[0].end.getMinutes(), date.getDate() <= 7 ? 45 : 50, key);
  checked += 1;
}
// A class in progress must remain visible until its actual end time.
const regular = schools.find(event => event.rrule.includes('2SU'));
const first = schools.find(event => event.rrule === 'FREQ=MONTHLY;BYDAY=1SU');
assert.equal(context.generateUpcomingOccurrences(regular, new Date(2026, 9, 18, 9, 49), 1)[0].start.getDate(), 18);
assert.equal(context.generateUpcomingOccurrences(regular, new Date(2026, 9, 18, 9, 50), 1)[0].start.getDate(), 25);
assert.equal(context.generateUpcomingOccurrences(first, new Date(2026, 10, 1, 9, 44), 1)[0].start.getDate(), 1);
assert.equal(context.generateUpcomingOccurrences(first, new Date(2026, 10, 1, 9, 45), 1)[0].start.getMonth(), 11);
for (const name of ['index.html', 'events.html']) {
  const html = fs.readFileSync(new URL(name, root), 'utf8');
  const data = JSON.parse(html.match(/<script type="application\/ld\+json">\s*([\s\S]*?)\s*<\/script>/)[1]);
  const events = data.event || data.itemListElement.map(item => item.item);
  const schedules = events.find(event => event.name === 'Sunday School').eventSchedule;
  assert.equal(schedules.length, 2);
  assert.equal(schedules.find(schedule => schedule.byMonthWeek === 1).endTime, '09:45');
  assert.equal(schedules.find(schedule => Array.isArray(schedule.byMonthWeek)).endTime, '09:50');
}
const contactCard = fs.readFileSync(new URL('contact.vcf', root), 'utf8').replace(/\r?\n[ \t]/g, '');
assert.ok(contactCard.includes('9:00 to 9:50 AM (9:45 AM on first Sundays for Fellowship Breakfast)'));
console.log(`Sunday School schedule passed: ${checked} classes, cancellations, first Sundays, five-Sunday months, and end-time boundaries.`);
