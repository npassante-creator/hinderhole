/**
 * resolver.js
 *
 * Turns whatever a player pastes into a normalized submission record.
 *
 *   const { resolve } = require('./resolver');
 *   await resolve('https://youtu.be/dQw4w9WgXcQ?t=42');
 *
 *   {
 *     source:        'youtube',
 *     external_id:   'dQw4w9WgXcQ',
 *     source_url:    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
 *     embed_url:     'https://www.youtube.com/embed/dQw4w9WgXcQ',
 *     title:         'Never Gonna Give You Up',
 *     artist:        'Rick Astley',
 *     artist_guessed: true,
 *     thumbnail_url: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
 *     duration_s:    213,
 *     raw_title:     'Rick Astley - Never Gonna Give You Up (Official Video)'
 *   }
 *
 * Works with no API keys at all using public oEmbed endpoints.
 * Set YOUTUBE_API_KEY for real durations, and SPOTIFY_CLIENT_ID /
 * SPOTIFY_CLIENT_SECRET for clean artist names and durations.
 *
 * Node 18+ (uses global fetch).
 */

'use strict';

const TIMEOUT_MS = 8000;

// ---------------------------------------------------------------
// URL parsing
// ---------------------------------------------------------------

const YT_HOSTS = new Set([
  'youtube.com', 'www.youtube.com', 'm.youtube.com',
  'music.youtube.com', 'youtu.be', 'www.youtu.be',
]);

const SPOTIFY_HOSTS = new Set(['open.spotify.com', 'play.spotify.com']);

const YT_ID = /^[A-Za-z0-9_-]{11}$/;
const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;

/**
 * Identify the source and extract the bare id. Returns null if the URL
 * is not something we know how to embed.
 */
function parseSource(input) {
  if (!input || typeof input !== 'string') return null;
  const raw = input.trim();

  // spotify:track:ID URI form
  const uri = raw.match(/^spotify:track:([A-Za-z0-9]{22})$/);
  if (uri) return { source: 'spotify', external_id: uri[1] };

  let url;
  try {
    url = new URL(raw.startsWith('http') ? raw : `https://${raw}`);
  } catch {
    return null;
  }

  const host = url.hostname.toLowerCase();

  if (YT_HOSTS.has(host)) {
    let id = null;

    if (host === 'youtu.be' || host === 'www.youtu.be') {
      id = url.pathname.slice(1).split('/')[0];
    } else if (url.pathname === '/watch') {
      id = url.searchParams.get('v');
    } else {
      // /shorts/ID, /embed/ID, /live/ID, /v/ID
      const m = url.pathname.match(/^\/(?:shorts|embed|live|v)\/([^/?#]+)/);
      if (m) id = m[1];
    }

    if (id && YT_ID.test(id)) return { source: 'youtube', external_id: id };
    return null;
  }

  if (SPOTIFY_HOSTS.has(host)) {
    // /track/ID and the localized /intl-de/track/ID form
    const m = url.pathname.match(/\/track\/([A-Za-z0-9]{22})/);
    if (m && SPOTIFY_ID.test(m[1])) {
      return { source: 'spotify', external_id: m[1] };
    }
    return null;
  }

  return null;
}

function canonicalUrl(source, id) {
  return source === 'youtube'
    ? `https://www.youtube.com/watch?v=${id}`
    : `https://open.spotify.com/track/${id}`;
}

function embedUrl(source, id) {
  return source === 'youtube'
    ? `https://www.youtube.com/embed/${id}`
    : `https://open.spotify.com/embed/track/${id}`;
}

// ---------------------------------------------------------------
// Title cleanup
// ---------------------------------------------------------------

const NOISE = new RegExp(
  '\\s*[\\(\\[]\\s*(official\\s*)?(music\\s*)?' +
  '(video|audio|lyric\\s*video|lyrics|visualizer|hd|hq|4k|remaster(ed)?' +
  '(\\s*\\d{4})?|full\\s*album\\s*stream|explicit|clean)\\s*[\\)\\]]',
  'gi'
);

/**
 * YouTube titles are freeform. Best effort split into artist and track.
 * Always flagged as guessed so the UI can let the submitter correct it.
 */
function splitTitle(rawTitle, channelName) {
  const cleaned = String(rawTitle || '')
    .replace(NOISE, '')
    .replace(/\s*\|\s*.*$/, '')
    .replace(/\s{2,}/g, ' ')
    .trim();

  const dash = cleaned.match(/^(.{1,80}?)\s+[-–—]\s+(.+)$/);
  if (dash) {
    return { artist: dash[1].trim(), title: dash[2].trim(), guessed: true };
  }

  // Channels like "Rick Astley - Topic" are auto-generated and reliable.
  const topic = String(channelName || '').match(/^(.*?)\s*-\s*Topic$/);
  if (topic) {
    return { artist: topic[1].trim(), title: cleaned, guessed: false };
  }

  return { artist: channelName || null, title: cleaned, guessed: true };
}

/** Parses ISO 8601 durations like PT4M13S into seconds. */
function parseIsoDuration(iso) {
  const m = String(iso || '').match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/);
  if (!m) return null;
  return (+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0);
}

// ---------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------

async function getJson(url, options = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { ...options, signal: ctrl.signal });
    if (!res.ok) {
      const err = new Error(`HTTP ${res.status} from ${new URL(url).hostname}`);
      err.status = res.status;
      throw err;
    }
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

async function resolveYouTube(id) {
  const out = {
    source: 'youtube',
    external_id: id,
    source_url: canonicalUrl('youtube', id),
    embed_url: embedUrl('youtube', id),
    thumbnail_url: `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
    duration_s: null,
  };

  if (process.env.YOUTUBE_API_KEY) {
    const api =
      'https://www.googleapis.com/youtube/v3/videos' +
      `?part=snippet,contentDetails&id=${id}&key=${process.env.YOUTUBE_API_KEY}`;
    const data = await getJson(api);
    const item = data.items && data.items[0];
    if (!item) throw new Error('Video not found, or it is private');

    const parts = splitTitle(item.snippet.title, item.snippet.channelTitle);
    return {
      ...out,
      raw_title: item.snippet.title,
      title: parts.title,
      artist: parts.artist,
      artist_guessed: parts.guessed,
      duration_s: parseIsoDuration(item.contentDetails.duration),
      thumbnail_url:
        (item.snippet.thumbnails.maxres || item.snippet.thumbnails.high || {})
          .url || out.thumbnail_url,
    };
  }

  // No key: oEmbed gives title, channel, and a thumbnail. No duration.
  const oe = await getJson(
    'https://www.youtube.com/oembed?format=json&url=' +
      encodeURIComponent(out.source_url)
  );
  const parts = splitTitle(oe.title, oe.author_name);
  return {
    ...out,
    raw_title: oe.title,
    title: parts.title,
    artist: parts.artist,
    artist_guessed: parts.guessed,
    thumbnail_url: oe.thumbnail_url || out.thumbnail_url,
  };
}

let spotifyToken = { value: null, expires: 0 };

async function spotifyAccessToken() {
  const { SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET } = process.env;
  if (!SPOTIFY_CLIENT_ID || !SPOTIFY_CLIENT_SECRET) return null;
  if (spotifyToken.value && Date.now() < spotifyToken.expires) {
    return spotifyToken.value;
  }

  const basic = Buffer.from(
    `${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}`
  ).toString('base64');

  const data = await getJson('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  });

  spotifyToken = {
    value: data.access_token,
    expires: Date.now() + (data.expires_in - 60) * 1000,
  };
  return spotifyToken.value;
}

async function resolveSpotify(id) {
  const out = {
    source: 'spotify',
    external_id: id,
    source_url: canonicalUrl('spotify', id),
    embed_url: embedUrl('spotify', id),
    thumbnail_url: null,
    duration_s: null,
  };

  const token = await spotifyAccessToken();
  if (token) {
    const t = await getJson(`https://api.spotify.com/v1/tracks/${id}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    return {
      ...out,
      raw_title: t.name,
      title: t.name,
      artist: t.artists.map((a) => a.name).join(', '),
      artist_guessed: false,
      duration_s: Math.round(t.duration_ms / 1000),
      thumbnail_url: (t.album.images[0] || {}).url || null,
    };
  }

  // No credentials: oEmbed gives a title and cover art, no artist field.
  const oe = await getJson(
    'https://open.spotify.com/oembed?url=' + encodeURIComponent(out.source_url)
  );
  const parts = splitTitle(oe.title, null);
  return {
    ...out,
    raw_title: oe.title,
    title: parts.title,
    artist: parts.artist,
    artist_guessed: true,
    thumbnail_url: oe.thumbnail_url || null,
  };
}

// ---------------------------------------------------------------
// Public API
// ---------------------------------------------------------------

class UnsupportedSourceError extends Error {
  constructor(input) {
    super('That link is not a YouTube or Spotify track. Paste a video or ' +
          'track URL, or upload an audio file instead.');
    this.name = 'UnsupportedSourceError';
    this.input = input;
  }
}

async function resolve(input) {
  const parsed = parseSource(input);
  if (!parsed) throw new UnsupportedSourceError(input);

  return parsed.source === 'youtube'
    ? resolveYouTube(parsed.external_id)
    : resolveSpotify(parsed.external_id);
}

/**
 * For self-recorded submissions. Metadata comes from the submitter,
 * there is nothing to look up.
 */
function fromUpload({ storageKey, title, artist, duration_s, thumbnail_url }) {
  return {
    source: 'upload',
    external_id: storageKey,
    source_url: `/media/${storageKey}`,
    embed_url: `/media/${storageKey}`,
    title: title || 'Untitled',
    artist: artist || null,
    artist_guessed: false,
    duration_s: duration_s || null,
    thumbnail_url: thumbnail_url || null,
    raw_title: title || null,
  };
}

module.exports = {
  resolve,
  parseSource,
  fromUpload,
  splitTitle,
  parseIsoDuration,
  canonicalUrl,
  embedUrl,
  UnsupportedSourceError,
};
