-- Music League: Autumn 2026 season seed
--
-- Replaces the earlier placeholder seed. Real categories, real dates.
--
-- Deadlines are 5:00pm CENTRAL, not midnight, and not Pacific.
-- Note that DST ends Nov 1 2026, so rounds 9 and 10 fall in CST (UTC-6)
-- while rounds 1 through 8 are CDT (UTC-5). Setting the session timezone
-- and using plain timestamp literals lets Postgres work that out. Do not
-- hardcode UTC offsets here.

begin;

set local timezone to 'America/Chicago';

-- ---- edit this ------------------------------------------------
\set commissioner_email '''npassante@gmail.com'''
-- ---------------------------------------------------------------

insert into players (name, email)
values ('Nate', :commissioner_email)
on conflict (email) do nothing;

insert into leagues (name, points_per_voter, max_per_song, created_by)
select 'Autumn 2026', 10, 10, id
from players where email = :commissioner_email
returning id \gset league_

insert into memberships (league_id, player_id, role)
select :league_id, id, 'admin'
from players where email = :commissioner_email;


insert into rounds (
  league_id, round_number, title, description,
  status, submit_deadline, vote_deadline
)
values
  (:league_id,  1, 'First Song from a Band''s First Album', null,
   'submitting', '2026-09-04 17:00', '2026-09-09 17:00'),

  (:league_id,  2, 'Reggae / Ska / Dub', null,
   'draft', '2026-09-11 17:00', '2026-09-16 17:00'),

  (:league_id,  3, 'Indigenous / Aboriginal Bands', null,
   'draft', '2026-09-18 17:00', '2026-09-23 17:00'),

  (:league_id,  4, 'Hardcore', null,
   'draft', '2026-09-25 17:00', '2026-09-30 17:00'),

  (:league_id,  5, 'Song Played During an Assassination Attempt', null,
   'draft', '2026-10-02 17:00', '2026-10-07 17:00'),

  (:league_id,  6, '1958', null,
   'draft', '2026-10-09 17:00', '2026-10-14 17:00'),

  (:league_id,  7, 'Eastern European Bands', null,
   'draft', '2026-10-16 17:00', '2026-10-21 17:00'),

  (:league_id,  8, 'Song Played While Committing / Attempting a Murder', null,
   'draft', '2026-10-23 17:00', '2026-10-28 17:00'),

  (:league_id,  9, 'Obscure Metal', null,
   'draft', '2026-10-30 17:00', '2026-11-04 17:00'),

  (:league_id, 10, 'Hiney / Boof / Butt Rock', null,
   'draft', '2026-11-06 17:00', '2026-11-11 17:00');

commit;


-- Verify the deadlines landed correctly, including the DST shift
-- between rounds 8 and 9.
--
-- select round_number, title,
--        submit_deadline at time zone 'America/Chicago' as songs_due_ct,
--        vote_deadline   at time zone 'America/Chicago' as votes_due_ct,
--        submit_deadline as songs_due_utc
--   from rounds order by round_number;
