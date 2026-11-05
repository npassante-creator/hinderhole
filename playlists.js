/**
 * playlists.js
 *
 * Season's-end listening. Every player's picks in round order, and a
 * mixtape of the songs that took each round.
 *
 * A round that has not been revealed stays secret: other people's picks
 * for it are never selected, only a placeholder. Your own pick shows to
 * you, marked as still in play.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');
const scoring = require('./scoring');

function router(db) {
  const r = express.Router();

  async function load(req, res, next) {
    try {
      const league = await scoring.leagueFor(db, req.player.id);
      if (!league) return res.redirect('/');
      req.league = league;

      const { rows: rounds } = await db.query(
        `select id, round_number, title, status from rounds
          where league_id = $1 order by round_number`,
        [league.id]
      );
      req.rounds = rounds;
      req.tables = await scoring.roundTables(db, league.id);
      req.table = await scoring.seasonTable(db, league.id);
      next();
    } catch (err) {
      next(err);
    }
  }

  /** One player's season, in round order. */
  async function picksFor(req, who) {
    const mine = String(who) === String(req.player.id);
    const { rows: own } = await db.query(
      `select s.id, s.round_id, s.title, s.artist, s.source, s.source_url,
              s.external_id, s.thumbnail_url, s.note, s.is_late
         from submissions s
         join rounds r on r.id = s.round_id
        where r.league_id = $1
          and s.player_id = $2
          and (r.status = 'revealed' or $3)`,
      [req.league.id, who, mine]
    );
    const byRound = new Map(own.map((s) => [String(s.round_id), s]));

    return req.rounds.map((round) => {
      const sub = byRound.get(String(round.id)) || null;
      const t = req.tables.get(String(round.id)) || [];
      const ranked = sub ? t.find((x) => String(x.id) === String(sub.id)) : null;
      let state;
      if (round.status === 'revealed') state = sub ? 'scored' : 'missed';
      else if (round.status === 'draft') state = 'later';
      else state = mine && sub ? 'mine' : 'hidden';
      return {
        round,
        state,
        sub,
        place: ranked ? scoring.ordinal(ranked.place) : null,
        won: ranked ? ranked.place === 1 : false,
        points: ranked ? ranked.points : null,
        of: ranked ? ranked.of : null,
      };
    });
  }

  function youtubeIds(list) {
    return list
      .filter((x) => x.sub && x.sub.source === 'youtube' && x.sub.external_id)
      .map((x) => x.sub.external_id);
  }

  function render(req, res, view, extra) {
    res.render('playlists', {
      league: req.league,
      roster: req.table.map((row) => ({
        ...row,
        on: view === 'player' && String(row.id) === String(extra.who),
      })),
      view,
      wide: true,
      ...extra,
    });
  }

  r.get('/playlists', requireAuth, (req, res) => {
    res.redirect(`/playlists/${req.player.id}`);
  });

  r.get('/playlists/mixtape', requireAuth, load, (req, res, next) => {
    try {
      const winners = [];
      req.rounds.forEach((round) => {
        const t = req.tables.get(String(round.id)) || [];
        const top = t.filter((s) => s.place === 1);
        if (round.status !== 'revealed' || !top.length) {
          winners.push({ round, sub: null });
          return;
        }
        top.forEach((s) => winners.push({ round, sub: s, points: s.points }));
      });
      render(req, res, 'mixtape', {
        winners,
        who: null,
        ytCount: youtubeIds(winners).length,
      });
    } catch (err) {
      next(err);
    }
  });

  r.get('/playlists/mixtape/youtube', requireAuth, load, (req, res) => {
    const ids = [];
    req.rounds.forEach((round) => {
      if (round.status !== 'revealed') return;
      (req.tables.get(String(round.id)) || [])
        .filter((s) => s.place === 1 && s.source === 'youtube' && s.external_id)
        .forEach((s) => ids.push(s.external_id));
    });
    if (!ids.length) return res.redirect('/playlists/mixtape');
    res.redirect(`https://www.youtube.com/watch_videos?video_ids=${ids.slice(0, 50).join(',')}`);
  });

  r.get('/playlists/:playerId(\\d+)', requireAuth, load, async (req, res, next) => {
    try {
      const who = req.params.playerId;
      const row = req.table.find((x) => String(x.id) === String(who));
      if (!row) return next();
      const picks = await picksFor(req, who);
      const scored = picks.filter((p) => p.state === 'scored');
      const wins = picks.filter((p) => p.won);
      const best = scored.slice().sort((a, b) => b.points - a.points)[0] || null;
      render(req, res, 'player', {
        who,
        person: row,
        isMe: String(who) === String(req.player.id),
        picks,
        wins,
        best,
        scoredCount: scored.length,
        ytCount: youtubeIds(picks).length,
        ordinal: scoring.ordinal,
      });
    } catch (err) {
      next(err);
    }
  });

  r.get('/playlists/:playerId(\\d+)/youtube', requireAuth, load, async (req, res, next) => {
    try {
      const who = req.params.playerId;
      if (!req.table.some((x) => String(x.id) === String(who))) return next();
      const ids = youtubeIds(await picksFor(req, who));
      if (!ids.length) return res.redirect(`/playlists/${who}`);
      res.redirect(`https://www.youtube.com/watch_videos?video_ids=${ids.slice(0, 50).join(',')}`);
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router };
