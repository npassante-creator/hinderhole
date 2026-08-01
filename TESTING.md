# Testing the scheduler

Nothing here waits on a real Friday. Deadlines are editable and the
scheduler can be run one pass at a time.

## See what it would do, change nothing

    cd /var/www/hinderhole
    node scheduler.js --once --dry

Prints every transition and every email it would send, then exits. Safe to
run any time, including against live data.

## Run one pass without sending mail

    node scheduler.js --once --no-mail

Advances rounds for real. Emails are logged instead of sent.

## Run one pass for real

    node scheduler.js --once

## Force a transition in two minutes

Set a deadline just ahead of now, then run a pass.

    psql "$DBURL" -c "update rounds set submit_deadline = now() + interval '1 minute' where id = 1;"
    sleep 70
    node scheduler.js --once --dry

The dry run should announce that round 1 moves to voting. Drop --dry to
let it happen.

## Put the deadlines back

    psql "$DBURL" -f migrations/002_seed.sql

That rewrites the season dates. Safe to rerun; it only touches rounds.

Or set one round by hand, remembering these are Central:

    psql "$DBURL" -c "set timezone to 'America/Chicago';
      update rounds set submit_deadline = '2026-09-04 17:00',
                        vote_deadline   = '2026-09-09 17:00'
       where round_number = 1;"

## Stop it advancing anything while you poke around

Tap the "auto advance on" chip at /admin, or:

    psql "$DBURL" -c "update leagues set auto_advance = false where id = 1;"

The scheduler keeps running and still purges expired tokens, but leaves
rounds alone. Manual buttons in /admin keep working either way.

## Reminders

A person gets each nudge once per round, tracked in reminders_sent. To
test the same reminder twice:

    psql "$DBURL" -c "delete from reminders_sent where round_id = 1;"

Demo players at @demo.invalid are never emailed, in any mode.

## Watch it live

    pm2 logs hinderhole-cron

## Remove the demo data when you are done

See the teardown block at the bottom of migrations/900_demo.sql.
