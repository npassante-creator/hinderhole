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

    li.appendChild(meta);

    if (m.body) {
      var body = document.createElement('p');
      body.className = 'msg__body';
      body.textContent = m.body;
      li.appendChild(body);
    }

    if (m.media && m.media.url) {
      var img = document.createElement('img');
      img.className = 'msg__gif';
      img.src = m.media.url;
      img.alt = m.media.alt || 'GIF';
      img.loading = 'lazy';
      // Width and height up front so the log does not jump as GIFs load.
      if (m.media.w) img.width = m.media.w;
      if (m.media.h) img.height = m.media.h;
      li.appendChild(img);
    }

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

  var pending = null;   // a chosen gif, waiting to be sent

  function send() {
    var body = box.value.trim();
    if (!body && !pending) return;

    box.disabled = true;
    state.textContent = '';

    fetch('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: body, media: pending }),
    })
      .then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || 'Did not send.');
          return d;
        });
      })
      .then(function (d) {
        box.value = '';
        clearPending();
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

  // ---- the gif picker -------------------------------------------

  var gifBtn = document.getElementById('gifbtn');
  var picker = document.getElementById('gifpicker');

  if (gifBtn && picker) {
    var gifSearch = picker.querySelector('.gif__search');
    var gifGrid = picker.querySelector('.gif__grid');
    var gifState = picker.querySelector('.gif__state');
    var searchTimer = null;
    var loaded = false;

    gifBtn.addEventListener('click', function () {
      var open = picker.hasAttribute('hidden');
      if (open) {
        picker.removeAttribute('hidden');
        gifBtn.setAttribute('aria-expanded', 'true');
        if (!loaded) { loaded = true; load(''); }
        gifSearch.focus();
      } else {
        picker.setAttribute('hidden', '');
        gifBtn.setAttribute('aria-expanded', 'false');
      }
    });

    gifSearch.addEventListener('input', function () {
      clearTimeout(searchTimer);
      // Beta keys allow about a hundred searches an hour, so do not fire
      // one per keystroke.
      searchTimer = setTimeout(function () { load(gifSearch.value.trim()); }, 450);
    });

    function load(q) {
      gifState.textContent = 'looking';
      gifGrid.textContent = '';
      fetch('/chat/gifs' + (q ? '?q=' + encodeURIComponent(q) : ''))
        .then(function (r) {
          return r.json().then(function (d) {
            if (!r.ok) throw new Error(d.error || 'Could not load GIFs.');
            return d;
          });
        })
        .then(function (d) {
          gifState.textContent = d.results.length ? '' : 'nothing found';
          d.results.forEach(function (g) {
            var b = document.createElement('button');
            b.type = 'button';
            b.className = 'gif__pick';
            var img = document.createElement('img');
            img.src = g.url;
            img.alt = g.alt;
            img.loading = 'lazy';
            b.appendChild(img);
            b.addEventListener('click', function () { choose(g); });
            gifGrid.appendChild(b);
          });
        })
        .catch(function (err) { gifState.textContent = err.message; });
    }

    function choose(g) {
      pending = { url: g.url, w: g.w, h: g.h, alt: g.alt };
      picker.setAttribute('hidden', '');
      gifBtn.setAttribute('aria-expanded', 'false');
      showPending(g);
      box.focus();
    }
  }

  function showPending(g) {
    clearPending(true);
    var strip = document.createElement('div');
    strip.className = 'gif__pending';
    strip.id = 'gifpending';

    var img = document.createElement('img');
    img.src = g.url;
    img.alt = g.alt;
    strip.appendChild(img);

    var x = document.createElement('button');
    x.type = 'button';
    x.className = 'gif__drop';
    x.textContent = 'remove';
    x.addEventListener('click', function () { clearPending(); });
    strip.appendChild(x);

    form.parentNode.insertBefore(strip, form);
  }

  function clearPending(keepValue) {
    if (!keepValue) pending = null;
    var old = document.getElementById('gifpending');
    if (old) old.remove();
  }

  // ---- attaching an image ---------------------------------------
  //
  // Phone photos are three to five megabytes. Shrinking in the browser
  // before sending means less waiting on a phone signal and no image
  // library on the server. Animated GIFs are sent untouched, because
  // drawing one to a canvas would flatten it to the first frame.

  var imgBtn = document.getElementById('imgbtn');
  var imgInput = document.getElementById('imginput');

  if (imgBtn && imgInput) {
    imgBtn.addEventListener('click', function () { imgInput.click(); });

    imgInput.addEventListener('change', function () {
      var file = imgInput.files && imgInput.files[0];
      imgInput.value = '';
      if (!file) return;
      if (!/^image\//.test(file.type)) {
        state.textContent = 'That is not an image.';
        return;
      }
      state.textContent = 'preparing';
      shrink(file).then(upload).catch(function (err) {
        state.textContent = err.message || 'Could not read that image.';
      });
    });
  }

  function shrink(file) {
    // Animated GIFs and anything already small go up as they are.
    if (file.type === 'image/gif' || file.size < 400 * 1024) {
      return Promise.resolve({ blob: file, w: null, h: null });
    }

    var MAX = 1600;
    // from-image so a photo taken sideways does not arrive sideways.
    return createImageBitmap(file, { imageOrientation: 'from-image' })
      .then(function (bmp) {
        var scale = Math.min(1, MAX / Math.max(bmp.width, bmp.height));
        var w = Math.round(bmp.width * scale);
        var h = Math.round(bmp.height * scale);

        var canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        canvas.getContext('2d').drawImage(bmp, 0, 0, w, h);
        bmp.close && bmp.close();

        return new Promise(function (done, fail) {
          canvas.toBlob(function (blob) {
            if (blob) done({ blob: blob, w: w, h: h });
            else fail(new Error('Could not process that image.'));
          }, 'image/jpeg', 0.82);
        });
      })
      .catch(function () {
        // Older browser, or a format createImageBitmap will not decode.
        return { blob: file, w: null, h: null };
      });
  }

  function upload(prepared) {
    var fd = new FormData();
    fd.append('image', prepared.blob, 'upload');
    if (prepared.w) fd.append('w', prepared.w);
    if (prepared.h) fd.append('h', prepared.h);

    state.textContent = 'uploading';
    return fetch('/chat/upload', { method: 'POST', body: fd })
      .then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || 'Upload failed.');
          return d;
        });
      })
      .then(function (d) {
        state.textContent = '';
        pending = { url: d.url, w: d.w, h: d.h, alt: 'Image' };
        showPending({ url: d.url, alt: 'Image' });
        box.focus();
      });
  }

  paintTimes();
  toBottom();
  schedule();
}());
