/**
 * dupecheck.js
 *
 * Stops two people submitting the same song in the same round.
 *
 * Two deliberate limits:
 *
 *   Exact matches only. The fuzzy similarity check is good enough to warn
 *   a commissioner but not good enough to tell someone their legitimate
 *   pick is off limits. A false positive here means a player is locked
 *   out of a song nobody else actually chose, which is worse than the
 *   duplicate it would have prevented.
 *
 *   Enforced in the app, not as a database constraint. A unique index
 *   would be stronger, but it would also block the commissioner entering
 *   a song on someone's behalf, and that is the escape hatch for exactly
 *   the situations this creates. The tiny race between two simultaneous
 *   submissions is covered by the collision alert.
 *
 * The message never says who. Submissions are secret until voting, and
 * "Jess already picked that" would give away more than the block saves.
 */

'use strict';

const TAKEN = 'Somebody has already picked that one this round. ' +
              'Pick something else, or ask the commissioner if you think ' +
              'this is wrong.';

/**
 * Is this song already spoken for by someone else in this round?
 *
 * @param db        pg pool
 * @param roundId   round being submitted to
 * @param playerId  who is submitting, so their own pick does not block them
 * @param track     resolved track, needs external_id and title/artist
 * @returns the message to show, or null if the song is free
 */
async function taken(db, roundId, playerId, track) {
  const externalId = track.external_id || null;
  const artist = track.artist || null;
  const title = track.title || null;

  const { rows } = await db.query(
    `select 1
       from submissions s
      where s.round_id = $1
        and s.player_id <> $2
        and (
          ($3::text is not null and s.external_id = $3)
          or (
            song_key($4, $5) is not null
            and s.song_key = song_key($4, $5)
          )
        )
      limit 1`,
    [roundId, playerId, externalId, artist, title]
  );

  return rows[0] ? TAKEN : null;
}

module.exports = { taken, TAKEN };
