-- Music League: catching the same song under a different link
--
-- Matching on the YouTube id only catches a literal repost. With obscure
-- music there are five uploads of the same track, plus live versions,
-- remasters, and lyric videos.
--
-- So: normalise artist and title into a fingerprint, and keep trigram
-- similarity as a second net for the near misses.
--
-- This will never be perfect. The metadata is guessed off freeform
-- YouTube titles. It is a warning for a human to judge, never a block.

begin;

create extension if not exists pg_trgm;

/**
 * Strip a title down to something comparable.
 *
 * "Radiohead - Idioteque (Official Video) [HD]"  -> radioheadidioteque
 * "Idioteque - Radiohead (Live at Glastonbury)"  -> idiotequeradiohead
 *
 * Note the last two sort differently. That is what the trigram check is
 * for: this function catches the tidy cases, similarity catches the rest.
 */
create or replace function song_key(p_artist text, p_title text)
returns text as $$
  select nullif(
    regexp_replace(
      lower(
        -- Drop anything in brackets: (Official Video), [HD], (Remastered)
        regexp_replace(
          coalesce(p_artist, '') || ' ' || coalesce(p_title, ''),
          '[\(\[\{][^\)\]\}]*[\)\]\}]', ' ', 'g')
      ),
      -- Then the noise words that survive outside brackets, and finally
      -- everything that is not a letter or a number.
      '\m(official|video|audio|lyrics?|lyric|hd|hq|4k|remaster(ed)?|' ||
      'live|version|full|album|single|feat|ft|featuring|with|the|a|an|' ||
      'explicit|clean|mv|m/v|visualizer)\M|[^a-z0-9]',
      '', 'g'
    ), '');
$$ language sql immutable;


-- Stored rather than computed on the fly, so it can be indexed and so a
-- later change to song_key does not silently reinterpret history.
alter table submissions
  add column if not exists song_key text;

update submissions
   set song_key = song_key(artist, title)
 where song_key is null;

create index if not exists submissions_song_key_idx
  on submissions (song_key);

create index if not exists submissions_song_key_trgm
  on submissions using gin (song_key gin_trgm_ops);


create or replace function submissions_set_key() returns trigger as $$
begin
  new.song_key := song_key(new.artist, new.title);
  return new;
end;
$$ language plpgsql;

drop trigger if exists submissions_key on submissions;
create trigger submissions_key
  before insert or update of artist, title on submissions
  for each row execute function submissions_set_key();


-- ---------------------------------------------------------------
-- The lookup
-- ---------------------------------------------------------------
--
-- Three ways a song counts as seen before, loosest last:
--   1. the same link
--   2. the same normalised key
--   3. a normalised key that is close enough
--
-- Only looks at rounds that have been revealed, so a player can never
-- learn anything about a round still in play.

create or replace function song_seen_before(
  p_league_id bigint, p_external_id text, p_round_id bigint
) returns table (
  round_number smallint, round_title text, submitted_by text,
  song_title text, how text
) as $$
  with me as (
    select external_id, song_key
      from submissions
     where round_id = p_round_id and external_id = p_external_id
     limit 1
  )
  select r.round_number, r.title, p.name, s.title,
         case
           when s.external_id = me.external_id then 'the same link'
           when s.song_key = me.song_key       then 'the same song'
           else 'something very close'
         end
    from submissions s
    join rounds r  on r.id = s.round_id
    join players p on p.id = s.player_id
    cross join me
   where r.league_id = p_league_id
     and r.status = 'revealed'
     and s.round_id <> p_round_id
     and (
       s.external_id = me.external_id
       or (me.song_key is not null and s.song_key = me.song_key)
       or (me.song_key is not null and s.song_key is not null
           and similarity(s.song_key, me.song_key) > 0.62)
     )
   order by r.round_number;
$$ language sql stable;


-- ---------------------------------------------------------------
-- The commissioner's view
-- ---------------------------------------------------------------
--
-- Two people picking the same song in the same round is the case players
-- must not be told about, since submissions are secret until voting. The
-- commissioner can see it and sort it out quietly.

create or replace function round_collisions(p_round_id bigint)
returns table (
  a_player text, a_title text, b_player text, b_title text, how text
) as $$
  select pa.name, a.title, pb.name, b.title,
         case
           when a.external_id = b.external_id then 'the same link'
           when a.song_key = b.song_key       then 'the same song'
           else 'something very close'
         end
    from submissions a
    join submissions b
      on b.round_id = a.round_id and b.id > a.id
    join players pa on pa.id = a.player_id
    join players pb on pb.id = b.player_id
   where a.round_id = p_round_id
     and (
       a.external_id = b.external_id
       or (a.song_key is not null and a.song_key = b.song_key)
       or (a.song_key is not null and b.song_key is not null
           and similarity(a.song_key, b.song_key) > 0.62)
     );
$$ language sql stable;

commit;
