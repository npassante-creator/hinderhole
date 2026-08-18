/**
 * chat.js
 *
 * One room for the whole league.
 *
 * Polling rather than a persistent connection. Mobile browsers suspend
 * background tabs and kill open connections, so an event stream would
 * quietly stop updating and look broken. Polling reconnects by simply
 * being a request. At twenty one people it is nothing.
 *
 * Deleted messages leave a tombstone rather than vanishing. A thread with
 * silent holes in it is worse than one that says something was removed.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');
const giphy = require('./giphy');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const multer = require('multer');

const PAGE = 60;              // messages loaded at once
const MAX_LEN = 2000;
const RATE_WINDOW_S = 30;
const RATE_MAX = 12;          // messages per window, per person

const MEDIA_DIR = process.env.MEDIA_DIR || '/var/lib/hinderhole/media';
const CHAT_DIR = path.join(MEDIA_DIR, 'chat');

// The browser shrinks photos before sending, so this is a backstop
// against someone posting a raw camera file or something worse.
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_IMAGE_BYTES, files: 1 },
});

/** Read the first bytes rather than trusting the name or the browser. */
function sniffImage(buf) {
  if (buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return '.jpg';
  if (buf[0] === 0x89 && buf.slice(1, 4).toString('ascii') === 'PNG') return '.png';
  if (buf.slice(0, 3).toString('ascii') === 'GIF') return '.gif';
  if (buf.slice(0, 4).toString('ascii') === 'RIFF' &&
      buf.slice(8, 12).toString('ascii') === 'WEBP') return '.webp';
  return null;
}

function router(db) {
  const r = express.Router();
  const json = express.json();

  async function loadLeague(req, res, next) {
    try {
      const { rows } = await db.query(
        `select l.id, l.name, m.role
           from leagues l
           join memberships m on m.league_id = l.id
          where m.player_id = $1
          order by l.created_at desc limit 1`,
        [req.player.id]
      );
      if (!rows[0]) return res.redirect('/');
      req.league = rows[0];
      req.isAdmin = rows[0].role === 'admin';
      next();
    } catch (err) {
      next(err);
    }
  }

  function shape(row, viewerId, isAdmin) {
    if (row.deleted_at) {
      return {
        id: String(row.id),
        deleted: true,
        name: row.name,
        at: row.created_at,
      };
    }
    return {
      id: String(row.id),
      name: row.name,
      body: row.body,
      at: row.created_at,
      edited: Boolean(row.edited_at),
      mine: row.player_id === viewerId,
      canRemove: row.player_id === viewerId || isAdmin,
      media: row.media_url ? {
        url: row.media_url,
        kind: row.media_kind,
        w: row.media_w,
        h: row.media_h,
        alt: row.media_alt,
      } : null,
    };
  }

  async function fetchMessages(leagueId, { after, before } = {}) {
    if (after) {
      const { rows } = await db.query(
        `select m.*, p.name
           from messages m join players p on p.id = m.player_id
          where m.league_id = $1 and m.id > $2
          order by m.id limit $3`,
        [leagueId, after, PAGE]
      );
      return rows;
    }
    const { rows } = await db.query(
      `select m.*, p.name
         from messages m join players p on p.id = m.player_id
        where m.league_id = $1 ${before ? 'and m.id < $3' : ''}
        order by m.id desc limit $2`,
      before ? [leagueId, PAGE, before] : [leagueId, PAGE]
    );
    return rows.reverse();
  }

  // ---------------------------------------------------------------
  // The room
  // ---------------------------------------------------------------

  r.get('/chat', requireAuth, loadLeague, async (req, res, next) => {
    try {
      const rows = await fetchMessages(req.league.id);
      const messages = rows.map((x) => shape(x, req.player.id, req.isAdmin));
      const newest = rows.length ? rows[rows.length - 1].id : 0;

      await db.query(
        `insert into chat_reads (league_id, player_id, last_seen)
         values ($1, $2, $3)
         on conflict (league_id, player_id)
         do update set last_seen = greatest(chat_reads.last_seen, $3),
                       updated_at = now()`,
        [req.league.id, req.player.id, newest]
      );

      res.render('chat', {
        league: req.league,
        gifsOn: giphy.enabled,
        messages,
        newest: String(newest),
        hasMore: rows.length === PAGE,
      });
    } catch (err) {
      next(err);
    }
  });

  /** Everything since the id the client already has. */
  r.get('/chat/since/:id', requireAuth, loadLeague, async (req, res, next) => {
    try {
      const after = Number(req.params.id) || 0;
      const rows = await fetchMessages(req.league.id, { after });
      const messages = rows.map((x) => shape(x, req.player.id, req.isAdmin));

      if (rows.length) {
        await db.query(
          `insert into chat_reads (league_id, player_id, last_seen)
           values ($1, $2, $3)
           on conflict (league_id, player_id)
           do update set last_seen = greatest(chat_reads.last_seen, $3),
                         updated_at = now()`,
          [req.league.id, req.player.id, rows[rows.length - 1].id]
        );
      }

      res.json({
        messages,
        newest: rows.length ? String(rows[rows.length - 1].id) : String(after),
      });
    } catch (err) {
      next(err);
    }
  });

  /** Older messages, for scrolling back. */
  r.get('/chat/before/:id', requireAuth, loadLeague, async (req, res, next) => {
    try {
      const rows = await fetchMessages(req.league.id,
        { before: Number(req.params.id) });
      res.json({
        messages: rows.map((x) => shape(x, req.player.id, req.isAdmin)),
        hasMore: rows.length === PAGE,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Saying something
  // ---------------------------------------------------------------

  r.post('/chat', requireAuth, loadLeague, json, async (req, res, next) => {
    try {
      const body = String(req.body.body || '').trim();
      const media = req.body.media || null;

      // Whatever the browser sends is checked here, not trusted. Only
      // Giphy's own hosts can ever end up rendered in a message.
      // Two kinds of media are legal: a Giphy url, or a key we issued
      // ourselves from /chat/upload. Nothing else.
      const isUpload = media && /^\/chat\/media\/[a-f0-9]{32}\.[a-z]{3,4}$/
        .test(String(media.url || ''));
      if (media && !isUpload && !giphy.isAllowed(String(media.url || ''))) {
        return res.status(400).json({ error: 'That image is not allowed.' });
      }
      if (!body && !media) {
        return res.status(400).json({ error: 'Say something first.' });
      }
      if (body.length > MAX_LEN) {
        return res.status(400).json({ error: 'That is too long.' });
      }

      const { rows: recent } = await db.query(
        `select count(*)::int as n from messages
          where player_id = $1 and league_id = $2
            and created_at > now() - ($3 || ' seconds')::interval`,
        [req.player.id, req.league.id, String(RATE_WINDOW_S)]
      );
      if (recent[0].n >= RATE_MAX) {
        return res.status(429).json({ error: 'Slow down a second.' });
      }

      const { rows } = await db.query(
        `insert into messages
           (league_id, player_id, body, media_url, media_kind,
            media_w, media_h, media_alt)
         values ($1, $2, $3, $4, $5, $6, $7, $8)
         returning id, created_at`,
        [
          req.league.id, req.player.id, body || null,
          media ? String(media.url) : null,
          media ? (isUpload ? 'image' : 'gif') : null,
          media && Number(media.w) ? Number(media.w) : null,
          media && Number(media.h) ? Number(media.h) : null,
          media ? String(media.alt || 'GIF').slice(0, 200) : null,
        ]
      );

      res.json({
        ok: true,
        message: {
          id: String(rows[0].id),
          name: req.player.name,
          body,
          at: rows[0].created_at,
          mine: true,
          canRemove: true,
          media: media ? {
            url: String(media.url),
            kind: isUpload ? 'image' : 'gif',
            w: Number(media.w) || null,
            h: Number(media.h) || null,
            alt: String(media.alt || 'GIF'),
          } : null,
        },
      });
    } catch (err) {
      next(err);
    }
  });

  /** Yours, or anyone's if you are an admin. Leaves a tombstone. */
  r.post('/chat/:id/remove', requireAuth, loadLeague, json,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `update messages
              set deleted_at = now(), deleted_by = $3
            where id = $1 and league_id = $2 and deleted_at is null
              and (player_id = $3 or $4)
          returning id`,
          [req.params.id, req.league.id, req.player.id, req.isAdmin]
        );
        if (!rows[0]) return res.status(403).json({ error: 'Not yours.' });
        res.json({ ok: true });
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Uploaded images
  // ---------------------------------------------------------------

  r.post('/chat/upload', requireAuth, loadLeague, (req, res, next) => {
    upload.single('image')(req, res, (err) => {
      if (err) {
        return res.status(400).json({
          error: err.code === 'LIMIT_FILE_SIZE'
            ? 'That image is too big.'
            : 'Could not read that file.',
        });
      }
      next();
    });
  }, async (req, res, next) => {
    try {
      if (!req.file) return res.status(400).json({ error: 'No file.' });

      const ext = sniffImage(req.file.buffer);
      if (!ext) {
        return res.status(400).json({
          error: 'That does not look like an image inside, whatever it is named.',
        });
      }

      await fsp.mkdir(CHAT_DIR, { recursive: true });
      const key = crypto.randomBytes(16).toString('hex') + ext;
      await fsp.writeFile(path.join(CHAT_DIR, key), req.file.buffer,
        { mode: 0o640 });

      res.json({
        ok: true,
        url: `/chat/media/${key}`,
        w: Number(req.body.w) || null,
        h: Number(req.body.h) || null,
        alt: 'Image',
      });
    } catch (err) {
      next(err);
    }
  });

  /** Behind auth, because a league's chat is not public. */
  r.get('/chat/media/:key', requireAuth, loadLeague, async (req, res) => {
    const key = String(req.params.key);
    if (!/^[a-f0-9]{32}\.[a-z]{3,4}$/.test(key)) return res.status(404).end();

    const { rows } = await db.query(
      `select 1 from messages
        where league_id = $1 and media_url = $2 limit 1`,
      [req.league.id, `/chat/media/${key}`]
    );
    // A just-uploaded image has no message row yet, so let the uploader
    // see their own preview.
    if (!rows[0]) {
      try {
        await fsp.access(path.join(CHAT_DIR, key));
      } catch {
        return res.status(404).end();
      }
    }

    res.sendFile(path.join(CHAT_DIR, key), {
      headers: { 'Cache-Control': 'private, max-age=604800' },
    }, (err) => { if (err && !res.headersSent) res.status(404).end(); });
  });

  // ---------------------------------------------------------------
  // The GIF picker's data source
  // ---------------------------------------------------------------

  r.get('/chat/gifs', requireAuth, loadLeague, async (req, res) => {
    if (!giphy.enabled) {
      return res.status(503).json({ error: 'GIFs are not set up yet.' });
    }
    try {
      const q = String(req.query.q || '').trim().slice(0, 60);
      const results = q ? await giphy.search(q) : await giphy.trending();
      res.json({ results });
    } catch (err) {
      res.status(err.status === 429 ? 429 : 502)
         .json({ error: err.message });
    }
  });

  return r;
}

module.exports = { router };
