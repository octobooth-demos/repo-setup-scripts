# GitHub Copilot Fusion routing answer key

> **Presenters only.** This file lives in `repo-setup-scripts` and is never copied into
> demo repos. Don't show it on screen.

`create-repo` creates an OctoCart repo (`fusion-routing-xxxx`) in the signed-in booth account
(`octobooth-1`, `octobooth-2`, …) from the public `octobooth-demos/octocart` template: a small
Express + React merch store with vitest tests, without the Code Review demo's PRs.
You then run **three** prompts, each in its own GitHub Copilot Fusion autopilot session, and compare
how Fusion handled each one. The story: *you pick one model, and it decides how much horsepower
each task needs.*

## The three prompts

All three are in this folder. The Demo Launcher shows each with **📋 Copy** and **▶ Run with Fusion**.

| Label | File | Sized for | What it asks |
|-------|------|-----------|--------------|
| **Single** | [`single.txt`](single.txt) | Single | A one-line README note (Node.js 22 or later) |
| **Cascade** | [`cascade.txt`](cascade.txt) | Cascade | Tests (and a fix) so the orders API returns a generic 500 when the data store fails, without leaking details or changing stock/cart |
| **Critique** | [`critique.txt`](critique.txt) | Critique | A design proposal for order tracking that compares three data models and recommends one (no code) |

> Single: In the README's Quick start section, add a one-line note that OctoCart needs Node.js 22 or later (it's the "engines" requirement in package.json).

> Cascade: Make the orders API fail safely when the data store is unavailable. Add tests to api/test/orders.test.ts that make store methods (for example store.createOrder, store.listOrders, and store.getOrder) reject with a database-style error such as "connection to db-primary:5432 lost". Every orders endpoint must then respond 500 with the generic internal_error body, without leaking the underlying error message or stack, and a failed checkout must not change product stock or empty the user's cart. Use the existing vitest + supertest patterns in api/test, fix the code if a test fails, and make sure npm test passes.

> Critique: Write docs/design/order-tracking.md: a design proposal for order tracking in OctoCart. Compare a status field, an event log, and statuses derived from timestamps; reason through correctness, race conditions, testability, and a future move to a real database for each; recommend one and justify the tradeoffs, then spell out the API, UI, test plan with corner cases, and open questions. No code changes.

**Why the Cascade prompt has teeth:** `POST /api/orders` decrements stock *before* it saves the
order, so if `store.createOrder` fails, stock is already gone. The "must not change product stock"
test fails on the template as-is, so Fusion has to find and fix a real bug, not just add tests.
That's the kind of task where a cheap first draft often works but a quality gate earns its keep.

**Why Critique is a design doc, not a feature build:** in our testing (policy
`hydrafusion_v3_2026-10-27`), Fusion's router scores each prompt for reasoning, code generation,
debugging, and tool use. Critique went to prompts with **high reasoning and little code**
(comparing designs, weighing tradeoffs, recommending one). Every code-writing prompt above
"trivial" went to Cascade, including a full order tracking build, a promotions engine, a
SQLite migration, and a bug hunt. A design doc is also where a second opinion from a different
model family pays off most, which is a good story: "for judgment calls, it gets a reviewer."

## These are not guaranteed

Fusion picks the pattern **per request, dynamically**. These prompts are sized to land on Single,
Cascade, and Critique, and did in our dry run (see below; the routing scores were identical on
every re-run of the same prompt), but routing policy changes server-side, so a prompt can get a
different pattern after an update. Say so up front; it's a feature: "it decided this one was easy."
If a prompt lands on a different pattern, talk about why it might have (task looked simpler or
harder than expected) rather than re-running it live.

## Running it

**Fastest: Demo Launcher.** After the run finishes, click **▶ Run with Fusion** on each of the three
prompts. Each opens a new autopilot session with the GitHub Copilot Fusion model, named
`[Fusion - Single] …`, `[Fusion - Cascade] …`, and `[Fusion - Critique] …`, so they line up in the
session list. All three run in parallel in their own worktrees. Start Critique first: it takes longest.
If you opened the launcher from the canvas picker (no chat), each button copies its prompt and opens
the repo's new-session composer instead; pick **Auto → GitHub Copilot Fusion** and **Autopilot**, then paste.

**By hand (Copilot CLI):** in the clone, `copilot`, pick the GitHub Copilot Fusion (HydraFusion in
some builds) model with `/model`, switch to autopilot (<kbd>Shift</kbd>+<kbd>Tab</kbd>), and paste one
prompt. Use a separate clone or worktree per prompt so the runs don't step on each other.

## Seeing which pattern it used

- **In the session:** Fusion announces the plan up front, for example *"Using Cascade: a solver will work
  on your request, followed by a review pass and fixes if needed."* or *"Using Critique: a solver will draft a
  result, a critic will review it, and the original solver will revise it if needed."* Single has one
  solver phase; Cascade has a solver, a judge, and (only if the judge rejects) a repair by a stronger
  model; Critique has a draft, a **read-only critic** from a different model family, and a revision.
- **After the fact (CLI):** each session's `~/.copilot/session-state/<session-id>/events.jsonl` records it:
  `grep '"type":"session.fusion_resolved"' events.jsonl | grep -o '"pattern":"[a-z]*"\|"ruleId":"[^"]*"\|"scores":{[^}]*}'`
  shows the pattern, the routing rule, and the prompt's scores; `assistant.fusion_phase_completed` events
  show each phase's model, duration, and the judge's verdict.

## What to expect (dry run)

All three run in parallel on a fresh clone with GitHub Copilot Fusion in autopilot (Copilot CLI, November 2026):

| Prompt | Pattern | How it played out | Time | AI credits | Result |
|--------|---------|-------------------|------|------------|--------|
| Single | **single** | GPT-6 Luna solved it directly | ~45 s | 0.3 | README +2 lines |
| Cascade | **cascade** | GPT-6.1 Sol drafted the tests and the fix; the GPT-6 Luna judge **rejected** it (no proof that `npm test` passed); Claude Opus 5.5 repaired and verified | ~2.5 min | 31 | store-failure tests for all three orders endpoints + a stock/cart fix in `orders.ts`; `npm test` 87/87 |
| Critique | **critique** | Claude Opus 5.5 drafted; a GPT-6 Luna critic reviewed it read-only; Opus revised | ~5.5 min | 84 | ~590-line `docs/design/order-tracking.md`; no code changed, `npm test` still passes |

The Cascade run is the best moment to narrate: show the judge's rejection and the escalation to a
stronger model. The cost column makes the routing point on its own.

## Follow-up: build it

After the Critique session, a great live follow-up is to have Fusion *implement* the design. This one
routed to **Cascade** in our testing (about 8 minutes, 1,100+ lines across API and React, `npm test`
131/131, lint and typecheck clean):

> Plan and implement order tracking for OctoCart. Give orders a status lifecycle: placed, packed, shipped, out for delivery, delivered, or cancelled. For the demo, status advances with time since the order was placed (about one step per minute), using an injectable clock so it can be tested. Add GET /api/orders/:id/tracking, which returns the current status, a timeline with a timestamp for each reached step, and an estimated delivery date, and POST /api/orders/:id/cancel, which only works before the order ships. In the web app, add a "Your orders" view for signed-in users and an order tracking page with an accessible progress stepper, the order lines and totals, and a Cancel order button when cancelling is allowed. Follow the house rules in .github/copilot-instructions.md. Make sure all routes and components are tested and corner cases are handled, including other users' orders, unknown and invalid ids, cancelling a shipped or already-cancelled order, and an empty order history. Make sure npm test, npm run lint, and npm run typecheck pass.

Then show the tracking page (`npm run dev`, sign in as `mona@octocart.dev` / `octocat123`, place an
order, open **Your orders**, and watch the stepper advance about once a minute).

## Talking points

**One model choice, three different workflows.** Fusion picks the least complex workflow that's
likely to meet the quality bar:

| Pattern | What happens | What to point at |
|---------|--------------|------------------|
| **Single** | One selected model solves the task directly. | Docs tweak: done in under a minute, cheapest run. Why pay for a review on a one-liner? |
| **Cascade** | An efficient model drafts; a quality gate accepts it or escalates to a stronger model. | Failure-path tests: the gate checks the draft before you ever see it. |
| **Critique** | One model drafts; an independent, **read-only** critic from a *different model family* reviews it (the Rubber Duck pattern); the drafter revises once. | Design proposal: a judgment call where a second opinion catches gaps a solo pass misses. |

**Compare cost and time.** The three sessions' AI credits and durations make the point on their own:
the small task stayed small, the risky code change got a quality gate, and the judgment call got a reviewer.

**Why it's safe to hand it a repo.** Critics run in isolated, tool-less contexts (they can't edit your
code); every leg has timeouts and cost accounting; if a workflow is cancelled or fails validation,
no patch is applied. You get one coherent answer and one change set.

**Benchmarks and background.** See the [blank-prompt presenter notes](../fusion-blank/ANSWER_KEY.md#talking-points)
for the benchmark table and sound bite ("frontier quality, about Opus 5 or better, at 36-67% lower cost").

Source: [Project HydraFusion: frontier quality via multi-model orchestration](https://github.blog/ai-and-ml/github-copilot/project-hydrafusion-frontier-quality-via-multi-model-orchestration/).
Feedback goes to `/feedback` in Copilot CLI or the [community discussion](https://github.com/orgs/community/discussions/206492).

If a run stalls or fails, delete the repo (launcher **Clean up** section) and create a fresh one.
