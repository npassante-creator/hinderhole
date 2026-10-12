#!/usr/bin/env bash
#
# Add reply threads to the results page.
#
# Comments were left anonymously during voting. After a round is revealed,
# authors are shown alongside their comments. Replies let people keep that
# conversation going, fully attributed from the first word.
#
# Changes:
#   - migration 018: comment_replies table; trigger blocks replies until
#     a round is revealed
#   - results.js: c.id added to comments query; replies loaded and keyed
#     by comment; POST /round/:id/reply; DELETE /reply/:id (author or admin)
#   - views/results.ejs: replies rendered under each comment; reply toggle
#     and inline form; AJAX post-and-inject; updated fineprint
#   - public/app.css: styles for nested reply list and inline form
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f results.js ]; then echo "Not in the app directory."; exit 1; fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit your changes first."; git status --short; exit 1
fi

DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)

cp results.js          /tmp/results.js.b34
cp views/results.ejs   /tmp/results.ejs.b34
cp public/app.css      /tmp/app.css.b34

# ---------------------------------------------------------------
# 1. Migration
# ---------------------------------------------------------------

echo "==> migration 018: comment_replies"
if psql "$DBURL" -c '\d comment_replies' &>/dev/null; then
  echo "    table exists, skipping migration"
else
  psql "$DBURL" -f migrations/018_replies.sql
  echo "    done"
fi

# ---------------------------------------------------------------
# 2. results.js — json middleware
# ---------------------------------------------------------------

echo "==> results.js: json middleware"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('results.js')
s = p.read_text()

marker = "const json = express.json();"
if marker in s:
    print("    already there, skipping"); sys.exit(0)

old = "const { requireAuth } = require('./auth');"
if old not in s:
    sys.exit('Could not find requireAuth import')

s = s.replace(old, old + "\n" + marker, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 3. results.js — add c.id to comments query; load replies
# ---------------------------------------------------------------

echo "==> results.js: comments query + reply loading"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('results.js')
s = p.read_text()

if 'replyByComment' in s:
    print("    already there, skipping"); sys.exit(0)

old = """      // Comments are attributed to nobody, on purpose.
      const { rows: comments } = await db.query(
        `select c.submission_id, c.body, p.name as author
           from comments c
           join players p on p.id = c.author_id
          where c.round_id = $1
          order by c.created_at`,
        [round.id]
      );

      const bySong = new Map();
      comments.forEach((c) => {
        if (!bySong.has(c.submission_id)) bySong.set(c.submission_id, []);
        bySong.get(c.submission_id).push({ body: c.body, author: c.author });
      });"""

new = """      // Comments attributed once the round is revealed.
      const { rows: comments } = await db.query(
        `select c.id, c.submission_id, c.body, p.name as author
           from comments c
           join players p on p.id = c.author_id
          where c.round_id = $1
          order by c.created_at`,
        [round.id]
      );

      const { rows: replyRows } = await db.query(
        `select r.id, r.comment_id, r.body, p.name as author
           from comment_replies r
           join players p on p.id = r.author_id
           join comments c on c.id = r.comment_id
          where c.round_id = $1
          order by r.created_at`,
        [round.id]
      );

      const replyByComment = new Map();
      replyRows.forEach((r) => {
        if (!replyByComment.has(r.comment_id)) replyByComment.set(r.comment_id, []);
        replyByComment.get(r.comment_id).push({ id: r.id, body: r.body, author: r.author });
      });

      const bySong = new Map();
      comments.forEach((c) => {
        if (!bySong.has(c.submission_id)) bySong.set(c.submission_id, []);
        bySong.get(c.submission_id).push({
          id: c.id,
          body: c.body,
          author: c.author,
          replies: replyByComment.get(c.id) || [],
        });
      });"""

if old not in s:
    sys.exit('Could not find comments query block — check for prior partial patch')

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 4. results.js — POST /reply and DELETE /reply/:id routes
# ---------------------------------------------------------------

echo "==> results.js: reply routes"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('results.js')
s = p.read_text()

if '/round/:id/reply' in s:
    print("    already there, skipping"); sys.exit(0)

old = "  return r;\n}\n\nmodule.exports = { router };"

new = """  // ---------------------------------------------------------------
  // Comment replies (revealed rounds only; names visible)
  // ---------------------------------------------------------------

  r.post('/round/:id/reply', requireAuth, loadRound, json, async (req, res, next) => {
    try {
      const round = req.round;
      if (round.status !== 'revealed') {
        return res.status(409).json({ error: 'Replies are only available after a round is revealed.' });
      }
      const commentId = Number(req.body.comment_id);
      const body      = String(req.body.body || '').trim();

      if (!Number.isInteger(commentId) || commentId <= 0) {
        return res.status(400).json({ error: 'Unknown comment.' });
      }
      if (!body) return res.status(400).json({ error: 'Reply cannot be empty.' });

      const { rows: check } = await db.query(
        'select id from comments where id = $1 and round_id = $2',
        [commentId, round.id]
      );
      if (!check[0]) return res.status(404).json({ error: 'Comment not found.' });

      const { rows: [reply] } = await db.query(
        `insert into comment_replies (comment_id, author_id, body)
         values ($1, $2, $3)
         returning id, body`,
        [commentId, req.player.id, body.slice(0, 500)]
      );

      res.json({ ok: true, reply: { id: reply.id, body: reply.body, author: req.player.name } });
    } catch (err) {
      if (err.code === 'P0001') return res.status(409).json({ error: err.message });
      next(err);
    }
  });

  r.delete('/reply/:id', requireAuth, async (req, res, next) => {
    try {
      const replyId = Number(req.params.id);
      if (!Number.isInteger(replyId) || replyId <= 0) {
        return res.status(400).json({ error: 'Unknown reply.' });
      }

      // Author can always delete their own reply.
      const { rows } = await db.query(
        'delete from comment_replies where id = $1 and author_id = $2 returning id',
        [replyId, req.player.id]
      );
      if (rows[0]) return res.json({ ok: true });

      // Admins can delete any reply in their league.
      const { rows: adminCheck } = await db.query(
        `select 1
           from comment_replies cr
           join comments c    on c.id  = cr.comment_id
           join rounds rd     on rd.id = c.round_id
           join memberships m on m.league_id = rd.league_id
                              and m.player_id = $2
                              and m.is_admin
          where cr.id = $1`,
        [replyId, req.player.id]
      );
      if (adminCheck[0]) {
        await db.query('delete from comment_replies where id = $1', [replyId]);
        return res.json({ ok: true });
      }

      res.status(403).json({ error: 'Not your reply.' });
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router };"""

if old not in s:
    sys.exit('Could not find return r / module.exports block')

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 5. views/results.ejs — render replies under each comment
# ---------------------------------------------------------------

echo "==> views/results.ejs: comment + reply block"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/results.ejs')
s = p.read_text()

if 'reply-thread' in s:
    print("    already there, skipping"); sys.exit(0)

old = """          <% if (s.comments.length) { %>
            <ul class="chatter">
              <% s.comments.forEach(function (c) { %>
                <li class="chatter__line">
                  <span class="chatter__who"><%= c.author %></span>
                  <%= c.body %>
                </li>
              <% }) %>
            </ul>
          <% } %>"""

new = """          <% if (s.comments.length) { %>
            <ul class="chatter">
              <% s.comments.forEach(function (c) { %>
                <li class="chatter__line" data-comment-id="<%= c.id %>">
                  <div class="chatter__top">
                    <span class="chatter__who"><%= c.author %></span>
                    <span class="chatter__body"><%= c.body %></span>
                  </div>
                  <% if (c.replies.length) { %>
                    <ul class="chatter chatter--replies">
                      <% c.replies.forEach(function (r) { %>
                        <li class="chatter__line chatter__line--reply" data-reply-id="<%= r.id %>">
                          <span class="chatter__who"><%= r.author %></span>
                          <span class="chatter__body"><%= r.body %></span>
                        </li>
                      <% }) %>
                    </ul>
                  <% } %>
                  <div class="reply-thread" data-comment="<%= c.id %>" data-round="<%= round.id %>">
                    <button class="reply-toggle" type="button">&#8629; Reply</button>
                    <form class="reply-form" hidden>
                      <input class="reply-input" type="text" maxlength="500" placeholder="Add a reply&hellip;" autocomplete="off">
                      <button class="chip reply-send" type="submit">Send</button>
                    </form>
                  </div>
                </li>
              <% }) %>
            </ul>
          <% } %>"""

if old not in s:
    sys.exit('Could not find the comment rendering block')

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 6. views/results.ejs — update fineprint
# ---------------------------------------------------------------

echo "==> views/results.ejs: fineprint"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/results.ejs')
s = p.read_text()

old = "      Comments stay anonymous. You can see what was said, never who said it."
new = "      Comments were anonymous during voting. Authors and replies are visible here."

if new in s:
    print("    already there, skipping"); sys.exit(0)
if old not in s:
    sys.exit('Could not find fineprint text')

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 7. views/results.ejs — reply JS
# ---------------------------------------------------------------

echo "==> views/results.ejs: reply script"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/results.ejs')
s = p.read_text()

if "reply-thread" in s and "fetch(" in s:
    print("    already there, skipping"); sys.exit(0)

old = "<%- include('partials/foot') %>"
new = """\
<script>
(function () {
  function esc(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
            .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
  }

  document.querySelectorAll('.reply-thread').forEach(function (thread) {
    var toggle    = thread.querySelector('.reply-toggle');
    var form      = thread.querySelector('.reply-form');
    var input     = thread.querySelector('.reply-input');
    var commentId = thread.dataset.comment;
    var roundId   = thread.dataset.round;

    toggle.addEventListener('click', function () {
      form.hidden = !form.hidden;
      if (!form.hidden) { input.focus(); }
    });

    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      var body = input.value.trim();
      if (!body) return;
      toggle.disabled = true;

      try {
        var res  = await fetch('/round/' + roundId + '/reply', {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ comment_id: commentId, body: body }),
        });
        var data = await res.json();
        if (!data.ok) { alert(data.error); return; }

        var li   = thread.closest('.chatter__line');
        var list = li.querySelector('.chatter--replies');
        if (!list) {
          list = document.createElement('ul');
          list.className = 'chatter chatter--replies';
          li.insertBefore(list, thread);
        }
        var item = document.createElement('li');
        item.className       = 'chatter__line chatter__line--reply';
        item.dataset.replyId = data.reply.id;
        item.innerHTML =
          '<span class="chatter__who">'  + esc(data.reply.author) + '</span>' +
          '<span class="chatter__body">' + esc(data.reply.body)   + '</span>';
        list.appendChild(item);

        input.value = '';
        form.hidden = true;
      } catch (err) {
        alert('Could not post reply. Try again.');
      } finally {
        toggle.disabled = false;
      }
    });
  });
}());
</script>
<%- include('partials/foot') %>"""

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

# ---------------------------------------------------------------
# 8. public/app.css — reply styles
# ---------------------------------------------------------------

echo "==> public/app.css: reply styles"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('public/app.css')
s = p.read_text()

if '.reply-thread' in s:
    print("    already there, skipping"); sys.exit(0)

additions = """
/* ---------------------------------------------------------------
   Reply threads (results page)
   --------------------------------------------------------------- */

.chatter--replies {
  margin: .4rem 0 .5rem .75rem;
  border-left: 2px solid var(--oxblood);
  padding-left: .6rem;
}

.chatter__line--reply {
  background: transparent;
  padding: .25rem 0;
  margin-bottom: .1rem;
}

.reply-thread {
  margin-top: .35rem;
}

.reply-toggle {
  background: none;
  border: none;
  color: var(--steel);
  font-family: var(--util);
  font-size: .64rem;
  letter-spacing: .06em;
  text-transform: uppercase;
  cursor: pointer;
  padding: 0;
  line-height: 1.4;
}

.reply-toggle:hover { color: var(--amber); }
.reply-toggle:disabled { opacity: .5; cursor: default; }

.reply-form {
  display: flex;
  gap: .4rem;
  margin-top: .4rem;
  align-items: center;
}

.reply-input {
  flex: 1;
  background: var(--field);
  border: 1px solid var(--steel);
  border-radius: var(--strip-radius);
  color: var(--stock);
  font-family: var(--body);
  font-size: .88rem;
  padding: .3rem .5rem;
  min-width: 0;
}

.reply-input::placeholder { color: var(--steel); }
.reply-input:focus { outline: 2px solid var(--amber); border-color: transparent; }
"""

p.write_text(s + additions)
print("    done")
PY

# ---------------------------------------------------------------
# Verify and restart
# ---------------------------------------------------------------

echo "==> syntax check"
node --check results.js || {
  echo "    FAILED — restoring backups"
  cp /tmp/results.js.b34       results.js
  cp /tmp/results.ejs.b34      views/results.ejs
  cp /tmp/app.css.b34          public/app.css
  exit 1
}
echo "    ok"

echo "==> verifying migration"
psql "$DBURL" -c "
select
  (select count(*)::int from information_schema.tables
    where table_schema = 'public'
      and table_name   = 'comment_replies') as table_exists,
  (select count(*)::int from pg_proc
    where proname = 'enforce_reply_rules')  as trigger_exists;"

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
pm2 show hinderhole | grep -E 'status|restarts'

rm -f /tmp/results.js.b34 /tmp/results.ejs.b34 /tmp/app.css.b34

echo
echo "==> git add -A && git commit -m 'Add reply threads on results page' && git push"
echo
echo "Smoke test: open a revealed round at /round/<id>/results."
echo "Each comment should show a 'Reply' button."
echo "Posting a reply should inject it below the comment without a page reload."
