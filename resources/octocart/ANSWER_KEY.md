# OctoCart Copilot Code Review answer key

> **Presenters only.** This file lives in `repo-setup-scripts` and is never copied into
> demo repos (only the `pr-*/` directories are overlaid). Don't show it on screen.

`create-repo` opens four PRs against the OctoCart baseline. It requests Copilot Code Review on
the first three and leaves PR 4 for you to request live. All four PRs pass lint, typecheck, tests, and build, so every issue below is
something CI cannot catch. Line numbers refer to the file **after** the PR is applied.

CCR is non-deterministic. Expect it to catch most, not all, of these issues, and sometimes
to raise valid points that aren't listed here.

House rules are defined in `.github/copilot-instructions.md` (the **repo** column) and
`.github/instructions/{api,web-components,tests}.instructions.md`.

## PR 1: "Support stacking promo codes and sale pricing" (`feature/stackable-promo-codes`)

Theme: **subtle correctness bugs** in otherwise clean code.

| # | File:line | Category | What's wrong |
|---|-----------|----------|--------------|
| 1 | `api/src/lib/pricing.ts:65` | Bug (boundary) | `>` should be `>=`. A cart totaling exactly $50.00 is charged $5.99 shipping, even though the threshold means "$50 or more ships free". |
| 2 | `api/src/lib/pricing.ts:13` | Bug (float money) | `Math.floor(price * (1 - pct/100))` uses float math. With socks at 30% off, `1400 * 0.7 = 979.9999…` floors to **$9.79** instead of $9.80. Use `percentOf`/`subtract` from `money.ts` (house rule: money math only via the helpers). |
| 3 | `web/src/components/ProductCard.tsx:13` | Bug + house rule (web) | The UI computes the sale price itself with `Math.round`, so it shows $9.80 while the API charges $9.79. The UI must not compute prices; the API should return `salePrice`. |
| 4 | `api/src/lib/pricing.ts:51` | Bug / abuse | Codes aren't deduplicated or capped. `OCTO10,OCTO10,…` stacks indefinitely, and once the total exceeds 100%, `percentOf` throws a RangeError, which surfaces as a **500** instead of a 400. |
| 5 | `api/src/schemas.ts:44` | Validation (house rule: api) | The `.max(32)` limit on `promoCode` was removed, so input is now unbounded. |
| 6 | `api/src/routes/orders.ts:40` | Bug (async) | `items.forEach(async …)` runs stock decrements fire-and-forget. Errors are lost, and the order is saved before stock is updated. Use `for…of` with `await`. |
| 7 | `api/src/routes/orders.ts:50` | Bug (async) | `store.saveCart(userId, [])` has no `await`, so a failure is an unhandled rejection after the response has been sent. |
| 8 | `api/test/pricing.test.ts` | Tests (house rule: tests) | Only happy paths are covered. Nothing tests the $50.00 boundary, duplicate codes, the over-100% case, or an error path. |

Good demo moment: ask Copilot Chat on the PR, "What does a $50.00 cart pay for shipping?"

## PR 2: "Add order history page with CSV export" (`feature/order-history-export`)

Theme: **security, performance, and robustness**.

| # | File:line | Category | What's wrong |
|---|-----------|----------|--------------|
| 1 | `api/src/routes/orders.ts:80` | Security (IDOR) | `?userId=` lets **any** signed-in user export **any** customer's orders. There's no staff or role check (house rule: scope data to the current user). |
| 2 | `api/src/middleware/requireAuth.ts:21` + `web/src/api/client.ts:71` | Security | Session token accepted in the query string (`?access_token=`), so it leaks into browser history, server logs, and `Referer` headers. It also changes auth for **every** route, not just the export. |
| 3 | `api/src/routes/orders.ts:98` (and `line.name`) | Security (CSV injection) | Fields aren't quoted or escaped. A ship-to name containing `,` or `"` breaks the columns, and one starting with `=`, `+`, `-`, or `@` executes as a formula in Excel. |
| 4 | `api/src/routes/orders.ts:86` | Performance (N+1) | `await store.getProduct()` runs once per order line inside nested loops. Batch the lookup or reuse `line.name`. |
| 5 | `api/src/routes/orders.ts:78` | Robustness (house rule: api) | Raw `async` handler without `asyncHandler`. In Express 4, the `throw new NotFoundError` on line 87 becomes an unhandled rejection and the request hangs. |
| 6 | `api/src/routes/orders.ts:59-60` | Validation / perf (house rule: api) | `limit`/`offset` aren't validated with zod. `?limit=abc` gives `NaN` (empty page), negatives behave oddly, and there's no max page size. The CSV export also has no limit. |
| 7 | `api/src/routes/orders.ts:95-97` | Money (house rule: repo) | `(cents / 100).toFixed(2)` instead of the money helpers. |
| 8 | `web/src/components/OrderHistory.tsx:16` | UX / error handling (house rule: web) | `.catch(() => setOrders([]))` silently hides load failures as "no orders". There's no `role="alert"` error state. |
| 9 | `api/test/orders.test.ts` | Tests (house rule: tests) | One happy-path export test. There are no error-path or authorization tests, and nothing tests pagination. |
| bonus | `web/src/components/OrderHistory.tsx:11-17` | Bug (stale UI) | History only reloads when the token changes, so an order placed in the same session doesn't appear. CCR found this in testing. |

## PR 3: "Add a wishlist" (`feature/wishlist`), the custom-instructions showcase

Theme: the code **works**, but it breaks almost every rule in the repo's Copilot
instructions. Show `.github/copilot-instructions.md` first, then the review comments that cite it.

| # | File:line | House rule broken | What's wrong |
|---|-----------|-------------------|--------------|
| 1 | `api/src/routes/wishlist.ts:29` | api: validate all input with zod `validate()` | `req.body.productId` and `note` aren't validated. `note` is unbounded, and `:productId` params aren't validated either. |
| 2 | `api/src/routes/wishlist.ts:10, 28, 43, 48` | api: wrap async handlers in `asyncHandler` | All four handlers are raw `async`, so rejections escape Express 4. |
| 3 | `api/src/routes/wishlist.ts:24, 32` | api: throw `HttpError`s, never `res.status(...)` | Ad hoc 500 and 404 responses with the **wrong error shape** (`{message}` and `{error: string}` instead of `{error:{code,message}}`). The try/catch also swallows real errors. |
| 4 | `api/src/routes/wishlist.ts:19, 22` | repo: integer cents via `Money` helpers; no `parseFloat`/`toFixed` | The total is computed as float dollars and returned as a **string**. It should be `sum()` in cents. |
| 5 | `api/src/routes/wishlist.ts:40, 45, 53` | api: 201 for create, 204 for delete, named response keys | Returns `200 {ok:true}` everywhere. |
| 6 | `api/src/routes/wishlist.ts:51` | Bug (business rules) | Move to cart appends a duplicate line instead of merging, skipping the `MAX_QUANTITY` and stock checks that `cart.ts` enforces. It also doesn't 404 for products that aren't in the wishlist. |
| 7 | `web/src/components/Wishlist.tsx:23, 36` and `ProductList.tsx:20` | web: network calls only via `web/src/api/client.ts` | Direct `fetch` calls that bypass `ApiError` handling. Failed POSTs and DELETEs are ignored. |
| 8 | `web/src/components/Wishlist.tsx:57` | web: never compute or format money in the UI; use `formatMoney` | `(price / 100).toFixed(2)`. |
| 9 | `web/src/components/ProductCard.tsx:23-27` | web: semantic `<button>`; accessible name includes the product | `div role="button"` handles Enter but not Space, has no `aria-pressed`, and its name is just "♡" (or a title). |
| 10 | `web/src/components/Wishlist.tsx:60` | web: every input needs a label | Placeholder-only note input. |
| 11 | `web/src/components/Wishlist.tsx:73` | web: buttons name the product | "✕" and "Move to cart" don't say which product they act on. |
| 12 | `web/src/components/Wishlist.tsx:47, 49` | web: sections use `aria-labelledby`; errors use `role="alert"` | Neither is present. |
| 13 | (no test files) | tests: every route has tests, including an error path | No API or component tests at all. |
| bonus | `api/src/data/store.ts` (`saveToWishlist`) | Bug | Clicking the heart on an already-saved product sends no note, which wipes the existing note and resets `addedAt`. CCR found this in testing. |

## PR 4: "Add product reviews" (`feature/product-reviews`), the live review

Theme: **security and house rules in a small diff.** `create-repo` does **not** request a review
on this PR. Request it live: on github.com use **Reviewers → Copilot**; in the Copilot app, open
the PR session and ask for a review. In testing, the review took about 7 minutes to land, so have something to talk through while it runs.

| # | File:line | Category | What's wrong |
|---|-----------|----------|--------------|
| 1 | `web/src/components/ProductReviews.tsx:37` | Security (stored XSS) | `dangerouslySetInnerHTML={{ __html: review.body }}` renders unsanitized user input. A review like `<img src=x onerror=alert(1)>` runs script for every shopper who opens that product's reviews. The PR body even advertises "simple formatting like `<b>`". |
| 2 | `api/src/routes/reviews.ts:35, 43` | Security (house rule: api) | `POST` has no `requireAuth`, and `author` comes from the request body. Anyone can post anonymously as "OctoCart Staff" or as another customer. The author should be `currentUser(req).name`. |
| 3 | `api/src/routes/reviews.ts:43` | Validation (house rule: api) | `req.body` and `req.params` are read without zod `validate()`. `rating` can be `500`, `-3`, `2.5`, or `"5"`: a string turns the `reduce` into string concatenation, `500` swamps the average, and a negative rating makes `'★'.repeat()` throw a RangeError that crashes the UI (`ProductReviews.tsx:36`). `body` has no length limit. |
| 4 | `api/src/routes/reviews.ts:18, 22, 35, 39` | Errors (house rule: api) | Raw `async` handlers without `asyncHandler`, and ad hoc `res.status(404).json({ message })` instead of throwing `NotFoundError`. The error shape isn't `{ error: { code, message } }`. |
| 5 | `api/src/routes/reviews.ts:30` | Bug | A product with no reviews divides `0 / 0`: `average` is `NaN` and serializes as `null`, though the client type says `number`. |
| 6 | `api/src/routes/reviews.ts:14` | Bug / tests | Reviews live in a module-level array instead of the store, so `resetStore()` doesn't clear them. The second test only passes (`count` 2, `average` 4.5) because the first test's review **leaked** into it. |
| 7 | `web/src/components/ProductCard.tsx:31` + `ProductReviews.tsx:16` | Performance | Every product card fetches its reviews on mount, so the product list fires one request per product (N+1), even though the reviews are collapsed by default. Fetch on expand, or include a summary in `/api/products`. |
| 8 | `api/test/reviews.test.ts`, no `ProductReviews.test.tsx` | Tests (house rule: tests) | Happy paths only: nothing tests auth, validation, unknown products, or the empty-reviews case. The new component has no test. |

## Presenter tips

- Open the **PR list** (the script opens it for you) and start with PR 3. It's the most visual
  showcase of custom instructions. Then use PR 1 for the "it even catches a one-character bug" moment.
- If CCR hasn't finished, refresh. In testing, reviews landed in about 3-6 minutes, and
  the larger wishlist PR took the longest. Create the demo a few minutes before you need it.
- Save PR 4 for the live moment: request the review while the audience watches, walk through the
  finished reviews on PRs 1–3 while it runs, then come back to the XSS and validation findings.
- To re-run a review, use **Reviewers ➜ Re-request review** on Copilot.
- The baseline repo also contains `.github/instructions/*.instructions.md` files scoped by
  `applyTo` globs. Point out that the web rules fire only on `web/**` files.
