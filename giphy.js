/**
 * giphy.js
 *
 * A thin proxy in front of Giphy.
 *
 * Three reasons this is not called from the browser directly:
 *
 *   1. The key stays on the server. A key in page source is a key that
 *      gets scraped and burned through.
 *   2. Beta keys are limited to roughly 100 searches an hour. A short
 *      cache means twenty people typing "yes" all hour costs one call.
 *   3. Whatever the browser sends us has to be checked anyway, so the
 *      allowed hosts live in one place.
 */

'use strict';

const KEY = process.env.GIPHY_API_KEY || '';
const TTL_MS = 10 * 60 * 1000;
const CACHE_MAX = 200;

// Only these hosts can ever end up in a message.
const ALLOWED_HOSTS = new Set([
  'media.giphy.com',
  'media0.giphy.com', 'media1.giphy.com', 'media2.giphy.com',
  'media3.giphy.com', 'media4.giphy.com',
  'i.giphy.com',
]);

const cache = new Map();

function cacheGet(key) {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() > hit.until) { cache.delete(key); return null; }
  // Refresh recency so the map's insertion order acts as an LRU.
  cache.delete(key);
  cache.set(key, hit);
  return hit.value;
}

function cacheSet(key, value) {
  cache.set(key, { value, until: Date.now() + TTL_MS });
  while (cache.size > CACHE_MAX) {
    cache.delete(cache.keys().next().value);
  }
}

/** True if a URL is one we are willing to render in a message. */
function isAllowed(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && ALLOWED_HOSTS.has(u.hostname);
  } catch {
    return false;
  }
}

/** Trim Giphy's response to the few fields a chat bubble needs. */
function shape(data) {
  return (data.data || []).map((g) => {
    const img = (g.images && (g.images.fixed_width || g.images.downsized)) || {};
    return {
      id: g.id,
      url: img.url,
      w: Number(img.width) || null,
      h: Number(img.height) || null,
      alt: g.title || 'GIF',
    };
  }).filter((g) => g.url && isAllowed(g.url));
}

async function fetchGiphy(path, params) {
  if (!KEY) throw new Error('No Giphy key configured.');

  const qs = new URLSearchParams({
    api_key: KEY,
    limit: '24',
    rating: 'pg-13',
    bundle: 'messaging_non_clips',
    ...params,
  });

  const key = path + '?' + qs.toString().replace(/api_key=[^&]*&?/, '');
  const hit = cacheGet(key);
  if (hit) return hit;

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 6000);
  try {
    const res = await fetch(`https://api.giphy.com/v1/gifs/${path}?${qs}`,
      { signal: ctrl.signal });
    if (!res.ok) {
      const err = new Error(res.status === 429
        ? 'Giphy is rate limiting us. Try again in a minute.'
        : 'Giphy is not answering.');
      err.status = res.status;
      throw err;
    }
    const out = shape(await res.json());
    cacheSet(key, out);
    return out;
  } finally {
    clearTimeout(timer);
  }
}

const search = (q) => fetchGiphy('search', { q, offset: '0' });
const trending = () => fetchGiphy('trending', {});

module.exports = { search, trending, isAllowed, enabled: Boolean(KEY) };
