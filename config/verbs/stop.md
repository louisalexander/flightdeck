---
id: stop
label: STOP
key: escape
requires: working,blocked
interrupt: true
---
Interrupts the agent. Sends escape to its terminal; nothing is queued and no
prompt is delivered.

Valid only against an agent that is working or blocked, because those are the
only states where there is something to interrupt. Against an idle agent it
refuses rather than sending a stray escape into a prompt box.

Note what this does NOT do: it stops the current turn, it does not undo what
the turn already did. Files already written stay written, commands already run
stay run. To reverse work, interrupt first and then say what to revert.
