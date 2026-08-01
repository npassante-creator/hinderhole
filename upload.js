/**
 * upload.js
 *
 * Audio upload for people submitting their own recordings, or songs that
 * are not on YouTube at all.
 *
 * Uploaded audio is the best case for the continuous player: it reports
 * when it ends, so the round keeps flowing, and there is no sharing
 * setting for the submitter to get wrong.
 *
 * Files land in MEDIA_DIR, outside the app directory so a deploy that
 * unpacks a tarball can never wipe them. Names are random, so knowing one
 * file tells you nothing about the others.
 */

'use strict';

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const multer = require('multer');
const { requireAuth } = require('./auth');

const MEDIA_DIR = process.env.MEDIA_DIR || '/var/lib/hinderhole/media';
const MAX_BYTES = 25 * 1024 * 1024;

// Extension is decided here, from the sniffed type, never from the name
// the browser sent.
const TYPES = {
  'audio/mpeg': '.mp3',
  'audio/mp3': '.mp3',
  'audio/mp4': '.m4a',
  'audio/x-m4a': '.m4a',
  'audio/aac': '.aac',
  'audio/ogg': '.ogg',
  'audio/opus': '.opus',
  'audio/wav': '.wav',
  'audio/x-wav': '.wav',
  'audio/flac': '.flac',
  'audio/x-flac': '.flac',
  'audio/webm': '.weba',
};

// First bytes of each container, so a renamed .exe cannot get through.
function sniff(buf) {
  if (buf.length < 12) return null;
  const ascii = (a, b) => buf.slice(a, b).toString('ascii');

  if (ascii(0, 3) === 'ID3') return '.mp3';
  if (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0) return '.mp3';
  if (ascii(4, 8) === 'ftyp') {
    const brand = ascii(8, 12);
    if (/^(M4A|mp42|isom|dash|M4B )/.test(brand)) return '.m4a';
  }
  if (ascii(0, 4) === 'OggS') return '.ogg';
  if (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WAVE') return '.wav';
  if (ascii(0, 4) === 'fLaC') return '.flac';
  if (buf[0] === 0x1a && buf[1] === 0x45 && buf[2] === 0xdf && buf[3] === 0xa3) {
    return '.weba';
  }
  return null;
}

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_BYTES, files: 1 },
  fileFilter: (req, file, cb) => {
    if (TYPES[file.mimetype]) return cb(null, true);
    cb(new Error('That is not an audio file we can play.'));
  },
});

async function ensureDir() {
  await fsp.mkdir(MEDIA_DIR, { recursive: true });
}

function router(db) {
  const r = express.Router();

  // ---------------------------------------------------------------
  // Serving
  // ---------------------------------------------------------------
  // Behind auth, because a league's submissions are not public. Range
  // requests are handled by sendFile, which is what lets people scrub.

  r.get('/media/:key', requireAuth, async (req, res, next) => {
    try {
      const key = String(req.params.key);
      if (!/^[a-f0-9]{32}\.[a-z0-9]{2,4}$/.test(key)) {
        return res.status(404).end();
      }

      // The requester has to share a league with whoever submitted it.
      const { rows } = await db.query(
        `select 1
           from submissions s
           join rounds rd on rd.id = s.round_id
           join memberships m on m.league_id = rd.league_id
          where s.external_id = $1 and m.player_id = $2`,
        [key, req.player.id]
      );
      if (!rows[0]) return res.status(404).end();

      res.sendFile(path.join(MEDIA_DIR, key), {
        headers: { 'Cache-Control': 'private, max-age=86400' },
      }, (err) => { if (err && !res.headersSent) res.status(404).end(); });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------

  r.post('/round/:id/upload', requireAuth, (req, res, next) => {
    upload.single('audio')(req, res, (err) => {
      if (err) {
        const msg = err.code === 'LIMIT_FILE_SIZE'
          ? 'That file is over 25 MB. Trim it or export at a lower bitrate.'
          : err.message;
        return res.redirect(
          `/round/${req.params.id}?err=` + encodeURIComponent(msg));
      }
      next();
    });
  }, async (req, res, next) => {
    try {
      const { rows: roundRows } = await db.query(
        `select r.*, l.id as league_id
           from rounds r
           join leagues l on l.id = r.league_id
           join memberships m on m.league_id = l.id and m.player_id = $2
          where r.id = $1`,
        [req.params.id, req.player.id]
      );
      const round = roundRows[0];
      if (!round) return res.status(404).render('error', {
        code: '404', headline: 'No such record',
        detail: 'That round is not in the rack.',
      });

      if (round.status !== 'submitting') {
        return res.redirect(`/round/${round.id}?err=` +
          encodeURIComponent('Submissions for this round are closed.'));
      }
      if (!req.file) {
        return res.redirect(`/round/${round.id}?err=` +
          encodeURIComponent('Pick a file first.'));
      }

      const ext = sniff(req.file.buffer);
      if (!ext) {
        return res.redirect(`/round/${round.id}?err=` +
          encodeURIComponent(
            'That file does not look like audio inside, whatever it is named.'));
      }

      await ensureDir();
      const key = crypto.randomBytes(16).toString('hex') + ext;
      const dest = path.join(MEDIA_DIR, key);
      await fsp.writeFile(dest, req.file.buffer, { mode: 0o640 });

      const title = String(req.body.title || '').trim()
        || path.parse(req.file.originalname).name.slice(0, 120)
        || 'Untitled';

      // Replacing an upload leaves the old file orphaned. Clean it up.
      const { rows: prior } = await db.query(
        `select external_id from submissions
          where round_id = $1 and player_id = $2 and source = 'upload'`,
        [round.id, req.player.id]
      );

      const late = Boolean(round.submit_deadline &&
        Date.now() > round.submit_deadline.getTime());

      await db.query(
        `insert into submissions
           (round_id, player_id, source, source_url, external_id,
            title, artist, note, is_late)
         values ($1,$2,'upload',$3,$4,$5,$6,$7,$8)
         on conflict (round_id, player_id) do update set
           source = 'upload', source_url = excluded.source_url,
           external_id = excluded.external_id, title = excluded.title,
           artist = excluded.artist, thumbnail_url = null,
           duration_s = null, note = excluded.note,
           submitted_at = now(), is_late = excluded.is_late`,
        [round.id, req.player.id, `/media/${key}`, key, title,
         String(req.body.artist || '').trim() || null,
         String(req.body.note || '').trim() || null, late]
      );

      if (prior[0] && prior[0].external_id !== key) {
        fsp.unlink(path.join(MEDIA_DIR, prior[0].external_id))
          .catch(() => { /* already gone, fine */ });
      }

      res.redirect(`/round/${round.id}?saved=1`);
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router, MEDIA_DIR, MAX_BYTES };
