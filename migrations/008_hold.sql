-- Music League: per round hold
--
-- The league wide auto_advance switch is too blunt for "wait a day on this
-- one round". A hold pins a single round in place while the rest of the
-- season keeps running on its own.

begin;

alter table rounds
  add column if not exists on_hold boolean not null default false;

commit;
