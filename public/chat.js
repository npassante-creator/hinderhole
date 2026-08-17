/* chat.js
 *
 * Polling, not a persistent connection. Mobile browsers suspend background
 * tabs and drop open connections, which would leave the room silently
 * stale. A poll that fails just polls again.
 *
 * It backs off when the tab is hidden and speeds up right after you send,
 * so a live conversation feels live without hammering the server when
 * nobody is looking.
 */
(function () {
  'use strict';

  var root = document.getElementById('chat');
  if (!root) return;

  var log = document.getElementById('chatlog');
  var form = document.getElementById('chatform');
  var box = document.getElementById('chatbox');
  var state = document.getElementById('chatstate');
  var empty = document.querySelector('.chat__empty');
  var moreBtn = document.querySelector('.chat__more');

  var newest = root.getAttribute('data-newest') || '0';
  var timer = null;
  var quick = 0;          // faster polls right after activity
  var oldest = firstId();

  // ---- helpers --------------------------------------------------

  function firstId() {
    var li = log.querySelector('.msg');
    return li ? li.getAttribute('data-id') : null;
  }

  function atBottom() {
    return window.innerHeight + window.scrollY >=
           document.body.offsetHeight - 120;
  }

  function toBottom() {
    window.scrollTo({ top: document.body.scrollHeight, behavior: 'auto' });
  }

  function when(iso) {
    var d = new Date(iso);
    var now = new Date();
    var sameDay = d.toDateString() === now.toDateString();
    return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) +
           (sameDay ? '' : ', ' + d.toLocaleDateString([], { month: 'short', day: 'numeric' }));
  }

  function paintTimes(scope) {
    (scope || document).querySelectorAll('.msg__when').forEach(function (t) {
      if (!t.textContent) t.textContent = when(t.getAttribute('datetime'));
    });
  }

  /* Built with DOM methods, never innerHTML, so a message containing
     angle brackets stays a message. */
  function render(m) {
    var li = document.createElement('li');
    li.className = 'msg' + (m.mine ? ' msg--mine' : '') +
                   (m.deleted ? ' msg--gone' : '');
    li.setAttribute('data-id', m.id);

    if (m.deleted) {
      var gone = document.createElement('p');
      gone.className = 'msg__body msg__body--gone';
      gone.textContent = 'message removed';
      li.appendChild(gone);
      return li;
    }

    var meta = document.createElement('p');
    meta.className = 'msg__meta';

    var who = document.createElement('span');
    who.className = 'msg__who';
    who.textContent = m.name;
    meta.appendChild(who);

    var time = document.createElement('time');
    time.className = 'msg__when';
    time.setAttribute('datetime', m.at);
    time.textContent = when(m.at);
    meta.appendChild(time);

    if (m.canRemove) {
      var x = document.createElement('button');
      x.className = 'msg__x';
      x.type = 'button';
      x.setAttribute('aria-label', 'Remove');
      x.innerHTML = '&times;';
      meta.appendChild(x);
    }

    var body = document.createElement('p');
    body.className = 'msg__body';
    body.textContent = m.body;

    li.appendChild(meta);
    li.appendChild(body);
    return li;
  }

  function append(list) {
    if (!list.length) return;
    var stick = atBottom();
    list.forEach(function (m) {
      if (log.querySelector('[data-id="' + m.id + '"]')) return;
      log.appendChild(render(m));
    });
    if (empty) empty.hidden = true;
    if (stick) toBottom();
  }

  // ---- polling --------------------------------------------------

  function interval() {
    if (document.hidden) return 30000;
    if (quick > 0) { quick--; return 2500; }
    return 6000;
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(poll, interval());
  }

  function poll() {
    fetch('/chat/since/' + newest, { headers: { 'Accept': 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (data) {
          newest = data.newest;
          append(data.messages);
        }
      })
      .catch(function () { /* offline, try again next tick */ })
      .finally(schedule);
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { quick = 2; poll(); }
  });

  // ---- sending --------------------------------------------------

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    send();
  });

  // Enter sends, shift-enter makes a new line. On a phone the button is
  // the obvious route, so only bind this where there is a real keyboard.
  box.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey && !matchMedia('(pointer: coarse)').matches) {
      e.preventDefault();
      send();
    }
  });

  function send() {
    var body = box.value.trim();
    if (!body) return;

    box.disabled = true;
    state.textContent = '';

    fetch('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: body }),
    })
      .then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || 'Did not send.');
          return d;
        });
      })
      .then(function (d) {
        box.value = '';
        append([d.message]);
        newest = d.message.id;
        quick = 3;
        toBottom();
      })
      .catch(function (err) { state.textContent = err.message; })
      .finally(function () {
        box.disabled = false;
        box.focus();
        schedule();
      });
  }

  // ---- removing -------------------------------------------------

  log.addEventListener('click', function (e) {
    var x = e.target.closest && e.target.closest('.msg__x');
    if (!x) return;
    var li = x.closest('.msg');
    if (!confirm('Remove this message?')) return;

    fetch('/chat/' + li.getAttribute('data-id') + '/remove', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    }).then(function (r) {
      if (r.ok) li.replaceWith(render({ id: li.getAttribute('data-id'), deleted: true }));
    });
  });

  // ---- older ----------------------------------------------------

  if (moreBtn) {
    moreBtn.addEventListener('click', function () {
      if (!oldest) return;
      moreBtn.disabled = true;
      fetch('/chat/before/' + oldest)
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var anchor = document.body.scrollHeight;
          data.messages.slice().reverse().forEach(function (m) {
            log.insertBefore(render(m), log.firstChild);
          });
          oldest = firstId();
          window.scrollBy(0, document.body.scrollHeight - anchor);
          if (!data.hasMore) moreBtn.remove();
          else moreBtn.disabled = false;
        })
        .catch(function () { moreBtn.disabled = false; });
    });
  }

  paintTimes();
  toBottom();
  schedule();
}());
