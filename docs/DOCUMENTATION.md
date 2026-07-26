# How Motive Is Documented

> **Audience:** anyone adding a feature or a page.
> **Source of truth:** this file. The tree it describes lives under `docs/`.

Motive has two kinds of reader and they want opposite things. A human arriving
cold wants a narrative: what is this, why would I want it, show me it working. An
agent arriving mid-task wants a lookup: what is the exact shape of this call, what
are the defaults, what will reject me. Writing one document that serves both
produces a document that serves neither — prose too vague to act on, wrapped
around tables too dry to learn from.

So we split by *what the reader is doing*, not by what the code is called. Four
modes, each with its own directory, its own voice, and its own rule for when it
must change.

## The four modes

| Mode | Directory | The reader is… | Voice |
| --- | --- | --- | --- |
| **Guide** | `docs/guides/` | learning, start to finish | second person, ordered steps, one happy path |
| **Concept** | `docs/concepts/` | building a mental model | explanatory, why-first, no steps |
| **Component** | `docs/components/` | looking up one product | reference: types, parameters, defaults |
| **Recipe** | `EMBEDDING.md`, `INTEGRATIONS.md` | doing a specific task | task-titled, copy-pasteable, no theory |

Plus three that sit outside the grid because they describe the wire, the disk, or
the project rather than the code: `API.md` (REST), `FORMATS.md` (sprite
manifests), `reference/` (environment, CLI), and `RELEASING.md`.

The test for which mode a page belongs to is the question it answers:

- "How do I get started?" → guide
- "Why does it work that way?" → concept
- "What are the parameters of `X`?" → component
- "How do I do the specific thing Y?" → recipe

A page that answers two of these is two pages. The most common failure in a
growing doc set is a component reference that slowly grows a tutorial in the
middle of it; when you feel that happening, split and cross-link.

## The tree

```
docs/
  README.md              the map — reading paths by audience
  DOCUMENTATION.md       this file

  guides/                learn by doing
    QUICKSTART.md          five minutes: run the demo, drive it from a terminal
    DEMO.md                the full motive-demo user guide
    FIRST-APP.md           build your own companion from an empty package
    SPRITE-DESIGN.md       draw the art: grid, loops, timing, the checks
    TROUBLESHOOTING.md     symptom → cause → fix

  concepts/              the mental model
    QUEUE.md               why every action is a queue item
    STATES.md              states, triggers, transitions, and the render directive
    QUESTIONS.md           human-in-the-loop, and why agents cannot answer
    VOICE.md               speech out and in, and the entitlement gate
    RUNTIME.md             the runtime home, discovery, and auth

  components/            one page per product
    OVERVIEW.md            which product do I need
    CORE.md  SPRITE.md  UI.md  HTTP.md  MCP.md  AGENTS.md  VOICE.md

  reference/             exact facts, no narrative
    ENVIRONMENT.md         every environment variable and runtime file
    CLI.md                 executables, arguments, and scripts/
    STATE-PROFILES.md      which states to draw, per host

  ARCHITECTURE.md        layering and the invariants that hold it together
  EMBEDDING.md           recipe book for building on the packages
  API.md                 REST control plane
  FORMATS.md             sprite package manifests
  INTEGRATIONS.md        connecting agents
  RELEASING.md           cutting a release
  proposals/             design records; historical once shipped
```

The six top-level guides predate this structure and keep their paths on purpose:
they are linked from the README, from `CLAUDE.md`, from generated agent skills,
and from the wild. Stable URLs are worth more than a tidy tree.

## The page contract

Every page opens with a title, a metadata blockquote, and one paragraph that
answers "what is this page for" before any heading:

```markdown
# REST Control Plane

> **Audience:** anyone driving a running companion from outside the app.
> **Prerequisites:** a running Motive app.
> **Source of truth:** `Sources/MotiveHTTP/`, `ControlSchema.standardVerbs`.

A loopback HTTP server exposing the `MotiveControl` command surface…
```

**Source of truth** is the field that matters most, and it is there for agents.
It names the code a claim on the page can be checked against, so a reader who
distrusts the prose knows exactly where to go and a tool updating the code knows
exactly which page it just invalidated. Every page has one. If you cannot name
the source, the page is speculation and belongs in `proposals/`.

Beyond that:

- **Show the failure, not just the success.** A parameter's valid range is worth
  less than what happens when you exceed it. Motive's control surface answers
  vocabulary mistakes with a `valid` array precisely so callers can self-correct;
  docs should have the same posture.
- **Every code block must run.** Snippets are compiled mentally against real
  signatures, with real defaults. A snippet that drifts is worse than no snippet,
  because it is trusted.
- **Explain why once, link to it forever.** The reason a direct verb
  head-enqueues lives in `concepts/QUEUE.md`. `API.md` states the behavior and
  links. Rationale duplicated in four places is rationale that will disagree with
  itself in four places.
- **Name defaults inline.** `ttl` (ms, default 8000) — not "an optional TTL".
- **Use the vocabulary.** A **companion** is the running entity — it has a queue,
  asks questions, survives restarts. A **sprite** is the moving image and the
  package that defines it; sprites are data, never code. An **app** is the host
  process holding a companion. Winston is a companion, rendered as a sprite,
  hosted by `MotiveDemo`. The framework has no "pets": the word was retired
  because it flattened all three layers into one. `proposals/` predates the
  change and is left as written.

## Documenting a feature

A feature is not done when it is tested. It is done when a stranger can find it,
and this is the part of the workflow the doc structure exists to make mechanical.
Before opening a PR, walk the four modes and ask which are affected:

1. **Does it change the mental model?** New primitive, new lifecycle, a rule that
   surprises people → a `concepts/` page, or a section in one.
2. **Does it change a product's surface?** New public type or parameter → the
   matching `components/` page, plus `///` comments so DocC picks it up.
3. **Does it change the wire or the disk?** → `API.md`, `FORMATS.md`,
   `INTEGRATIONS.md`, or `reference/ENVIRONMENT.md`. These are the pages agents
   read; they are also the ones that go stale fastest, because the source moves
   without the prose.
4. **Can someone now do something they could not before?** → a recipe in
   `EMBEDDING.md`, and a line in the `[Unreleased]` section of `CHANGELOG.md`.

Most changes touch one or two. A change that touches none is either internal
refactoring or a feature nobody will discover.

Two rules with teeth, because prose alone has not held:

- **A new control-plane verb is three edits, not one.** `standardVerbs` + REST
  route + MCP tool, together — `testEveryStandardVerbHasATool` fails otherwise —
  and the `API.md` and `INTEGRATIONS.md` tables in the same commit. The tables
  are how an agent learns the verb exists; shipping the verb without them ships
  it invisibly.
- **A new capability is documented where it is registered.** Capabilities are
  declared, not coded, so the `CapabilityDescriptor`'s `help` string *is* its
  documentation for the user who sees the settings pane. Write it as a sentence
  someone would want to read, then list the capability in `guides/DEMO.md`.

## Where the docs are published

`docs/` in the repository is the source of truth. The GitHub wiki is a mirror,
pushed by `.github/workflows/docs.yml` on every merge to `main`: directory paths
are flattened into wiki page names (`docs/concepts/QUEUE.md` becomes
`Concepts-Queue`) and relative links are rewritten to match. Do not edit the wiki
directly — the next merge overwrites it.

Symbol-level API reference is generated from `///` comments by DocC and published
to GitHub Pages by the same workflow. That is why member-level doc comments are
worth writing even for self-evident types: they are the only documentation that
cannot drift, because it lives in the file it describes.
