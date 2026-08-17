#!/usr/bin/env bash
#
# Clears everything from testing and puts the season back to its starting
# position, ready for the real roster.
#
# It reports first and does nothing until you type the confirmation, so
# running it to see what it would remove is safe.
#
# What it removes:
#   - every demo player (@demo.invalid) and everything attached to them
#   - all submissions, votes, and comments on every round
#   - orphaned uploaded audio files
#   - sent-reminder records, so nudges fire properly in the real season
#   - login tokens (sessions are kept, so you stay signed in)
#
# What it keeps:
#   - real players and the roster
#   - the league, its invite code, dues, and payout settings
#   - category suggestions
#
set -euo pipefail
cd /var/www/hinderhole

DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)
MEDIA_DIR=$(grep '^MEDIA_DIR=' .env | cut -d= -f2- || echo /var/lib/hinderhole/media)

echo
echo "=============================================="
echo " Current state"
echo "=============================================="
psql "$DBURL" -q -c "
select
  (select count(*) from players where email like '%@demo.invalid') as demo_players,
  (select count(*) from players where email not like '%@demo.invalid') as real_players,
  (select count(*) from submissions) as submissions,
  (select count(*) from votes) as votes,
  (select count(*) from comments) as comments;"

psql "$DBURL" -q -c "
select round_number, status,
       submit_deadline at time zone 'America/Chicago' as songs_due
  from rounds order by round_number;"

echo
echo "=============================================="
echo " This will DELETE all of the above submissions,"
echo " votes, comments, and demo players."
echo "=============================================="
echo
read -r -p 'Type  RESET  to go ahead: ' answer
if [ "$answer" != "RESET" ]; then
  echo "Nothing changed."
  exit 0
fi

echo
echo "==> noting uploaded files so they can be cleaned up after"
psql "$DBURL" -At -c "
  select external_id from submissions where source = 'upload';" > /tmp/ml-orphans.txt || true

echo "==> clearing play data"
psql "$DBURL" -v ON_ERROR_STOP=1 <<'SQL'
begin;

-- Votes and comments go first, though the cascades would handle it.
delete from votes;
delete from comments;
delete from submissions;
delete from vote_waivers;
delete from reminders_sent;

-- Demo players and their memberships.
delete from memberships m
 using players p
 where m.player_id = p.id
   and p.email like '%@demo.invalid';

delete from players where email like '%@demo.invalid';

-- Old magic links. Sessions stay, so nobody signed in gets kicked out.
delete from login_tokens;

-- Put the season back to its starting position.
update rounds set status = 'draft', on_hold = false;
update rounds set status = 'submitting' where round_number = 1;

commit;
SQL

echo "==> restoring the real season dates"
psql "$DBURL" -v ON_ERROR_STOP=1 <<'SQL'
begin;
set local timezone to 'America/Chicago';

update rounds set submit_deadline = d.songs, vote_deadline = d.votes
  from (values
    (1,  '2026-09-04 17:00'::timestamp, '2026-09-09 17:00'::timestamp),
    (2,  '2026-09-11 17:00',            '2026-09-16 17:00'),
    (3,  '2026-09-18 17:00',            '2026-09-23 17:00'),
    (4,  '2026-09-25 17:00',            '2026-09-30 17:00'),
    (5,  '2026-10-02 17:00',            '2026-10-07 17:00'),
    (6,  '2026-10-09 17:00',            '2026-10-14 17:00'),
    (7,  '2026-10-16 17:00',            '2026-10-21 17:00'),
    (8,  '2026-10-23 17:00',            '2026-10-28 17:00'),
    (9,  '2026-10-30 17:00',            '2026-11-04 17:00'),
    (10, '2026-11-06 17:00',            '2026-11-11 17:00')
  ) as d(n, songs, votes)
 where rounds.round_number = d.n;

commit;
SQL

echo "==> removing orphaned audio files"
if [ -d "$MEDIA_DIR" ] && [ -s /tmp/ml-orphans.txt ]; then
  while read -r key; do
    [ -n "$key" ] && rm -f "$MEDIA_DIR/$key"
  done < /tmp/ml-orphans.txt
  echo "    done"
else
  echo "    nothing to remove"
fi
rm -f /tmp/ml-orphans.txt

echo
echo "=============================================="
echo " Fresh state"
echo "=============================================="
psql "$DBURL" -q -c "
select
  (select count(*) from players) as players,
  (select count(*) from submissions) as submissions,
  (select count(*) from votes) as votes;"

psql "$DBURL" -q -c "
select round_number, status,
       submit_deadline at time zone 'America/Chicago' as songs_due,
       vote_deadline   at time zone 'America/Chicago' as votes_due
  from rounds order by round_number;"

echo
echo "Next: add the roster at /admin, then send everyone the invite link."
