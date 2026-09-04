-- Music League: tell the commissioners about a collision, do not wait for
-- them to go looking.
--
-- Detection existed already but only rendered on the round sheet. If
-- nobody opened that page the duplicate went live and the first anyone
-- knew was two identical songs on the ballot.

begin;

-- One row per pair already reported, so a scheduler running every five
-- minutes does not send the same warning twelve times an hour.
create table if not exists collision_alerts (
  round_id      bigint not null references rounds(id) on delete cascade,
  a_submission  bigint not null,
  b_submission  bigint not null,
  sent_at       timestamptz not null default now(),
  primary key (round_id, a_submission, b_submission)
);

-- The existing function returns names and titles, which are no good as a
-- key: someone fixing their title would look like a new collision.
-- Recreate it carrying submission ids as well.
drop function if exists round_collisions(bigint);

create function round_collisions(p_round_id bigint)
returns table (
  a_id bigint, a_player text, a_title text,
  b_id bigint, b_player text, b_title text,
  how text
) as $$
  select a.id, pa.name, a.title,
         b.id, pb.name, b.title,
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
