-- Music League: media on chat messages
--
-- Deliberately generic rather than gif-specific. Image uploads will use
-- the same columns, and if Giphy ever changes terms the swap is one
-- source value.

begin;

alter table messages
  add column if not exists media_url  text,
  add column if not exists media_kind text,   -- 'gif' or 'image'
  add column if not exists media_w    integer,
  add column if not exists media_h    integer,
  add column if not exists media_alt  text;

-- A message must say something or show something.
alter table messages drop constraint if exists messages_body_check;
alter table messages alter column body drop not null;

alter table messages
  add constraint messages_has_content
  check (
    (body is not null and length(btrim(body)) between 1 and 2000)
    or media_url is not null
  );

commit;
