-- Music League: make the song key order-independent
--
-- "Radiohead - Idioteque" and "Idioteque - Radiohead" are the same song,
-- but concatenating in the order given produced two different strings
-- that scored 0.59 on similarity, under the threshold.
--
-- Sorting the words before joining turns that near miss into an exact
-- match, which is both stronger and cheaper than loosening the fuzzy
-- threshold and inviting false positives.

begin;

create or replace function song_key(p_artist text, p_title text)
returns text as $$
  with cleaned as (
    select regexp_replace(
             lower(
               -- Drop bracketed noise: (Official Video), [HD], (Remastered)
               regexp_replace(
                 coalesce(p_artist, '') || ' ' || coalesce(p_title, ''),
                 '[\(\[\{][^\)\]\}]*[\)\]\}]', ' ', 'g')
             ),
             -- Noise words that survive outside brackets, then punctuation.
             -- Punctuation becomes a space so words stay separable.
             '\m(official|video|audio|lyrics?|lyric|hd|hq|4k|remaster(ed)?|' ||
             'live|version|full|album|single|feat|ft|featuring|with|the|a|an|' ||
             'explicit|clean|mv|visualizer)\M|[^a-z0-9]',
             ' ', 'g'
           ) as text
  )
  select nullif(
    (select string_agg(w, '' order by w)
       from cleaned, unnest(string_to_array(cleaned.text, ' ')) as w
      where w <> ''),
    '');
$$ language sql immutable;

-- The stored keys were built by the old function, so rebuild them all.
update submissions set song_key = song_key(artist, title);

-- Exact matching now does the heavy lifting, so the fuzzy net can be a
-- little tighter without losing the case that prompted this.
drop function if exists song_seen_before(bigint, text, bigint);

create function song_seen_before(
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

commit;


-- Check it worked. Both of these should now be identical:
--
--   select song_key('Radiohead','Idioteque (Official Video)') as a,
--          song_key('','Idioteque [Live 2001] - Radiohead')  as b;
--
