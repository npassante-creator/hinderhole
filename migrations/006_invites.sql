-- Music League: self signup by invite link
--
-- A league gets a secret code. Anyone holding the link can add themselves,
-- but the code is unguessable and the commissioner can rotate it, which
-- kills every old link at once.
--
-- Joining does not grant access on its own. The new player still has to
-- click a magic link sent to the address they typed, so a made up email
-- gets nobody in.

begin;

alter table leagues
  add column if not exists invite_code text unique,
  add column if not exists invites_open boolean not null default true;

-- Records how someone got on the roster, so the commissioner can tell
-- a self signup from a hand added player.
alter table memberships
  add column if not exists joined_via text not null default 'admin';

create or replace function new_invite_code() returns text as $$
  -- Lower case, no vowels, so it cannot spell anything and cannot be
  -- confused when read aloud.
  select string_agg(
    substr('bcdfghjkmnpqrstvwxz23456789',
           floor(random() * 27)::int + 1, 1), '')
  from generate_series(1, 12);
$$ language sql volatile;

update leagues
   set invite_code = new_invite_code()
 where invite_code is null;

commit;
