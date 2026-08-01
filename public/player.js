/* player.js
 *
 * Two jobs:
 *   1. Click to load. Twenty embeds do not load until they are wanted.
 *   2. Play all. Runs the page top to bottom, advancing when a song ends.
 *
 * YouTube needs its IFrame API for the "ended" event, so that script is
 * fetched lazily the first time anything plays. Uploaded audio uses the
 * native ended event. Spotify embeds cannot report state, so continuous
 * play pauses there and waits for a nudge.
 */
(function () {
  'use strict';

  var ytReady = null;
  var queue = { on: false, index: -1, players: [] };

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

  function mount(host, autoAdvance) {
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
            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED && autoAdvance) advance();
            },
            onError: function () {
              if (autoAdvance) advance();
            }
          }
        });
        return true;
      });
    }

    var audio = host.querySelector('.player__audio');
    if (audio) {
      audio.play();
      if (autoAdvance) {
        audio.onended = function () { advance(); };
      }
      return Promise.resolve(true);
    }

    var frame = document.createElement('iframe');
    frame.src = embed;
    frame.className = 'player__frame';
    frame.style.height = '152px';
    frame.setAttribute('allow', 'autoplay; encrypted-media');
    frame.setAttribute('loading', 'lazy');
    frame.setAttribute('title', 'Player');
    host.insertBefore(frame, host.firstChild);

    if (autoAdvance) {
      queue.on = false;
      setBar('Spotify cannot report when a track ends. Press play all again to carry on.');
    }
    return Promise.resolve(true);
  }

  function collect() {
    return Array.prototype.slice.call(document.querySelectorAll('.player'))
      .filter(function (p) {
        return p.getAttribute('data-embed') || p.getAttribute('data-video');
      });
  }

  function advance() {
    if (!queue.on) return;
    var next = queue.index + 1;
    if (next >= queue.players.length) return stop('Reached the end of the round.');
    play(next);
  }

  function play(i) {
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
    setBar('Playing ' + (i + 1) + ' of ' + queue.players.length);
    mount(host, true);
  }

  function start() {
    queue.players = collect();
    if (!queue.players.length) return;
    queue.on = true;
    play(0);
  }

  function stop(msg) {
    queue.on = false;
    stopOthers(null);
    setBar(msg || null);
  }

  function setBar(text) {
    var bar = document.querySelector('.queuebar__status');
    if (bar) bar.textContent = text || '';
    var btn = document.querySelector('.queuebar__toggle');
    if (btn) btn.textContent = queue.on ? 'Stop' : 'Play all';
  }

  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;

    var facade = e.target.closest('.player__facade');
    if (facade) {
      queue.on = false;
      setBar(null);
      mount(facade.closest('.player'), false);
      return;
    }

    var toggle = e.target.closest('.queuebar__toggle');
    if (toggle) {
      if (queue.on) stop(null);
      else start();
    }
  });
}());
