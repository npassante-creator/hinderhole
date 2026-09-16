/* player.js
 *
 * Playback for the ballot and the results page.
 *
 *   - Nothing loads from YouTube until someone asks for it.
 *   - Clicking any song starts a run from there and keeps going.
 *   - Transport controls live in a bar fixed to the bottom of the
 *     screen, well away from the points buttons.
 *
 * Also carries the unread count on the chat link, which lives here
 * because this file is on every page.
 */
(function () {
  'use strict';

  var ytReady = null;
  var queue = { on: false, index: -1, players: [] };
  var bar = null;          // the bottom transport bar, built on first use

  // ---------------------------------------------------------------
  // YouTube API
  // ---------------------------------------------------------------
  // Fetched when the page loads, not on the first click. Loading it
  // inside a click handler meant the player was built a second later,
  // by which point the browser no longer treated playback as user
  // initiated and silently refused to start.

  function loadYT() {
    if (ytReady) return ytReady;
    ytReady = new Promise(function (done) {
      if (window.YT && window.YT.Player) return done(window.YT);
      var prev = window.onYouTubeIframeAPIReady;
      window.onYouTubeIframeAPIReady = function () {
        if (typeof prev === 'function') prev();
        done(window.YT);
      };
      var s = document.createElement('script');
      s.src = 'https://www.youtube.com/iframe_api';
      document.head.appendChild(s);
    });
    return ytReady;
  }

  // ---------------------------------------------------------------
  // Mounting and unmounting a single player
  // ---------------------------------------------------------------

  function stopOthers(except) {
    document.querySelectorAll('.player--live').forEach(function (host) {
      if (host !== except) collapse(host);
    });
  }

  function collapse(host) {
    if (host._yt && host._yt.destroy) {
      try { host._yt.destroy(); } catch (e) { /* already gone */ }
    }
    host._yt = null;
    var frame = host.querySelector('.player__frame, .player__mount');
    if (frame) frame.remove();
    if (host.dataset.facade && !host.querySelector('.player__facade')) {
      host.insertAdjacentHTML('afterbegin', host.dataset.facade);
    }
    host.classList.remove('player--live', 'player--current');
  }

  function stashFacade(host) {
    var facade = host.querySelector('.player__facade');
    if (facade) {
      host.dataset.facade = facade.outerHTML;
      facade.remove();
    }
  }

  function mount(host) {
    var source = host.getAttribute('data-source');
    var id = host.getAttribute('data-video');
    var embed = host.getAttribute('data-embed');
    if (!embed && !id) return Promise.resolve(false);

    stopOthers(host);
    stashFacade(host);
    host.classList.add('player--live', 'player--current');

    if (source === 'youtube' && id) {
      var slot = document.createElement('div');
      slot.className = 'player__mount';
      host.insertBefore(slot, host.firstChild);

      return loadYT().then(function (YT) {
        host._yt = new YT.Player(slot, {
          videoId: id,
          playerVars: { autoplay: 1, rel: 0, modestbranding: 1, playsinline: 1 },
          host: 'https://www.youtube-nocookie.com',
          events: {
            onReady: function (e) {
              // playerVars.autoplay is unreliable once a promise has
              // broken the gesture chain, so ask directly.
              try { e.target.playVideo(); } catch (err) { /* fine */ }
            },
            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED) advance();
              if (e.data === YT.PlayerState.PLAYING) setPlayPause(false);
              if (e.data === YT.PlayerState.PAUSED) setPlayPause(true);
            },
            onError: function () {
              // Embedding disabled, dead video, region block. Move on.
              note('That one will not play here. Skipping.');
              advance();
            }
          }
        });
        return true;
      });
    }

    var audio = host.querySelector('.player__audio');
    if (audio) {
      audio.play();
      audio.onended = function () { advance(); };
      audio.onplay = function () { setPlayPause(false); };
      audio.onpause = function () { setPlayPause(true); };
      return Promise.resolve(true);
    }

    // Spotify. No state events exist, so the run cannot continue itself.
    var frame = document.createElement('iframe');
    frame.src = embed;
    frame.className = 'player__frame';
    frame.style.height = '152px';
    frame.setAttribute('allow', 'autoplay; encrypted-media');
    frame.setAttribute('loading', 'lazy');
    frame.setAttribute('title', 'Player');
    host.insertBefore(frame, host.firstChild);
    note('Spotify cannot tell us when a track ends. Hit next when you are done.');
    return Promise.resolve(true);
  }

  // ---------------------------------------------------------------
  // The run
  // ---------------------------------------------------------------

  function collect() {
    return Array.prototype.slice.call(document.querySelectorAll('.player'))
      .filter(function (p) {
        return p.getAttribute('data-embed') || p.getAttribute('data-video');
      });
  }

  function titleOf(host) {
    var card = host.closest('.card, .result, li');
    if (!card) return '';
    var h = card.querySelector('.card__title, .result__title, .pick__title');
    return h ? h.textContent.trim() : '';
  }

  function play(i) {
    queue.players = queue.players.length ? queue.players : collect();
    if (i < 0 || i >= queue.players.length) return;

    queue.on = true;
    queue.index = i;
    var host = queue.players[i];

    document.querySelectorAll('.player--current').forEach(function (p) {
      if (p !== host) p.classList.remove('player--current');
    });

    host.scrollIntoView({
      behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches
        ? 'auto' : 'smooth',
      block: 'center'
    });

    showBar();
    setNowPlaying(i, titleOf(host));
    setPlayPause(false);

    mount(host).catch(function () {
      note('Could not start that one.');
    });
  }

  function advance() {
    if (!queue.on) return;
    if (queue.index + 1 >= queue.players.length) {
      return stop('That is the lot.');
    }
    play(queue.index + 1);
  }

  function skip() { advance(); }

  function back() {
    if (!queue.on) return;
    var yt = current();
    // More than ten seconds in, restart this one. Same as every player.
    if (yt && yt.getCurrentTime && yt.getCurrentTime() > 10) {
      yt.seekTo(0);
      return;
    }
    if (queue.index > 0) play(queue.index - 1);
    else if (yt && yt.seekTo) yt.seekTo(0);
  }

  function startFromTop() {
    queue.players = collect();
    if (queue.players.length) play(0);
  }

  function stop(msg) {
    queue.on = false;
    queue.index = -1;
    stopOthers(null);
    hideBar(msg);
  }

  function current() {
    var host = queue.players[queue.index];
    return host && host._yt ? host._yt : null;
  }

  function togglePause() {
    var yt = current();
    if (yt && yt.getPlayerState) {
      if (yt.getPlayerState() === 1) { yt.pauseVideo(); setPlayPause(true); }
      else { yt.playVideo(); setPlayPause(false); }
      return;
    }
    var host = queue.players[queue.index];
    var audio = host && host.querySelector('.player__audio');
    if (audio) {
      if (audio.paused) audio.play();
      else audio.pause();
    }
  }

  // ---------------------------------------------------------------
  // The bottom bar
  // ---------------------------------------------------------------
  // Deliberately not next to the points buttons. Reaching for next and
  // hitting a 7 by mistake is a worse bug than any of this.

  function buildBar() {
    if (bar) return bar;

    bar = document.createElement('div');
    bar.className = 'nowbar';
    bar.setAttribute('hidden', '');
    bar.innerHTML =
      '<div class="nowbar__inner">' +
        '<div class="nowbar__meta">' +
          '<span class="nowbar__pos"></span>' +
          '<span class="nowbar__title"></span>' +
        '</div>' +
        '<div class="nowbar__controls">' +
          '<button class="nowbar__btn" type="button" data-act="prev" aria-label="Previous">&#9664;&#9664;</button>' +
          '<button class="nowbar__btn nowbar__btn--play" type="button" data-act="playpause" aria-label="Pause">&#10074;&#10074;</button>' +
          '<button class="nowbar__btn" type="button" data-act="next" aria-label="Next">&#9654;&#9654;</button>' +
          '<button class="nowbar__btn nowbar__btn--stop" type="button" data-act="stop" aria-label="Stop">&times;</button>' +
        '</div>' +
      '</div>' +
      '<p class="nowbar__note"></p>';

    document.body.appendChild(bar);
    document.body.classList.add('has-nowbar');
    return bar;
  }

  function showBar() {
    buildBar().removeAttribute('hidden');
    document.body.classList.add('nowbar-open');
  }

  function hideBar(msg) {
    if (!bar) return;
    bar.setAttribute('hidden', '');
    document.body.classList.remove('nowbar-open');
    if (msg) setStatus(msg);
  }

  function setNowPlaying(i, title) {
    buildBar();
    var pos = bar.querySelector('.nowbar__pos');
    var t = bar.querySelector('.nowbar__title');
    if (pos) pos.textContent = (i + 1) + ' of ' + queue.players.length;
    if (t) t.textContent = title || '';
    note('');
  }

  function setPlayPause(paused) {
    if (!bar) return;
    var b = bar.querySelector('[data-act="playpause"]');
    if (!b) return;
    b.innerHTML = paused ? '&#9654;' : '&#10074;&#10074;';
    b.setAttribute('aria-label', paused ? 'Play' : 'Pause');
  }

  /** A transient line in the bottom bar. */
  function note(text) {
    if (!bar) return;
    var n = bar.querySelector('.nowbar__note');
    if (n) n.textContent = text || '';
  }

  /** The old status line up top, still used when a run ends. */
  function setStatus(text) {
    var el = document.querySelector('.queuebar__status');
    if (el) el.textContent = text || '';
    var btn = document.querySelector('.queuebar__toggle');
    if (btn) btn.textContent = 'Play all';
  }

  // ---------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------

  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;

    // Clicking a song starts the run from that song rather than playing
    // it alone. Wanting to hear one and then stop is the rarer case.
    var facade = e.target.closest('.player__facade');
    if (facade) {
      var host = facade.closest('.player');
      queue.players = collect();
      var idx = queue.players.indexOf(host);
      play(idx === -1 ? 0 : idx);
      return;
    }

    var toggle = e.target.closest('.queuebar__toggle');
    if (toggle) {
      if (queue.on) stop(null);
      else startFromTop();
      return;
    }

    var act = e.target.closest('.nowbar__btn');
    if (act) {
      var what = act.getAttribute('data-act');
      if (what === 'next') skip();
      else if (what === 'prev') back();
      else if (what === 'playpause') togglePause();
      else if (what === 'stop') stop(null);
    }
  });

  function preload() {
    if (document.querySelector('.player[data-video]')) loadYT();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', preload);
  } else {
    preload();
  }
}());


/* Unread count on whichever header link points at the chat. Lives here
   because player.js is on every page, so no template needs touching. */
(function () {
  'use strict';

  var link = document.querySelector('a[href="/chat"]');
  if (!link) return;
  if (location.pathname.replace(/\/+$/, '') === '/chat') return;

  function paint(n) {
    var badge = link.querySelector('.chat__badge');
    if (!n) { if (badge) badge.remove(); return; }
    if (!badge) {
      badge = document.createElement('span');
      badge.className = 'chat__badge';
      link.appendChild(badge);
    }
    badge.textContent = n > 99 ? '99+' : String(n);
  }

  function check() {
    if (document.hidden) return;
    fetch('/chat/unread', { headers: { 'Accept': 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d) paint(d.unread); })
      .catch(function () { /* offline, no badge, no harm */ });
  }

  check();
  setInterval(check, 60000);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) check();
  });
}());
