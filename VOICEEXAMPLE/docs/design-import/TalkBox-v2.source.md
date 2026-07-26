# TalkBox v2 — source pointer

Canonical file: Claude Design project `TalkBox Voice Agent Design`
(projectId c7ba3811-4be7-4f67-b067-7d6475f63552), file `TalkBox v2.dc.html`.
Fetch with DesignSync get_file. Layout summary:

- 1024x664 light window, two panes.
- LEFT speaker bay (336px): traffic lights, script "TalkBox" wordmark,
  224px speaker plate (corner screws, circular dot grille, blue glow
  while speaking, recessed LED: green=playing amber=paused gray=idle),
  round transport: Play (blue, enabled when idle+queue), Pause/Resume,
  Skip.
- RIGHT: Queue|Settings segmented tabs (top-right).
  QUEUE: speaking card (#E3EEFC bg, #0A7CFF EQ bars + bottom progress,
  badge 'SPEAKING · #N'), pillar rows (54px, pastel bg, number circle,
  up/down/x), dashed empty state with 'Copy AGENTS.md to get started',
  right-aligned Autoplay toggle + Clear, History (status chip + secs +
  Requeue).
  SETTINGS: cards 'Speech' (Voice select: Samantha/Alex/Daniel/Karen/
  Moira; rate 0.5-2x; gap 0-5s), 'Server' (port, make-public toggle,
  Copy AGENTS.md), 'General' (login, keep-on-top).
- Status bar: green dot 'Listening on host:port'.
- Palette: bg #F5F5F7, cards #FFF border #D8D8DD, ink #1D1D1F,
  muted #86868B/#515154, blue #0A7CFF (hover #0669D6), speaking tint
  #E3EEFC/#BAD5F5 badge #2D6AC0, done chip #DDF0E3/#3F7D57,
  neutral chip #E9E9ED, status green #34C759.
