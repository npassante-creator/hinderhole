/**
 * export.js
 *
 * Getting a round out of the app and into whatever people already use.
 *
 * Four shapes:
 *   .txt      numbered list with links, for pasting into a group chat
 *   .csv      spreadsheet, for archives and arguing about the numbers
 *   /youtube  a real YouTube playlist built from the video ids
 *   .m3u      for anyone running their own player
 *
 * Anonymity carries over. Before a round is revealed the exports carry no
 * submitter names and no points, otherwise handing someone the CSV would
 * undo what the voting page is careful about.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');

/** RFC 4180: quote anything with a comma, quote, or newline. */
function csvCell(value) {
  const s = value === null || value === undefined ? '' : String(value);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function slug(text) {
  return String(text).toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60) || 'round';
}

function router(db) {
  const r = express.Router();

  async function load(req, res, next) {
    try {
      const { rows } = await db.query(
        `select r.*, l.name as league_name
           from rounds r
           join leagues l on l.id = r.league_id
           join memberships m on m.league_id = l.id and m.player_id = $2
          where r.id = $1`,
        [req.params.id, req.player.id]
      );
      if (!rows[0]) {
        return res.status(404).render('error', {
          code: '404',
          headline: 'No such record',
          detail: 'That round is not in the rack.',
        });
      }
      req.round = rows[0];

      // Draft rounds have nothing in them, and rounds still taking
      // submissions must not leak who has turned one in.
      if (!['voting', 'revealed'].includes(req.round.status)) {
        return res.status(403).render('error', {
          code: '403',
          headline: 'Not yet',
          detail: 'Nothing to export until the songs are in.',
        });
      }

      req.revealed = req.round.status === 'revealed';

      const { rows: songs } = await db.query(
        `select s.id, s.title, s.artist, s.source, s.source_url,
                s.external_id, s.note,
                ${req.revealed ? 'p.name as submitter,' : 'null as submitter,'}
                ${req.revealed
                  ? 'coalesce(sum(v.points), 0)::int as points,'
                  : '0 as points,'}
                count(v.id)::int as backers
           from submissions s
           join players p on p.id = s.player_id
           left join votes v on v.submission_id = s.id
          where s.round_id = $1
          group by s.id, p.name
          order by ${req.revealed
            ? 'coalesce(sum(v.points), 0) desc, s.title'
            : 's.submitted_at'}`,
        [req.round.id]
      );

      req.songs = songs;
      next();
    } catch (err) {
      next(err);
    }
  }

  function filename(round, ext) {
    return `round-${String(round.round_number).padStart(2, '0')}-${slug(round.title)}.${ext}`;
  }

  // ---------------------------------------------------------------
  // Plain text, for pasting somewhere
  // ---------------------------------------------------------------

  r.get('/round/:id/export.txt', requireAuth, load, (req, res) => {
    const { round, songs, revealed } = req;
    const lines = [];

    lines.push(`Round ${round.round_number}: ${round.title}`);
    lines.push(round.league_name);
    lines.push('');

    songs.forEach((s, i) => {
      const n = String(i + 1).padStart(2, ' ');
      const artist = s.artist ? `${s.artist} - ` : '';
      lines.push(`${n}. ${artist}${s.title}`);
      lines.push(`    ${s.source_url}`);
      if (revealed) {
        lines.push(`    ${s.points} points, submitted by ${s.submitter}`);
      }
      lines.push('');
    });

    if (!revealed) {
      lines.push('Submitters are hidden until the round is revealed.');
    }

    res.type('text/plain; charset=utf-8');
    res.setHeader('Content-Disposition',
      `attachment; filename="${filename(round, 'txt')}"`);
    res.send(lines.join('\n'));
  });

  // ---------------------------------------------------------------
  // CSV
  // ---------------------------------------------------------------

  r.get('/round/:id/export.csv', requireAuth, load, (req, res) => {
    const { round, songs, revealed } = req;

    const header = ['round', 'category', 'position', 'title', 'artist',
                    'source', 'url'];
    if (revealed) header.push('points', 'voters', 'submitter', 'note');

    const rows = [header.map(csvCell).join(',')];

    songs.forEach((s, i) => {
      const row = [
        round.round_number, round.title, i + 1,
        s.title, s.artist, s.source, s.source_url,
      ];
      if (revealed) row.push(s.points, s.backers, s.submitter, s.note);
      rows.push(row.map(csvCell).join(','));
    });

    // BOM so Excel opens UTF-8 correctly. Names have accents in them.
    res.type('text/csv; charset=utf-8');
    res.setHeader('Content-Disposition',
      `attachment; filename="${filename(round, 'csv')}"`);
    res.send('\ufeff' + rows.join('\r\n'));
  });

  // ---------------------------------------------------------------
  // Whole season CSV
  // ---------------------------------------------------------------

  r.get('/season.csv', requireAuth, async (req, res, next) => {
    try {
      const { rows: leagues } = await db.query(
        `select l.* from leagues l
           join memberships m on m.league_id = l.id
          where m.player_id = $1
          order by l.created_at desc limit 1`,
        [req.player.id]
      );
      if (!leagues[0]) return res.redirect('/');

      // Revealed rounds only. A season file must never leak a live round.
      const { rows } = await db.query(
        `select r.round_number, r.title as category,
                s.title, s.artist, s.source, s.source_url, s.note,
                p.name as submitter,
                coalesce(sum(v.points), 0)::int as points,
                count(v.id)::int as voters
           from rounds r
           join submissions s on s.round_id = r.id
           join players p on p.id = s.player_id
           left join votes v on v.submission_id = s.id
          where r.league_id = $1 and r.status = 'revealed'
          group by r.round_number, r.title, s.id, s.title, s.artist,
                   s.source, s.source_url, s.note, p.name
          order by r.round_number, coalesce(sum(v.points), 0) desc`,
        [leagues[0].id]
      );

      const header = ['round', 'category', 'title', 'artist', 'submitter',
                      'points', 'voters', 'source', 'url', 'note'];
      const out = [header.join(',')];
      rows.forEach((x) => {
        out.push([x.round_number, x.category, x.title, x.artist, x.submitter,
                  x.points, x.voters, x.source, x.source_url, x.note]
          .map(csvCell).join(','));
      });

      res.type('text/csv; charset=utf-8');
      res.setHeader('Content-Disposition',
        `attachment; filename="${slug(leagues[0].name)}-season.csv"`);
      res.send('\ufeff' + out.join('\r\n'));
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // YouTube playlist
  // ---------------------------------------------------------------
  // YouTube builds a temporary playlist from a comma separated list of
  // video ids. No account, no setup, works on a phone or a TV.

  r.get('/round/:id/youtube', requireAuth, load, (req, res) => {
    const ids = req.songs
      .filter((s) => s.source === 'youtube' && s.external_id)
      .map((s) => s.external_id);

    if (!ids.length) {
      return res.status(404).render('error', {
        code: '404',
        headline: 'Nothing to play',
        detail: 'No YouTube songs in this round.',
      });
    }

    // The URL is a query string, and long ones get truncated by some
    // clients. Fifty ids is well inside any limit.
    const list = ids.slice(0, 50).join(',');
    res.redirect(
      `https://www.youtube.com/watch_videos?video_ids=${list}`);
  });

  // ---------------------------------------------------------------
  // M3U
  // ---------------------------------------------------------------

  r.get('/round/:id/export.m3u', requireAuth, load, (req, res) => {
    const { round, songs } = req;
    const base = process.env.APP_URL || '';
    const lines = ['#EXTM3U'];

    songs.forEach((s) => {
      const artist = s.artist ? `${s.artist} - ` : '';
      lines.push(`#EXTINF:-1,${artist}${s.title}`);
      lines.push(s.source === 'upload' ? base + s.source_url : s.source_url);
    });

    res.type('audio/x-mpegurl');
    res.setHeader('Content-Disposition',
      `attachment; filename="${filename(round, 'm3u')}"`);
    res.send(lines.join('\n'));
  });

  return r;
}

module.exports = { router };
