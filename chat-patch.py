#!/usr/bin/env python3
"""Teaches chat.js about media and adds the Giphy routes."""
import pathlib, sys

p = pathlib.Path('chat.js')
s = p.read_text()

if 'giphy' in s:
    print("    already there, skipping")
    sys.exit(0)

# 1. import
s = s.replace(
    "const { requireAuth } = require('./auth');",
    "const { requireAuth } = require('./auth');\nconst giphy = require('./giphy');"
)

# 2. shape() carries media through
s = s.replace(
    """    return {
      id: String(row.id),
      name: row.name,
      body: row.body,
      at: row.created_at,
      edited: Boolean(row.edited_at),
      mine: row.player_id === viewerId,
      canRemove: row.player_id === viewerId || isAdmin,
    };""",
    """    return {
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
    };"""
)

# 3. posting accepts a gif
s = s.replace(
    """      const body = String(req.body.body || '').trim();
      if (!body) return res.status(400).json({ error: 'Say something first.' });
      if (body.length > MAX_LEN) {
        return res.status(400).json({ error: 'That is too long.' });
      }""",
    """      const body = String(req.body.body || '').trim();
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
      }"""
)

s = s.replace(
    """      const { rows } = await db.query(
        `insert into messages (league_id, player_id, body)
         values ($1, $2, $3) returning id, created_at`,
        [req.league.id, req.player.id, body]
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
        },
      });""",
    """      const { rows } = await db.query(
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
      });"""
)

# 4. the picker's data source
s = s.replace(
    "  return r;\n}\n\nmodule.exports = { router };",
    """  // ---------------------------------------------------------------
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

module.exports = { router };"""
)

# 5. the view needs to know whether to show the button
s = s.replace(
    """      res.render('chat', {
        league: req.league,
        messages,""",
    """      res.render('chat', {
        league: req.league,
        gifsOn: giphy.enabled,
        messages,"""
)

p.write_text(s)
print("    done")
