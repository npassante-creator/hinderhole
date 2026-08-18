#!/usr/bin/env python3
"""Adds the GIF picker to the chat client."""
import pathlib, sys

p = pathlib.Path('public/chat.js')
s = p.read_text()

if 'gifpicker' in s:
    print("    already there, skipping")
    sys.exit(0)

# render() must draw media
s = s.replace(
    """    var body = document.createElement('p');
    body.className = 'msg__body';
    body.textContent = m.body;

    li.appendChild(meta);
    li.appendChild(body);
    return li;""",
    """    li.appendChild(meta);

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

    return li;"""
)

# send() carries a pending gif
s = s.replace(
    "  function send() {\n    var body = box.value.trim();\n    if (!body) return;",
    "  var pending = null;   // a chosen gif, waiting to be sent\n\n"
    "  function send() {\n    var body = box.value.trim();\n    if (!body && !pending) return;"
)

s = s.replace(
    "      body: JSON.stringify({ body: body }),",
    "      body: JSON.stringify({ body: body, media: pending }),"
)

s = s.replace(
    """      .then(function (d) {
        box.value = '';
        append([d.message]);""",
    """      .then(function (d) {
        box.value = '';
        clearPending();
        append([d.message]);"""
)

# the picker itself
s = s.replace(
    "  paintTimes();\n  toBottom();\n  schedule();",
    """  // ---- the gif picker -------------------------------------------

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

  paintTimes();
  toBottom();
  schedule();"""
)

p.write_text(s)
print("    done")
