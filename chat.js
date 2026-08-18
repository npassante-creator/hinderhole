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

const PAGE = 60;              // messages loaded at once
const MAX_LEN = 2000;
const RATE_WINDOW_S = 30;
const RATE_MAX = 12;          // messages per window, per person

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
      if (media && !giphy.isAllowed(String(media.url || ''))) {
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
          media ? 'gif' : null,
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
            kind: 'gif',
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
