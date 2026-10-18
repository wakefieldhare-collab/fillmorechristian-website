import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { announcementCards, renderAnnouncementsPage } from './lib/announcements.mjs';
const root = new URL('../', import.meta.url);
const data = JSON.parse(fs.readFileSync(new URL('announcements.json', root), 'utf8'));
const template = '<span data-announcements-service-date>this Sunday</span><p data-announcements-updated>Updated weekly</p><div data-announcements-list data-announcements-limit="1"><p data-announcements-fallback hidden>Unavailable</p></div>';
test('build output contains the published announcements before JavaScript runs', () => {
  for (const [page, count] of [['index.html', Math.min(3, data.announcements.length)], ['announcements.html', data.announcements.length]]) {
    const html = fs.readFileSync(new URL('dist/' + page, root), 'utf8');
    assert.equal((html.match(/class="announcement-card"/g) || []).length, count);
    for (const item of data.announcements.slice(0, count)) assert.ok(html.includes(item.title));
    assert.ok(!html.includes('Please enable JavaScript to view current announcements'));
  }
});
test('a new publication changes initial HTML, the preview limit and dates', () => {
  const next = { ...data, service_date: '2026-10-25', updated_at: '2026-10-18', announcements: [{title:'New announcement', when:'Next Sunday', details:'Fresh details'}, ...data.announcements] };
  const html = renderAnnouncementsPage(template, next);
  assert.ok(html.includes('Sunday, October 25, 2026'));
  assert.ok(html.includes('Updated October 18, 2026'));
  assert.ok(html.includes('New announcement'));
  assert.equal((html.match(/class="announcement-card"/g) || []).length, 1);
  assert.ok(html.includes('data-announcements-fallback hidden'));
});
test('announcement text and links cannot inject HTML or active URLs', () => {
  const hostile = { ...data, announcements: [{title:'<script>alert(1)</script>', when:'"date"', details:'<img src=x onerror=alert(1)> & details', url:'https://example.com/?a=1&b=2', link_label:'<b>Open</b>'}] };
  const html = announcementCards(hostile);
  assert.ok(!html.includes('<script>') && !html.includes('<img'));
  assert.ok(html.includes('&lt;script&gt;') && html.includes('&amp;b=2'));
  assert.ok(html.includes('&lt;b&gt;Open&lt;/b&gt;'));
  assert.throws(() => announcementCards({ ...hostile, announcements: [{ ...hostile.announcements[0], url:'javascript:alert(1)' }] }));
  assert.throws(() => announcementCards({ ...hostile, announcements: [{ ...hostile.announcements[0], url:'/relative' }] }));
});
test('empty and invalid data have explicit outcomes', () => {
  assert.ok(announcementCards({ ...data, announcements: [] }).includes('There are no current announcements.'));
  assert.throws(() => announcementCards({ ...data, announcements: null }));
  assert.throws(() => announcementCards({ ...data, announcements: [{ title: 'Incomplete' }] }));
});
