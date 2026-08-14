---
id: note
label: NOTE
interrupt: false
confirm: false
---
Summarise this session so far and journal it to Obsidian.

The scrollback already holds everything that was said. What I want is the
part it does not carry — the shape of the session, written for whoever
picks it up next, which is usually me tomorrow having forgotten all of it:

- What we set out to do, and whether that is still what we are doing.
- What actually happened. The route, not just the destination — including
  what was tried and abandoned, so nobody tries it again.
- The decisions, and the reasons behind them. Especially the ones that
  could reasonably have gone the other way.
- What is unresolved: open questions, known-broken things, work
  deliberately deferred.
- Where to pick up. The next concrete step, not a direction.

Then write it into the journal vault over the Obsidian MCP server. The
vault id is `flightdeck`; dates and times are local.

- The day's note is `Journal/YYYY-MM-DD.md`.
- If that note does not exist yet, create it with `obsidian_create_note`,
  with frontmatter `tags: [flightdeck, journal]` and a `# YYYY-MM-DD`
  heading, then add your entry to it.
- If it does exist, add your entry with `obsidian_edit_note` using its
  append operation. Append — never replace, and never edit what is there.
  Other agents in the fleet journal into the same day's note, and their
  entries are not yours to rewrite.
- Head each entry `## HH:MM — <repo> · <branch>`, so a day reads as a
  timeline across the whole fleet rather than a pile of prose.
- Tell me the path you wrote to.

If the Obsidian MCP tools are not available in this session, do not
improvise a path on disk and do not journal into whatever vault you can
find. Say plainly that you cannot journal this, and print the summary
here instead. A summary I still have to paste somewhere is recoverable; a
note written where nobody will look for it is not.

Do not do any of the work you are describing. Summarising it is the whole
job.
