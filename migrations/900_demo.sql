-- Demo data. Safe to run and safe to remove.
--
-- Everything created here is tagged joined_via = 'demo' and uses
-- @demo.invalid addresses, which cannot receive mail. The teardown at the
-- bottom of this file removes all of it and nothing else.
--
-- Run against round 1 of league 1. Adjust the two settings below if not.

begin;

\set league_id 1
\set round_id 1

-- ---------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------

insert into players (name, email) values
  ('Dale Kowalczyk',  'dale@demo.invalid'),
  ('Renata Voss',     'renata@demo.invalid'),
  ('Marcus Thibault', 'marcus@demo.invalid'),
  ('Jo Feeney',       'jo@demo.invalid'),
  ('Wendell Pike',    'wendell@demo.invalid'),
  ('Sasha Oyelaran',  'sasha@demo.invalid'),
  ('Ted Grumbach',    'ted@demo.invalid'),
  ('Priya Raman',     'priya@demo.invalid'),
  ('Boone Fletcher',  'boone@demo.invalid'),
  ('Ilse Márquez',    'ilse@demo.invalid'),
  ('Curtis Nakagawa', 'curtis@demo.invalid'),
  ('Georgia Best',    'georgia@demo.invalid')
on conflict (email) do nothing;

insert into memberships (league_id, player_id, role, joined_via, dues_paid_at)
select
  :league_id,
  p.id,
  'player',
  'demo',
  -- Most have paid, a few have not, so the pot total is interesting.
  case when p.email in ('ted@demo.invalid', 'boone@demo.invalid',
                        'georgia@demo.invalid')
       then null else now() - interval '9 days' end
from players p
where p.email like '%@demo.invalid'
on conflict (league_id, player_id) do nothing;


-- ---------------------------------------------------------------
-- Submissions
-- ---------------------------------------------------------------
-- Real, embeddable YouTube videos. Thumbnails come straight from the id,
-- so these render exactly like a live submission.
--
-- Two people are left without a song on purpose, so the round sheet has
-- something in the missing column. One submission is marked late.

with picks (email, vid, title, artist, note, late) as (values
  ('dale@demo.invalid',    'lIPan-rEQJA', 'Blitzkrieg Bop',        'Ramones',           'The obvious answer, but it is the obvious answer for a reason.', false),
  ('renata@demo.invalid',  'ktvTqknDobU', 'Radioactive',           'Imagine Dragons',   null, false),
  ('marcus@demo.invalid',  'fregObNcHC8', 'Dancing Queen',         'ABBA',              'Not their first album. I am aware. Fight me.', false),
  ('jo@demo.invalid',      'YlUKcNNmywk', 'Africa',                'Toto',              null, false),
  ('wendell@demo.invalid', 'A_MjCqQoLLA', 'Hey Jude',              'The Beatles',       null, false),
  ('sasha@demo.invalid',   'rY0WxgSXdEE', 'Fade to Black',         'Metallica',         'Cheating slightly on the theme.', false),
  ('ted@demo.invalid',     'kXYiU_JCYtU', 'Numb',                  'Linkin Park',       null, true),
  ('priya@demo.invalid',   '1w7OgIMMRc4', 'Sweet Child O Mine',    'Guns N Roses',      null, false),
  ('boone@demo.invalid',   'hTWKbfoikeg', 'Smells Like Teen Spirit','Nirvana',          'Bleach was first but nobody has heard it.', false),
  ('ilse@demo.invalid',    'y6120QOlsfU', 'Sandstorm',             'Darude',            null, false)
)
insert into submissions
  (round_id, player_id, source, source_url, external_id,
   title, artist, thumbnail_url, note, is_late, submitted_at)
select
  :round_id,
  p.id,
  'youtube',
  'https://www.youtube.com/watch?v=' || k.vid,
  k.vid,
  k.title,
  k.artist,
  'https://i.ytimg.com/vi/' || k.vid || '/hqdefault.jpg',
  k.note,
  k.late,
  now() - (random() * interval '3 days')
from picks k
join players p on p.email = k.email
on conflict (round_id, player_id) do nothing;

commit;


-- ===============================================================
-- TEARDOWN. Run this to remove every trace of the demo data.
-- ===============================================================
--
-- begin;
-- delete from memberships m using players p
--  where m.player_id = p.id and p.email like '%@demo.invalid';
-- delete from players where email like '%@demo.invalid';
-- commit;
--
-- Submissions, votes, and comments go with the players via cascade.
