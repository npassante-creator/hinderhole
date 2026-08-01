/**
 * test-parse.js
 * Offline checks for the parts that do not need network access.
 *   node test-parse.js
 */

const assert = require('assert');
const { parseSource, splitTitle, parseIsoDuration } = require('./resolver');

const urls = [
  ['https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'youtube', 'dQw4w9WgXcQ'],
  ['https://youtu.be/dQw4w9WgXcQ?t=42', 'youtube', 'dQw4w9WgXcQ'],
  ['https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share', 'youtube', 'dQw4w9WgXcQ'],
  ['https://www.youtube.com/shorts/dQw4w9WgXcQ', 'youtube', 'dQw4w9WgXcQ'],
  ['https://www.youtube.com/embed/dQw4w9WgXcQ', 'youtube', 'dQw4w9WgXcQ'],
  ['https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM', 'youtube', 'dQw4w9WgXcQ'],
  ['youtube.com/watch?v=dQw4w9WgXcQ', 'youtube', 'dQw4w9WgXcQ'],
  ['https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=abc123', 'spotify', '4cOdK2wGLETKBW3PvgPWqT'],
  ['https://open.spotify.com/intl-de/track/4cOdK2wGLETKBW3PvgPWqT', 'spotify', '4cOdK2wGLETKBW3PvgPWqT'],
  ['spotify:track:4cOdK2wGLETKBW3PvgPWqT', 'spotify', '4cOdK2wGLETKBW3PvgPWqT'],
];

let pass = 0;
for (const [url, source, id] of urls) {
  const got = parseSource(url);
  assert.ok(got, `failed to parse: ${url}`);
  assert.strictEqual(got.source, source, url);
  assert.strictEqual(got.external_id, id, url);
  pass++;
}

const rejects = [
  'https://soundcloud.com/artist/track',
  'https://www.youtube.com/playlist?list=PLabc',
  'https://open.spotify.com/album/4cOdK2wGLETKBW3PvgPWqT',
  'just some text',
  '',
  null,
];
for (const bad of rejects) {
  assert.strictEqual(parseSource(bad), null, `should have rejected: ${bad}`);
  pass++;
}

const titles = [
  ['Rick Astley - Never Gonna Give You Up (Official Video)', 'Rick Astley Official',
   'Rick Astley', 'Never Gonna Give You Up'],
  ['Radiohead - Idioteque [Official Audio]', 'Radiohead',
   'Radiohead', 'Idioteque'],
  ['Blackbird', 'The Beatles - Topic', 'The Beatles', 'Blackbird'],
  ['Learning to Fly (Remastered 2019)', 'Tom Petty', 'Tom Petty', 'Learning to Fly'],
];
for (const [raw, channel, artist, title] of titles) {
  const got = splitTitle(raw, channel);
  assert.strictEqual(got.artist, artist, raw);
  assert.strictEqual(got.title, title, raw);
  pass++;
}

assert.strictEqual(parseIsoDuration('PT3M33S'), 213);
assert.strictEqual(parseIsoDuration('PT1H2M3S'), 3723);
assert.strictEqual(parseIsoDuration('PT45S'), 45);
assert.strictEqual(parseIsoDuration('garbage'), null);
pass += 4;

console.log(`All ${pass} checks passed.`);
