#!/usr/bin/env python3
"""Shows comment authors and the penalty in the templates."""
import pathlib, sys
did = []

# --- results.ejs: named comments + penalty line -------------------
p = pathlib.Path('views/results.ejs')
s = p.read_text()

if 'chatter__who' not in s:
    old = """              <ul class="chatter">
                <% s.comments.forEach(function (c) { %>
                  <li class="chatter__line"><%= c %></li>
                <% }) %>
              </ul>"""
    new = """              <ul class="chatter">
                <% s.comments.forEach(function (c) { %>
                  <li class="chatter__line">
                    <span class="chatter__who"><%= c.author %></span>
                    <%= c.body %>
                  </li>
                <% }) %>
              </ul>"""
    if old not in s:
        sys.exit('results.ejs: could not find the chatter list.')
    s = s.replace(old, new, 1)
    did.append('named comments')

if 'result__penalty' not in s:
    old = """          <p class="result__by">
            <span class="result__submitter"><%= s.submitter %></span>"""
    new = """          <% if (s.penalty) { %>
            <p class="result__penalty">
              <%= s.raw_points %> earned, <%= s.penalty %> deducted for
              <%= s.penalty %> unspent vote<%= s.penalty === 1 ? '' : 's' %>
            </p>
          <% } %>

          <p class="result__by">
            <span class="result__submitter"><%= s.submitter %></span>"""
    if old in s:
        s = s.replace(old, new, 1)
        did.append('penalty line')

p.write_text(s)

# --- standings.ejs: show the deduction ----------------------------
p = pathlib.Path('views/standings.ejs')
s = p.read_text()

if 'league__penalty' not in s:
    old = """            <span class="league__detail">
              <%= row.rounds_played %> rounds<% if (row.wins) { %> &middot; <%= row.wins %> won<% } %>
            </span>"""
    new = """            <span class="league__detail">
              <%= row.rounds_played %> rounds<% if (row.wins) { %> &middot; <%= row.wins %> won<% } %>
              <% if (row.total_penalty) { %>
                <span class="league__penalty">&middot; &minus;<%= row.total_penalty %> unspent</span>
              <% } %>
            </span>"""
    if old in s:
        s = s.replace(old, new, 1)
        did.append('standings deduction')
        p.write_text(s)

print("    " + (", ".join(did) if did else "all already patched"))
