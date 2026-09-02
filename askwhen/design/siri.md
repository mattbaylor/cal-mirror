# Siri, and what the iOS surface actually is

Researched 2 September 2026, off Apple's own documentation and its WWDC26
session. `mcp.md` claimed App Intents was the only shape iOS offers, reasoned
from the absence of subprocesses rather than from anything Apple published. That
guess holds up, and the picture is better than it assumed.

---

## First, two things doing the rounds that Apple does not say

Search results confidently report that **SiriKit was deprecated at WWDC26 on 9
June and App Intents 2.0 added multi-turn conversation, streaming responses and a
View Annotations API.** Those claims come from third-party blogs.

Apple's own WWDC26 session on this exact topic — *Build intelligent Siri
experiences with App Schemas* — **says none of it.** No deprecation, no
"App Intents 2.0", no multi-turn or streaming. View Annotations are covered, but
as an existing capability rather than a new one.

Marked here rather than dropped, per the technique in `competitors.md`: name the
claim, do not adopt it. If multi-turn conversational follow-up is real it matters
a great deal to the agent surface, and it should be confirmed from a release note
or the API itself before anything is designed around it.

---

## What Apple does say

Siri gains three things through App Intents:

1. **Access to app entities** — it can query your content. *"When and where is my
   next meeting?"*
2. **Action execution** — it can invoke your intents. *"Send my latest report to
   Mary."*
3. **On-screen context** — it understands what is visible and can be pointed at
   it.

Two tiers, and the distinction is the whole planning question:

- **App Intents** expose actions to Shortcuts, Spotlight and Widgets.
- **App Schemas** are App Intents shaped to *system-defined* schemas, which is
  what lets Siri handle them through natural language without the app defining
  phrases. Grouped into **domains**.

Entities can conform to `IndexedEntity`, which contributes them to the Spotlight
semantic index and enables semantic search and Q&A over the content, with
attribution back to the app. Where indexing is impractical, `EntityStringQuery`
does string matching instead.

Xcode surfaces missing related schemas at build time — adopt `sendMessage` and it
reminds you about `draftMessage`. And there is an **`AppIntentsTesting`**
framework for the logic, with Shortcuts, Spotlight and Siri as progressively more
end-to-end checks.

Apple's session names no platform limits; the framework spans iOS, iPadOS,
macOS, watchOS and visionOS.

## There is a Calendar domain

Read off Apple's *App schema domains* collection. Primary domains — the ones that
reach Apple Intelligence and Siri:

**Audio · Calendar · Camera · Clock · Files · Mail · Maps · Messages · Notes ·
Phone · Photos · Reminders · System and in-app search**

Then single-purpose domains that integrate a specific surface outside Siri
(Assistant, Visual intelligence), and Shortcuts-only domains (Books and others)
whose schemas work in Shortcuts but are **not** discoverable by Siri.

**Calendar is a primary domain**, which is better than `mcp.md` assumed. The
exact schemas in it are worth reading in Xcode rather than in a browser, since
Xcode is what tells you which ones you are missing.

---

## What this means for us

**The two surfaces serve different consumers and we want both.**

| | Consumer | Transport | Where |
|---|---|---|---|
| **MCP** | Claude, ChatGPT, Codex | stdio subprocess | macOS |
| **App Intents / Schemas** | Siri and Apple Intelligence | system framework | iOS, iPadOS, macOS |

These are not competing answers to one question. Siri will not speak MCP, and
Claude Code will not invoke an App Intent. On macOS we can have both, and they
should share one implementation underneath — which argues for the tool logic
living in `CalMirrorKit` with two thin adapters, exactly as the engine already
does.

**The likely split of our own surface:**

- **Calendar-shaped actions** — publish, what is offered, accept or decline a
  request — are candidates for Calendar-domain schemas, and get Siri's natural
  language free.
- **Configuration and diagnosis** — *"why is nothing showing on Thursday?"* — fit
  no domain. There is no settings or configuration domain, so these stay custom
  App Intents: available in Shortcuts and Spotlight, but without schema-level
  Siri understanding.

That second bullet is the one to check rather than believe. `System and in-app
search` may cover more of the Q&A shape than its name suggests, and *"why is
nothing showing on Thursday?"* is closer to a search-and-answer than to a
setting.

**And the diagnosis work is shared regardless.** Both surfaces need
`SlotDeriver` to record *why* a candidate was dropped, and neither needs it to
record *what* dropped it. That note is already carried forward on step 1 and it
does not depend on which surface wins.

---

## What I would check next, in order

1. **The Calendar domain's actual schema list**, in Xcode. It decides how much of
   our surface gets natural language for free.
2. **Whether `IndexedEntity` fits an offered slot.** If slots can be indexed,
   *"when can I see Matt?"* becomes a Siri query rather than an app launch — and
   that is a different product, not a nicer one.
3. **The multi-turn claim**, from a primary source. It is the difference between
   an assistant that configures the tool and one that runs single commands.
4. **Whether App Intents on macOS is a serious surface or a checkbox.** If it is
   real, MCP becomes the developer path and App Intents the everyone-else path,
   which changes who each is built for.
