/* ballot.js
 *
 * Point allocation that saves as it changes. No submit button, because a
 * five day voting window means people will close the tab mid-way and a
 * forgotten submit would lose the lot.
 *
 * The server is the authority on the budget. This only mirrors it, and
 * rolls back the pips if the server disagrees.
 */
(function () {
  'use strict';

  var tally = document.getElementById('tally');
  if (!tally) return;

  var roundId = tally.getAttribute('data-round');
  var budget = Number(tally.getAttribute('data-budget'));
  var spent = Number(tally.getAttribute('data-spent'));

  var spentEl = tally.querySelector('.tally__spent');
  var fillEl = tally.querySelector('.tally__fill');
  var stateEl = tally.querySelector('.tally__state');

  function paint(msg, bad) {
    spentEl.textContent = spent;
    fillEl.style.width = Math.min(100, Math.round(spent / budget * 100)) + '%';
    tally.classList.toggle('tally--full', spent === budget);
    tally.classList.toggle('tally--over', spent > budget);
    if (msg) {
      stateEl.textContent = msg;
      stateEl.className = 'tally__state' + (bad ? ' tally__state--bad' : '');
    } else if (spent === budget) {
      stateEl.textContent = 'All in.';
      stateEl.className = 'tally__state';
    } else {
      stateEl.textContent = (budget - spent) + ' left';
      stateEl.className = 'tally__state';
    }
  }

  function post(url, payload) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then(function (res) {
      return res.json().then(function (data) {
        if (!res.ok) throw new Error(data.error || 'Something went wrong.');
        return data;
      });
    });
  }

  // ---- points ---------------------------------------------------

  document.addEventListener('click', function (e) {
    var pip = e.target.closest && e.target.closest('.dial__pip');
    if (!pip) return;

    var card = pip.closest('.card');
    var dial = pip.closest('.dial');
    var points = Number(pip.getAttribute('data-points'));

    var was = dial.querySelector('.dial__pip.is-on');
    var wasPoints = was ? Number(was.getAttribute('data-points')) : 0;
    if (points === wasPoints) return;

    // Optimistic: move the pip now, correct it if the server objects.
    setPip(dial, points);
    spent = spent - wasPoints + points;
    paint(null);
    card.classList.add('card--saving');

    post('/round/' + roundId + '/vote', {
      submission_id: Number(card.getAttribute('data-submission')),
      points: points,
    }).then(function (data) {
      spent = data.spent;
      card.classList.remove('card--saving');
      card.classList.add('card--saved');
      setTimeout(function () { card.classList.remove('card--saved'); }, 900);
      paint(null);
    }).catch(function (err) {
      setPip(dial, wasPoints);
      spent = spent - points + wasPoints;
      card.classList.remove('card--saving');
      paint(err.message, true);
    });
  });

  function setPip(dial, points) {
    dial.querySelectorAll('.dial__pip').forEach(function (p) {
      var on = Number(p.getAttribute('data-points')) === points;
      p.classList.toggle('is-on', on);
      p.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  // ---- comments, saved on pause -------------------------------

  var timers = new WeakMap();

  document.addEventListener('input', function (e) {
    var box = e.target;
    if (!box.classList || !box.classList.contains('say__box')) return;

    var card = box.closest('.card');
    var state = box.parentElement.querySelector('.say__state');
    state.textContent = '';

    clearTimeout(timers.get(box));
    timers.set(box, setTimeout(function () {
      state.textContent = 'saving';
      post('/round/' + roundId + '/comment', {
        submission_id: Number(card.getAttribute('data-submission')),
        body: box.value,
      }).then(function () {
        state.textContent = box.value.trim() ? 'saved' : '';
      }).catch(function (err) {
        state.textContent = err.message;
      });
    }, 700));
  });

  paint(null);
}());
