-- Music League: passwordless auth
-- Magic links over SendGrid. No passwords to store, reset, or leak.

begin;

alter table players
  add column if not exists last_login_at timestamptz,
  add column if not exists is_active boolean not null default true;


-- ---------------------------------------------------------------
-- One time login links
-- ---------------------------------------------------------------
-- Only the SHA-256 hash is stored. A database dump does not let anyone
-- log in as anybody.

create table login_tokens (
  id           bigserial primary key,
  player_id    bigint not null references players(id) on delete cascade,
  token_hash   text not null unique,
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  requested_ip inet,
  created_at   timestamptz not null default now()
);

create index login_tokens_player_idx on login_tokens (player_id, created_at desc);
create index login_tokens_expiry_idx on login_tokens (expires_at);


-- ---------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------
-- Long lived on purpose. A ten week season should not make anyone
-- re-authenticate every Friday.

create table sessions (
  id           bigserial primary key,
  player_id    bigint not null references players(id) on delete cascade,
  token_hash   text not null unique,
  user_agent   text,
  ip           inet,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz
);

create index sessions_player_idx on sessions (player_id);
create index sessions_expiry_idx on sessions (expires_at);


-- ---------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------
-- Call from the same scheduler that advances round status.

create or replace function purge_expired_auth() returns void as $$
begin
  delete from login_tokens
   where expires_at < now() - interval '1 day';

  delete from sessions
   where expires_at < now() - interval '7 days'
      or (revoked_at is not null and revoked_at < now() - interval '7 days');
end;
$$ language plpgsql;

commit;
