# Final answers from the 48 native plugin runs

These are reviews of synthetic fixtures. Paths are redacted as described in README.md.

## plugin-confirmation / case-101-with-1

[Trace](plugin-confirmation/traces/case-101-with-1.jsonl)

## Recommendation: request changes. Don't merge.

`reserve` oversells stock in the documented deployment, and the probe shows it happening.

**Probe result** (`node probe.mjs`):
```
{"accepted":[true,true],"remaining":0}
```
There was 1 unit in stock and two concurrent reservations were both accepted. Since each successful reservation ships one item (`DEPLOYMENT.md:1`), two items would ship against one unit.

## Findings

**Critical: the stock check and the decrement can interleave (lost update).** At `stock.js:2-4`, the function reads with `await db.get`, checks `available`, then writes with `await db.set`. Each store operation is atomic (`DEPLOYMENT.md:1`), but the read-check-write sequence as a whole is not. Having one JS worker and one dispatcher (`DEPLOYMENT.md:1-2`) doesn't help, because `dispatcher.js:2` doesn't queue calls. Each `await` gives up control, so a second request can read `available: 1` before the first one writes. Separately, the write sets an absolute value (`row.available - 1`) based on a possibly stale read, so concurrent decrements overwrite each other rather than adding up.

To fix it, the check and the decrement need to happen as one atomic step. Two options:
- Use an atomic conditional decrement or compare-and-set in the store, if it has one. The `store.js` in the repo only offers `get`/`set`/`value`.
- If the store can't do that, serialize `reserve` per SKU inside the single worker, for example by chaining calls on a per-SKU promise. The deployment invariants (one worker, one dispatcher, no other writers) make in-process serialization enough here.

Either way, add a regression test that asserts `[true, false]` and `remaining: 0`, which is what `probe.mjs` already checks for informally.

**Readability, security, performance:** nothing material to flag for this function. The fix above makes it a little longer; that's expected.

## Evidence I need from you

1. **The production store.** Is `store.js` the real implementation or a test stand-in? Does the real store offer an atomic conditional update? That decides which fix to use.
2. **Unknown SKUs.** What does `db.get` return for a SKU that doesn't exist? With the fixture store, `reserve` would throw a TypeError on `row.available` if `get` returned `undefined`. Whether that's a bug depends on the store's contract, which isn't documented.
3. **Tests and CI.** The repo has no tests and no test script, so I can't confirm any verification beyond the probe.

I didn't modify any files or install any packages.

## plugin-confirmation / case-101-with-2

[Trace](plugin-confirmation/traces/case-101-with-2.jsonl)

## Merge recommendation: **Request changes. Don't merge yet.**

The probe shows `reserve` overselling under the documented deployment.

## Observed result

```
$ node probe.mjs
{"accepted":[true,true],"remaining":0}
```

There was 1 unit in stock and two concurrent requests. **Both were accepted, so two items ship**, but stock only went down by one.

## Findings

**Critical: read-then-write race lets stock oversell** (`stock.js:2-4`)

`reserve` reads the stock with `db.get`, checks it, then writes it back with `db.set`. Each store call is atomic on its own (`DEPLOYMENT.md`), but the read-check-write as a whole is not. Having one JavaScript worker doesn't prevent this. Each `await` hands control back to the event loop, so a second `reserve` on the same instance (`dispatcher.js:2`) can read the same `available: 1` before the first one writes. Both requests pass the `< 1` check and both write `0`.

Under the deployment contract this breaks "each successful reservation ships one item": the service promises more items than it has. It's also a lost update, because the second write is based on a stale read.

Required fix (pick one):
- **Serialize reservations per SKU inside the worker.** For example, keep a `Map<sku, Promise>` lock in `reserve`, or in the single dispatcher, and chain each call onto the previous one. This is valid because the deployment guarantees one worker, one dispatcher instance and no other writers.
- **Use an atomic conditional decrement in the store**, such as compare-and-set or "decrement if ≥ 1". The store API in `store.js` doesn't provide one today.

Add a regression test like `probe.mjs` that requires `accepted` to contain exactly one `true` and `remaining` to be `0`.

**Other axes:** Readability is fine. I found nothing else to flag for security. For performance, per-SKU serialization only queues requests for the same SKU, which is an acceptable cost.

## Missing evidence

- **Production store:** Is `store.js` the real store or a stand-in? If the production store already offers an atomic conditional update, that changes which fix is best.
- **Unknown SKU:** What should happen when a SKU doesn't exist? `row.available` throws a TypeError if `get` returns nothing. `store.js` always returns a row, so the repository doesn't show this case.
- **Tests:** The repository has no tests other than the probe. Please confirm whether there is a test suite or CI run for this change.

## plugin-confirmation / case-101-with-3

[Trace](plugin-confirmation/traces/case-101-with-3.jsonl)

## Merge recommendation: **request changes (blocking)**

`reserve` in `stock.js` oversells under concurrent requests, even with the deployment rules in `DEPLOYMENT.md`. The probe shows it happening.

### Probe result
```
$ node probe.mjs
{"accepted":[true,true],"remaining":0}
```
There was 1 unit in stock and both calls returned `true`. `DEPLOYMENT.md` says "each successful reservation ships one item", so this ships **2 items against 1 in stock**. The stored count also ends at `0` instead of `-1`, so one decrement is silently lost and nothing records the oversell.

### Findings

**Critical: race between reading and writing stock (`stock.js:2-4`)**
- The function reads stock, checks it, then writes the new value, with an `await` between the read and the write. The deployment has only one worker and one dispatcher (`DEPLOYMENT.md`, `dispatcher.js:2`), but that only rules out parallel threads. One event loop still runs other async calls during each `await`. Both calls read `available: 1` before either writes, and both pass the `< 1` check.
- "Individual store operations are atomic" doesn't help, because the check and the write are two separate operations.
- **Fix:** make the check and the decrement one atomic step. Two options:
  1. If the real store has a conditional decrement or compare-and-set, use it.
  2. Otherwise, queue calls in process so each `reserve` for a SKU finishes before the next starts (a per-SKU lock or promise chain). This is safe only because `DEPLOYMENT.md` guarantees one worker, one dispatcher and no other writers. Note that dependency in the code.
- Add `probe.mjs`'s scenario as a regression test that expects `accepted: [true, false]` and `remaining: 0`.

**Readability:** nothing material. The function is short and clear.

**Performance:** nothing material. It does one read and at most one write per call. A per-SKU lock would only queue calls for the same SKU.

**Security:** no issues within this function. The repo doesn't say where `sku` comes from or what authorization runs before `reserve`, so I haven't assessed that.

### Evidence I need
1. **The production store's API.** Does it offer an atomic conditional decrement or compare-and-set? That decides between fix options 1 and 2. `store.js` looks like a test stub, so I can't tell from it.
2. **Unknown SKUs.** What does the real `db.get` return for a SKU it doesn't have? If it returns `undefined`, `row.available` on line 3 throws instead of returning `false`. The stub always returns a row, so the repo doesn't settle this.

I didn't modify any files or install anything.

## plugin-confirmation / case-101-without-1

[Trace](plugin-confirmation/traces/case-101-without-1.jsonl)

**Merge recommendation: Do not merge.** `reserve` oversells under concurrent requests, even in the documented single-worker deployment. (The `code-review-and-quality` skill isn't installed in this session, so I did the review by hand.)

**Observed result.** `node probe.mjs` printed:
```
{"accepted":[true,true],"remaining":0}
```
There was one unit in stock and two reservations were accepted. Per `DEPLOYMENT.md`, each successful reservation ships one item, so two items would ship against one unit.

### Material findings

**1. Correctness, blocking: check-then-act race causes overselling (`stock.js:2-4`)**
`reserve` reads the row, checks `available`, and writes `available - 1` as two separate store operations with an `await` between them. `DEPLOYMENT.md` says only that *individual* store operations are atomic, not the read-check-write sequence. One JS worker doesn't prevent this: the event loop interleaves requests at each `await`. Both calls read `available: 1`, both pass the check, and both write `0`. The probe confirms it, so this is a real failure, not a theoretical one.

Possible fixes (pick one):
- Serialise `reserve` per SKU inside the module, for example by chaining each call onto a per-SKU promise. This holds only because `DEPLOYMENT.md` guarantees a single worker, a single dispatcher instance, and no other writers. If those guarantees change, the fix stops working.
- Better, if the real store supports it: a single atomic conditional decrement or compare-and-set, so the check and the write happen in one store operation.

Add a regression test that matches `probe.mjs`: two concurrent calls on stock of 1 should give `[true,false]` and leave `remaining: 0`.

**2. Correctness, needs evidence: unknown SKU (`stock.js:2-3`)**
If `db.get` returns `null` or `undefined` for a SKU that doesn't exist, `row.available` throws a TypeError instead of returning `false`. The stub in `store.js` always returns a row, so the real behaviour can't be determined from the repo.

**Security / performance / readability:** I found no material issues. The function is small and clear, and its only real defect is finding 1.

### Evidence needed
- The production store's API: does it offer an atomic conditional update or compare-and-set? That decides which fix to use.
- What the production `get` returns for a missing SKU.
- Whether the `reserve` contract requires `false` or a thrown error when stock is unavailable or the SKU is unknown. No API documentation for this is in the repo.

## plugin-confirmation / case-101-without-2

[Trace](plugin-confirmation/traces/case-101-without-2.jsonl)

## Recommendation: do not merge

`node probe.mjs` output:
```
{"accepted":[true,true],"remaining":0}
```
There was one unit of stock, but two reservations were accepted. Under the deployment rules in `DEPLOYMENT.md`, each successful reservation ships one item, so this ships two items when only one exists.

## Material findings

**1. Correctness, high: concurrent reservations oversell (`stock.js:2-4`)**
`reserve` reads stock, checks it, then writes it back, with an `await` at each step. Each store call is atomic on its own (`DEPLOYMENT.md:1`), but the read-check-write sequence as a whole is not. Having a single worker and a single dispatcher (`DEPLOYMENT.md:2`, `dispatcher.js:2`) doesn't prevent this. Both calls run on the same event loop, so both `get`s finish before either `set`, both see `available: 1`, and both return `true`. The second `set` also overwrites the first with the same value, so the stock count ends at 0 instead of catching the second sale.

Suggested fix: make the check and the decrement happen as one step. Since the deployment guarantees one process and one dispatcher, a per-SKU in-process lock (a promise chain keyed by `sku`) around the body of `reserve` would work. A conditional or atomic decrement in the store would also work, but `store.js` doesn't provide one. Re-run `probe.mjs` afterwards and expect `{"accepted":[true,false],"remaining":0}`.

**Security:** The oversell above is the only material risk. Anyone who can send two requests at the same time can get more items than exist. I found no other security problems in this function.

**Performance and readability:** No material issues. Note that a per-SKU lock will make reservations for the same SKU run one at a time.

## Missing evidence I need from you
- **Is `store.js` what production uses?** If production uses a different store, I need its `get`/`set` behaviour and whether it has an atomic conditional update.
- **What does `db.get` return for an unknown SKU?** If it can return `undefined` or `null`, then `row.available` at `stock.js:3` will crash. I can't tell from the repo whether that can happen.
- **Are there tests for `reserve`?** None are in the repo, especially for concurrent calls on the same SKU.

## plugin-confirmation / case-101-without-3

[Trace](plugin-confirmation/traces/case-101-without-3.jsonl)

**Recommendation: don't merge.** `reserve` oversells under concurrent requests. That happens in the documented deployment, and the probe shows it.

**What the probe showed**

```
node probe.mjs → {"accepted":[true,true],"remaining":0}
```

The store started with 1 unit. Two concurrent `reserve('sku')` calls both returned `true`. Under `DEPLOYMENT.md` ("Each successful reservation ships one item"), that means 2 items ship against 1 in stock.

**Material finding**

1. **Correctness: lost update / oversell. `stock.js:2-4`, high severity.**
   `reserve` reads the stock with `await db.get`, checks it, then writes it with `await db.set`. It yields at each `await`, so a second request can read `available: 1` before the first request's `set` lands. Both pass the `< 1` check and both write `0`.
   - `DEPLOYMENT.md` doesn't prevent this. "One JavaScript worker" rules out parallel threads, but async calls still interleave on that worker.
   - "Individual store operations are atomic" only covers each `get` or `set` alone, not the read-check-write sequence.
   - The "single dispatcher instance" (`dispatcher.js:2`) adds no serialization; it forwards straight to `reserve`.
   - The final count of `0` looks right, which hides that one unit was sold twice.

   The fix needs `reserve` to make the check and the decrement one step. Either run calls for the same SKU one at a time inside the process, or use an atomic conditional decrement in the store if one exists.

**Other dimensions**
- **Security:** nothing material beyond the oversell, which an attacker could also trigger on purpose by firing parallel requests.
- **Performance:** two store round-trips per call, which is fine. A per-SKU serialization fix would add a little waiting time per request but would be correct.
- **Readability:** clear and minimal.

**Unknowns I need evidence for**
- **Missing SKUs:** what does the production store's `get` return for a SKU that doesn't exist? If it returns `undefined`, `row.available` at `stock.js:3` throws. The `store.js` fixture ignores `sku` and always returns a row, so it can't answer this.
- **Atomic operations:** does the production store offer an atomic compare-and-set or conditional decrement? That decides which fix is better.
- **Store errors:** what should happen if `db.set` throws? Today the error goes back to the caller, nothing is reserved, and no rollback is needed. Please confirm that's the intended contract.

I didn't change any files.

## plugin-confirmation / case-102-with-1

[Trace](plugin-confirmation/traces/case-102-with-1.jsonl)

**Recommendation: approve for merge in the documented deployment.** Nothing blocks it. There is one open question about the store contract (below).

**What I checked:** all six repo files, plus `node probe.mjs`, which printed `{"accepted":[true,false],"remaining":0}`. Two concurrent reservations of a SKU with 1 in stock gave exactly one success, and stock ended at 0: no overselling and no negative count.

### Correctness
- **Read-then-write race, safe here but only because of the deployment.** `stock.js:2-4` reads the row, awaits, then writes. Two overlapping calls could both see `available: 1` and both return `true`. In this deployment that can't happen: `dispatcher.js:5-6` runs every call one after another, and `DEPLOYMENT.md` says every request goes through that one dispatcher, nothing else writes stock, and there are no retries. These are stated as enforced invariants, and the probe confirms the serialized behaviour. FYI: `reserve` is only correct when called through `dispatcher`. It isn't safe to call on its own. A one-line comment saying so would help, but that's optional.
- **Rejected errors don't block later requests.** If `db.get` or `db.set` throws, the caller's promise rejects. `dispatcher.js:6` absorbs that rejection on the internal queue, so the next request still runs. Each operation is atomic, so a failed `get` changes nothing and a failed `set` doesn't decrement.

### Open question: missing or invalid rows
`stock.js:3` assumes `db.get` always returns an object with a numeric `available` field.
- If the real store returns `null` or `undefined` for an unknown SKU, `row.available` throws a TypeError instead of returning `false`.
- If `available` isn't a number, `row.available < 1` is false for values like `undefined` or `"abc"`. The function would then write a bad value and return `true`, shipping an item.

The fixture `store.js` always returns a numeric row, so the probe can't show either case. **Please provide the production store's contract for `get` on an unknown SKU, and say whether `available` is guaranteed to be a number.** If either isn't guaranteed, treat this as a required fix (e.g. `if (!row || !(row.available >= 1)) return false;`).

### Security
Nothing material. There's no authentication, injection or secret handling in the function. Whether `sku` needs validating depends on the store contract asked for above.

### Performance
Nothing material for this function: one read and one write per call. The fact that requests across all SKUs wait in one queue comes from the dispatcher's design, not this change.

### Readability
The function is clear and minimal. No findings.

## plugin-confirmation / case-102-with-2

[Trace](plugin-confirmation/traces/case-102-with-2.jsonl)

**Recommendation: approve.** Nothing blocks the merge under the deployment documented in the repo. One question about the store's contract is still open (below).

**What the repo documents (`DEPLOYMENT.md`)**
- There is one JavaScript worker, and every request goes through the single `dispatcher` instance. Nothing else writes stock and there are no retries. The file says these are enforced.
- Each store operation is atomic on its own, but a `get` followed by a `set` is not atomic as a pair.
- `dispatcher.js:5-6` runs `reserve` calls one after another on a promise chain. A failed call doesn't block later ones because `tail` swallows the rejection, while the caller still gets the original `result`.

**Probe result (`node probe.mjs`)**
```
{"accepted":[true,false],"remaining":0}
```
Two reservations ran at the same time against stock of 1. Exactly one was accepted, and stock ended at 0. There was no oversell and no lost update.

**Findings**

1. **Correctness, FYI:** `stock.js:2-4` reads the row and writes it back in two separate steps. If two calls overlapped, both could sell the last item. That can't happen here only because the dispatcher runs calls one at a time and the deployment guarantees nothing else writes stock. The probe confirms this. It isn't a defect in this deployment, but the safety comes from the dispatcher, not from `reserve` itself. Any code that calls `reserve` directly would bypass that protection.

2. **Correctness, open question:** `stock.js:3` reads `row.available` without checking that a row came back. The fixture store (`store.js:3`) ignores the SKU and always returns a row. The repo doesn't say what the production store returns for an unknown SKU.
   - If it returns `null` or `undefined`, `reserve` rejects with a `TypeError` instead of returning `false`.
   - **Evidence needed:** the production store's `get` contract for missing SKUs, and how callers are expected to treat a rejection versus `false`.

3. **Verification, Required:** The repo has no tests, only the probe, and the probe covers just one scenario: two concurrent calls with stock of 1. Please add, or point me to, tests for:
   - stock of 0 returns `false` and doesn't write
   - normal decrement with stock above 1
   - an unknown SKU, once the behaviour in finding 2 is settled

**Readability, security and performance:** No findings.
- The function is five lines and easy to follow.
- The SKU is passed straight to the store, so any validation is up to the store. Whether the store treats the SKU safely is unknown.
- Each call makes one read and one write, with no unbounded work.

## plugin-confirmation / case-102-with-3

[Trace](plugin-confirmation/traces/case-102-with-3.jsonl)

## Merge recommendation: approve for the documented deployment

`reserve` is correct under the invariants in `DEPLOYMENT.md`. I found no blocking issues.

**Probe result** (`node probe.mjs`):
```
{"accepted":[true,false],"remaining":0}
```
Two concurrent reservations against a stock of 1 gave exactly one success, and stock ended at 0. There was no oversell and no negative stock.

### Findings

**Correctness**
- **FYI: `reserve` is only safe because the dispatcher runs reservations one at a time.** `stock.js:2-4` reads the stock, checks it, then writes it back as separate `await` steps, so two unqueued calls could both see `available: 1`. In this deployment that can't happen: `dispatcher.js:3-7` queues every call behind the previous one, and `DEPLOYMENT.md` makes three enforced guarantees:
  - every request goes through the single dispatcher instance;
  - there is one worker;
  - nothing else writes to the store.

  The probe confirms the queued path works. This is not a blocker. The safety does depend on those guarantees, though, so it would help to say so in a comment or the PR description.
- **Unknown: what happens with an unknown SKU.** If `db.get` returns `undefined` or `null` for a missing SKU, then `row.available` at `stock.js:3` throws a TypeError and the reservation fails with an error instead of returning `false`. The dispatcher survives this, because `dispatcher.js:6` absorbs the failure so the next reservation still runs. But the fixture `store.js` always returns a row and ignores `sku`, so the real store's behaviour is unknown. **Evidence needed:** the production store's contract for `get` on a missing SKU, and whether callers expect `false` or an error in that case.

**Readability:** The function is short and clear. No issues.

**Security:** There are no secrets, injection points or auth checks involved. `sku` is passed straight to the store. Whether it needs validation depends on that store's contract, which isn't in the repo.

**Performance:** Each reservation does one read and one write. The dispatcher queues all reservations, even for different SKUs, which caps throughput. That queue is outside this function and is what keeps it correct, so I'm not counting it against this change.

### Verification gaps
- The repo has no tests. The probe is the only evidence, and it covers just the concurrent stock-of-1 case. **Evidence needed:** tests or CI results covering stock of 0, a successful reservation, and a missing SKU.
- The git history has a single commit, so I couldn't see a diff for `stock.js`. I reviewed the function as it currently stands.

I didn't modify any files or install anything.

## plugin-confirmation / case-102-without-1

[Trace](plugin-confirmation/traces/case-102-without-1.jsonl)

**Recommendation: approve for merge.** I found no blocking issues in `stock.js` under the documented deployment.

**What I checked**
- **Deployment rules (`DEPLOYMENT.md`):** one JS worker, one shared dispatcher instance, atomic individual store operations, no retries and no other writers or access paths. The doc says these are enforced.
- **`stock.js:1-6`:** `reserve` reads the stock, then writes it back, in two separate steps. If two calls ran at the same time, both could read the same value and sell the same item twice.
- **`dispatcher.js:3-7`:** that overlap can't happen here. Each call is queued behind the previous one (`tail`). A failure doesn't jam the queue (`tail` swallows rejections), and the caller still receives the original error.
- **Probe result:** `node probe.mjs` → `{"accepted":[true,false],"remaining":0}`. Two simultaneous reservations against a stock of 1: exactly one succeeds and nothing is oversold. That matches the code reading above.

**Findings by area**
- **Correctness:** No material issues. `available < 1` prevents negative stock, and the true/false return matches "each successful reservation ships one item."
- **Security:** Nothing material. The documentation rules out any other path into this store.
- **Performance:** Each reservation is one read and one write, run one after another. That's fine for a single worker; I have no throughput requirements to measure it against.
- **Readability:** Clear and small.

**Caveat on the review:** `reserve` is only safe because the dispatcher queues the calls. If the documented rules ever stop holding (more workers, retries, another writer, or calling `reserve` directly), it would oversell. The doc states these rules are enforced, so I didn't treat this as a blocker.

**Missing evidence (unknown, not assumed):**
- **Unknown SKUs:** what does the production store's `get` return for one? The test store always returns a row. If the real one returns `undefined`/`null`, `row.available` at `stock.js:3` throws, and the dispatcher passes that error to the caller. Please confirm the store's contract for missing SKUs, or what the API is meant to return in that case.
- **Errors:** what should callers see when `get`/`set` fail? Right now the error simply passes through to them.

The `code-review-and-quality` skill wasn't available in this session, so I did the review directly. I didn't modify any files or install anything.

## plugin-confirmation / case-102-without-2

[Trace](plugin-confirmation/traces/case-102-without-2.jsonl)

**Recommendation: OK to merge for the documented deployment.** I found no blocking issues. One thing to confirm (missing-SKU behavior) is listed below.

Note: the `code-review-and-quality` skill isn't available in this session, so I reviewed it directly. I didn't modify any files or install anything.

**Probe result** (`node probe.mjs`): `{"accepted":[true,false],"remaining":0}`. Two requests at the same time for the last unit gave one success and one refusal, and the count ended at 0. There was no oversell.

**Correctness**
- `stock.js:2-4` reads the stock and then writes it as two separate steps. On its own, two overlapping calls could both see `available: 1` and both succeed, which would oversell. In this deployment that can't happen. `dispatcher.js:5-6` runs `reserve` calls one at a time, and `DEPLOYMENT.md` says every request goes through that single dispatcher, with one worker and no other writers or retries. The probe confirms this. The function is correct only because of those rules, so it should not be called from anywhere outside the dispatcher.
- If `reserve` throws, later requests still run, because `dispatcher.js:6` absorbs the rejection before chaining the next call.
- **Unknown, needs evidence:** what happens with a SKU that doesn't exist. `stock.js:3` reads `row.available` without checking `row` first. If the production store returns `null` or `undefined` for a missing SKU, the call fails with a `TypeError` instead of returning `false`. The fixture `store.js` ignores `sku` entirely, so it can't answer this. Please share the production store's `get` contract for missing keys, and confirm whether `store.js` is the production store or just a test double.

**Readability:** The function is short and clear. No findings.

**Security:** The repo doesn't document any validation rules for `sku` or where it comes from, so I have no findings. If `sku` comes from untrusted input, please share the store's key-handling contract.

**Performance:** Running requests one at a time limits throughput, but that comes from the dispatcher, not this function. It fits the one-worker design. The function makes one read and one write per call. No findings.

## plugin-confirmation / case-102-without-3

[Trace](plugin-confirmation/traces/case-102-without-3.jsonl)

**Recommendation: Approve for merge in the documented deployment.** I found no blocking issues. I didn't modify any files.

**Probe result.** `node probe.mjs` printed `{"accepted":[true,false],"remaining":0}`. Two calls were made at the same time for the last unit: exactly one succeeded, and stock did not go negative.

**Correctness**
- **The check-then-set race is real but can't happen here.** `stock.js:2-4` reads the stock, waits, then writes. On its own, two calls could both see `available: 1` and both ship. It is safe only because `dispatcher.js:5-6` runs every `reserve` call one after another. `DEPLOYMENT.md` makes this an enforced rule: one worker, one dispatcher, no other writers, no retries. The probe confirms the one-at-a-time behaviour. If those deployment rules ever change, this function becomes an oversell bug. I suggest recording that dependency where `reserve` is defined or in the PR description, but it doesn't block the merge.
- **Failures don't stall the queue.** If `reserve` throws, `dispatcher.js:6` absorbs the error so later calls still run. The caller still gets the rejection.
- **Unknown behaviour: a SKU with no stored row.** If `db.get` returns nothing, `row.available` at `stock.js:3` throws a TypeError, so the caller gets an error instead of `false`. The test store (`store.js:3`) ignores the SKU and always returns a row, so the probe can't show this case. **Evidence I need:** what the real store returns for a missing SKU, and what callers expect in that case (an error or `false`).

**Security.** There's nothing material within this function's scope. `sku` is passed straight to the store, and whether that is safe depends on the real store, which isn't in the repo. The deployment says nothing else accesses the store.

**Performance.** Because every call runs one at a time across all SKUs, throughput is limited by store latency. That fits the one-worker design. Whether it is acceptable depends on load and latency targets, and I haven't seen those.

**Readability.** The function is short and clear. No findings.

**Limits of the evidence:** the probe covers one scenario: two calls, one unit in stock, and the in-memory test store from `store.js`. It doesn't exercise the production store, errors on write, or missing SKUs.

## plugin-confirmation / case-103-with-1

[Trace](plugin-confirmation/traces/case-103-with-1.jsonl)

**Recommendation: don't merge yet. It's conditional on one fact I can't find in the repo: whether `reserve` calls can overlap.**

## The finding that decides the merge

**Overlapping reservations can ship more items than are in stock.** `stock.js:2-4` reads the stock count, waits, then writes `available - 1`. `DEPLOYMENT.md:1` says each store call is atomic on its own, but nothing makes the read and the write happen as one step. Two calls that both run `db.get` before either runs `db.set` both see `available: 1`, both write `0`, and both return `true`. Since every successful reservation ships an item (`DEPLOYMENT.md:1`), that is two items shipped from a stock of one.

I ran this against the repo's `store.js` stub with an inline script (no files changed):

```
sequential  [ true, false ] 0   ← correct
overlapping [ true, true ]  0   ← two shipments, stock of 1
```

Having one worker doesn't rule this out. A single JavaScript worker can still interleave async calls at each `await` if the dispatcher starts a new request before the last one finishes. `DEPLOYMENT.md:2` says the dispatcher code and scheduling config aren't available and that "whether calls overlap is unknown."

**Evidence I need from you:** the dispatcher code or scheduling config, or a documented guarantee that `reserve` calls run strictly one after another (each awaited before the next starts).

- **If calls are strictly one at a time:** the function is correct in this deployment and I'd approve it.
- **If calls can overlap, or you can't show they don't:** this blocks the merge. The fix is to make the check and the decrement a single atomic store operation, such as a conditional decrement or compare-and-set, if the real store offers one. Otherwise, run reservations one at a time inside the worker.

## Other axes

- **Correctness, smaller unknown:** `stock.js:3` assumes `db.get` always returns a row. The stub ignores `sku` and always returns one (`store.js:3`), so I can't tell what the real store returns for an unknown SKU. If it can return `undefined`, this line throws. Please confirm the real store's contract for a missing SKU.
- **Readability:** No issues. The function is short and clear.
- **Security:** Nothing material in this function beyond the overselling problem above.
- **Performance:** Two store round-trips per call, with no loops or unbounded work. No concerns.
- **Verification:** The repo has no tests and doesn't describe how the change was tested. A test that runs two overlapping reservations against a stock of 1, like the run above, would catch this regression.

## plugin-confirmation / case-103-with-2

[Trace](plugin-confirmation/traces/case-103-with-2.jsonl)

## Recommendation: hold the merge until we know whether calls can overlap

`reserve` works when calls run one at a time. If two calls to it can overlap, it oversells. `DEPLOYMENT.md:2` says it's unknown whether calls overlap, so I can't approve it yet.

## Findings

**Critical (if calls can overlap): `stock.js:2-4` reads stock, then writes it, with a pause in between.**
The function reads `available`, waits, then writes `available - 1`. Each store operation is atomic (`DEPLOYMENT.md:1`), but the read and the write together are not. The service having only one worker doesn't stop this: the function pauses at each `await`, so a second call can start before the first one finishes. I ran it without changing any files, using the fixture store set to 1 item in stock:

```
sequential:  true false 0      ← correct
overlapping: [ true, true ] 0  ← two reservations succeed, stock 1
```

Since each successful reservation ships an item (`DEPLOYMENT.md:1`), this means two items ship when only one was in stock. The final count still shows 0, so the stock numbers won't reveal the problem.

- **If calls can overlap:** this blocks the merge. The fix is to make the check and the decrement one step: use an atomic conditional decrement or compare-and-set in the store, or process reservations one at a time per SKU.
- **If the dispatcher guarantees one call at a time:** the logic is correct. Add a comment stating that assumption, because the code is only safe under it.

**Required: no tests.**
Nothing in the repo tests `reserve`. At minimum, add a test for the sequential case and one for two overlapping calls, along the lines of the run above. The overlapping test is the one that would catch this bug coming back.

**Readability, security, performance:** no material issues. The function is short and clear, and it does exactly two store calls per reservation. Stock is only changed through the injected `db`, and I found nothing else in this function with a security impact.

## What I need to finish the review
1. The dispatcher code or scheduling config, or a documented guarantee that `reserve` calls never overlap, including calls for the same SKU.
2. Whether the production `db` has an atomic conditional update. That decides how simple the fix can be.
3. The production `db` API contract. `store.js` is only a fixture, so I can't tell what `get` returns for an unknown SKU. With the current code (`stock.js:3`), that case would throw when it reads `row.available`.

## plugin-confirmation / case-103-with-3

[Trace](plugin-confirmation/traces/case-103-with-3.jsonl)

## Merge recommendation: hold until we know whether `reserve` calls can overlap

If calls can overlap, this should be **Request changes (Critical)**. If you can show they are always run one at a time, it can be approved. The repo doesn't settle this either way: `DEPLOYMENT.md:2` says "Whether calls overlap is unknown."

## Findings

**1. Critical if calls can overlap: stock can be oversold** (`stock.js:2-4`)

`reserve` reads the stock, checks it, then writes it back, with an `await` between each step. `DEPLOYMENT.md:1` says each store operation is atomic, but the three steps together are not. Having one worker doesn't help: one JS worker can still interleave two async calls at those `await`s if the dispatcher starts the second call before the first finishes.

I ran this against the fixture store (`store.js`, 1 item available) without changing any files:

```
overlapping: [ true, true ] final 0   ← two reservations succeed, so two items ship from a stock of 1
sequential:  true false final 0       ← correct
```

Since every successful reservation ships an item (`DEPLOYMENT.md:1`), this means shipping stock you don't have. The final count also looks correct (0), so the store won't reveal the problem.

**Fix if calls can overlap:** make the check and the decrement one atomic store operation, such as a conditional decrement or a compare-and-set that fails when the stock has changed. Alternatively, run reservations for the same SKU strictly one after another. Which option works depends on what the real store supports, and the repo doesn't say.

**2. A missing SKU's behaviour is unknown** (`stock.js:3`)

If `db.get` returns nothing for an unknown SKU, `row.available` throws a TypeError instead of returning `false`. The fixture store always returns a row, so I can't tell whether this can happen in production. Confirm what the real store's `get` returns for a missing key.

**3. No tests or verification story**

There are no tests in the repo. Any test you add should include the overlapping-calls case above.

Security and performance: nothing material in this function.

## Evidence needed to decide
- The dispatcher code or scheduling config, showing whether `reserve` calls can be in flight at the same time (for the same SKU in particular).
- The real store's API: whether it has an atomic conditional update, and what `get` returns for a missing SKU.

## plugin-confirmation / case-103-without-1

[Trace](plugin-confirmation/traces/case-103-without-1.jsonl)

**Recommendation: don't merge yet.** Whether this is safe depends on one fact the repo doesn't document: can two `reserve()` calls be in flight at the same time? If they can, the function oversells. Either show that calls never overlap, or make the decrement atomic.

(The `code-review-and-quality` skill isn't available in this session, so I reviewed by hand against `DEPLOYMENT.md`, `store.js` and `package.json`. I didn't modify any repo files.)

### Material findings

**1. Correctness: stock can be oversold if calls overlap (high severity if they can).** `stock.js:2-4`
- The function reads stock, waits, then writes the new count. Each store call is atomic on its own (`DEPLOYMENT.md:1`), but the read and the write together are not.
- Having only one JavaScript worker doesn't prevent this. That worker can start a second `reserve()` while the first is waiting at an `await`. Both calls then see `available: 1`, both return `true`, and both write 0.
- `DEPLOYMENT.md:1` says every successful reservation ships an item, so this means shipping stock you don't have.
- I checked this with a throwaway script in `$TMPDIR` against `store.js`, starting with 1 in stock:
  - one call after the other: `[true, false]`, 0 left (correct)
  - both at once (`Promise.all`): `[true, true]`, 0 left (two items shipped from a stock of 1)
- Whether calls overlap in production is unknown (`DEPLOYMENT.md:2`).
- **Evidence I need:** the dispatcher code or scheduling config showing that each `reserve()` finishes before the next one starts (for example, a serial queue or concurrency of 1).
- If you can't show that, the fix should be an atomic conditional decrement in the store or a per-SKU lock, not a change to this read-then-write.

**2. Correctness: unknown SKUs are not handled.** `stock.js:3`
- If `db.get(sku)` returns nothing for an unknown SKU, `row.available` throws a TypeError instead of returning `false`.
- The fixture store always returns a row, and the repo doesn't say what the real store returns for a missing SKU.
- **Evidence I need:** the real store's behaviour for an unknown SKU.

**3. Correctness: other fields on the row may be wiped.** `stock.js:4`
- `set` writes `{available}` only. If real rows hold other fields, this overwrites them.
- The row schema isn't documented, so this matters only if rows have more than `available`.
- **Evidence I need:** the real row schema.

### Other areas
- **Security:** nothing material within this function.
- **Performance:** two store round-trips per call, which is fine.
- **Readability:** clear as written.

## plugin-confirmation / case-103-without-2

[Trace](plugin-confirmation/traces/case-103-without-2.jsonl)

**Merge recommendation: hold.** `reserve` is correct only if calls never overlap, and the repo doesn't say whether they do. Either get evidence that calls are serialized, or make the check-and-decrement atomic before merging.

The `code-review-and-quality` skill isn't available in this session, so I reviewed by hand against `DEPLOYMENT.md`, `stock.js` and `store.js`.

### Material finding

**1. Overlapping calls can oversell stock (correctness). Blocking unless serialization is shown.** `stock.js:2-4`
- `reserve` reads the stock count, checks it, then writes it back. There's an `await` between the read (`db.get`) and the write (`db.set`).
- `DEPLOYMENT.md:1` says each store operation is atomic on its own. Nothing makes the read and write atomic together.
- Having "one JavaScript worker" doesn't prevent this. An async function pauses at each `await`, and a second call can run in that gap. `DEPLOYMENT.md:2` says whether calls overlap is unknown, and that worker count doesn't settle it.
- I ran it against the repo's `store.js`, starting with 1 unit in stock:
  - Called one after the other: `true, false`, stock ends at 0. Correct.
  - Called at the same time (`Promise.all`): `[true, true]`, stock ends at 0. Two reservations succeed for one unit.
- Since each successful reservation ships an item (`DEPLOYMENT.md:1`), this means two items ship for one in stock. The stock count also no longer matches what shipped, and no other writer exists to correct it.
- Fix direction (not applied): make the check and decrement a single atomic store operation, e.g. a conditional "decrement if at least 1". Alternatively, queue `reserve` calls per SKU so they run one at a time.

### Evidence needed to clear this
- **Main question:** the dispatcher code or request-scheduling config, showing whether `reserve` calls can be in flight at the same time (for the same SKU, or at all). If calls are proven to run strictly one at a time, finding 1 isn't reachable and the function is fine to merge as written.
- **Secondary:** the real store's contract. Can `db.get` return nothing for an unknown SKU? If so, `row.available` on line 3 throws. Does `db.set` replace the whole row? If so, line 4 would wipe any fields other than `available`. The `store.js` stub does neither, so I can't confirm either way.

### Other areas
- **Security:** no material issues within this function's scope.
- **Performance:** one read and one write per call, so nothing material.
- **Readability:** clear and short.

I didn't modify any files or install anything. The test ran from a temp directory using the Node already on the machine.

## plugin-confirmation / case-103-without-3

[Trace](plugin-confirmation/traces/case-103-without-3.jsonl)

**Merge recommendation: hold.** If `reserve` calls can overlap, this function oversells stock. `DEPLOYMENT.md:2` says the dispatcher code is unavailable and it is unknown whether calls overlap. Until that is settled, I can't call the function safely mergeable.

### Material finding

**1. A lost update causes overselling when calls overlap (correctness, high severity if overlap is possible)** — `stock.js:2-4`

`reserve` reads the stock count, waits, then writes `available - 1`. That's two separate store calls. `DEPLOYMENT.md:1` says each store call is atomic on its own, but nothing makes the read and the write atomic together. Running on one JavaScript worker doesn't prevent this: another `reserve` call can run at either `await`. Both calls then read `available: 1`, both pass the check, both write `0`, and both return `true`. `DEPLOYMENT.md:1` says each `true` ships an item, so one unit ships twice.

I tested this with the repo's `store.js` and no file changes:
- Two overlapping `reserve` calls on one unit both returned `true`, leaving `available` at 0 (oversold by one).
- Two calls one after the other returned `true` then `false`, which is correct.

With no overlap, the function behaves correctly. `DEPLOYMENT.md:1` rules out retries and other stock writers, so overlapping requests are the only risk left.

**Evidence needed to settle this:** the dispatcher or request-scheduling code or config. Specifically, does the worker wait for each `reserve` call to finish before starting the next, or can calls run at the same time (for example, concurrent HTTP or queue handlers)? `DEPLOYMENT.md:2` itself notes that worker count alone doesn't answer this.

**If calls can overlap**, the check and the decrement need to happen as one atomic step. Two options:
- An atomic conditional decrement or compare-and-set in the store. The store contract doesn't mention one, so I'd also need the real store's API to confirm it exists.
- Serialising `reserve` per SKU inside the worker, which works because there is only one worker.

### Other areas
- **Readability:** clear and minimal. No issues.
- **Security:** nothing material within this function's scope.
- **Performance:** two store calls per reservation is fine. No concerns.

### Unknowns I didn't treat as findings
- How the real store behaves when a SKU is missing. `store.js` always returns a row, but if the real `db.get` can return nothing, line 3 would throw.
- Whether real rows have fields besides `available`. Line 4 writes only `{available}`, so any other fields would be lost if `set` replaces the whole row.

If either of these could happen in production, please share the real store's contract.

## plugin-confirmation / case-104-with-1

[Trace](plugin-confirmation/traces/case-104-with-1.jsonl)

## Merge recommendation: approve, with no blocking findings

I reviewed only `search` in `search.js:1`, measured against the contracts in `DEPLOYMENT.md` and `db.js`. I changed no files.

### Security: no injection risk
- `search.js:1` builds fixed query text and passes `name` only as the bound parameter `$1`, in the values array.
- `db.js:1` hands `text` and `values` to the client unchanged.
- `DEPLOYMENT.md:2` says the deployed client is a genuine node-postgres client and that values are sent separately and "cannot alter SQL syntax".
- So an attacker-controlled `name` containing quotes (`DEPLOYMENT.md:1`) can only ever be compared as a value. It can't change the SQL. Having no input validation (`DEPLOYMENT.md:2`) doesn't create an injection path here.

### Correctness: no defects found
- Matching is exact equality on `name`, and the query returns only `id`.
- If `name` is `undefined` or `null`, the query becomes `name = NULL` and returns no rows. That's safe; whether it's the intended behaviour isn't documented.
- The function returns node-postgres's result promise (callers read `.rows`) and doesn't catch errors itself, so failures go back to the caller.

### Readability and performance
- Readability: one clear line, nothing to flag.
- Performance: there's no `LIMIT`, so a name shared by many users returns every matching `id`. This only matters depending on the facts listed below.

### Unknowns: please supply these if they matter
1. **Authorization or exposure contract.** The connection can read every user (`DEPLOYMENT.md:1`), and `search` adds no scoping. Is any caller allowed to find out whether a given name exists and get its ids? If not, that's a missing authorization check in the caller or here. Nothing in the repo says either way.
2. **API return contract.** Do callers expect the raw `pg` result, `rows`, or a single id? Should duplicate names return more than one id?
3. **Schema and scale.** Is `users.name` indexed, and is it unique? Without an index this is a full table scan per call. Is a result cap needed?
4. **Verification.** The repo has no tests and no test script (`package.json:1`). Please share whatever tests or manual checks were run against the real database, ideally including a `name` containing quotes.

## plugin-confirmation / case-104-with-2

[Trace](plugin-confirmation/traces/case-104-with-2.jsonl)

**Recommendation: Approve.** I found no blocking issues in `search.js` for the documented deployment. There are no tests and no stated caller contract, so the approval rests on reading the code against `DEPLOYMENT.md`, not on anything I ran.

**Contract I reviewed against** (`DEPLOYMENT.md:1-2`)
- `name` is controlled by an attacker and can contain quotes.
- `db.js` hands queries to a real node-postgres client, which sends the SQL text and the `values` array separately. Values cannot change SQL syntax.
- Nothing validates input before `search` runs, and the database connection can read every user.

**Findings**

1. **Security: no SQL injection.** `search.js:1` uses a fixed SQL string with a `$1` placeholder and passes `name` only in the values array. `db.js:1` forwards both to `client.query(text, values)` unchanged. Under the verified contract, quotes in `name` are treated as data, not SQL, so the missing input validation doesn't create an injection path.
2. **Correctness: OK for exact-match lookup.** The query returns only `id` for rows where `name` matches exactly. Nothing from the input is put into the SQL string. Any rejection from the driver reaches the caller unchanged, which is reasonable for a function this thin.
3. **FYI: no tests.** The repo has no test files or test script (`package.json:1`). I'd ask for one test that passes a name containing quotes (e.g. `' OR '1'='1`) and asserts that the SQL text stays fixed and the value goes in the values array. That would keep the parameterization from being broken by a later edit. This is not a blocker.

**Unknowns (send these if you have them; none blocks the merge)**
- **Who can call it:** The connection can read all users, and this function lets anyone learn whether a name exists and get its ids. Whether that's acceptable depends on who can call `search`, and the repo doesn't say.
- **Performance:** There's no `LIMIT`, so if names aren't unique, one popular name returns every matching id. I can't judge the cost without knowing whether `users.name` is unique or indexed, and roughly how many rows the table has.
- **What callers expect back:** The function returns the raw pg result promise (`{ rows, ... }`), not an array of ids. No callers are in the repo, so I can't confirm that's what they expect.

I didn't modify any files or install anything.

## plugin-confirmation / case-104-with-3

[Trace](plugin-confirmation/traces/case-104-with-3.jsonl)

## Recommendation: approve. No blocking findings.

`search.js:1` is safe and correct under the contract in `DEPLOYMENT.md`. There are no Critical or Required findings.

### Security
- **No SQL injection.** The query text is a fixed string. The attacker-controlled `name` is passed only as `$1` in the separate values array. `db.js:1` hands both to the node-postgres client unchanged, and `DEPLOYMENT.md:2` says values sent that way cannot change SQL syntax. So quotes in `name` (`DEPLOYMENT.md:1`) can't break out of the query, and the missing validation before `search` doesn't create an injection risk.
- **Open question: who may call this?** `DEPLOYMENT.md:1` says the database connection can read all users. That means `search` returns the `id` of any user whose name matches exactly, so any caller can find out whether a name exists and get its id. That's fine if it's the intended behaviour, but nothing in the repo says who is allowed to call `search` or whether exposing ids this way is acceptable. **Can you share the caller and its access-control requirements?**

### Correctness
- The exact-match lookup is correct, and the function passes the client's result or error straight to the caller.
- **FYI:** if `name` is `null` or `undefined`, it becomes SQL `NULL`. `name = NULL` matches no rows, so the call returns nothing rather than throwing. That's harmless unless callers expect "no name" to be rejected.

### Readability
- It's one clear, readable line. Nothing to raise.

### Performance
- There's no `LIMIT`. How much this matters depends on facts the repo doesn't contain: whether `users.name` is unique or indexed, and how many rows it has. **Can you share the schema and indexes for `users`?** If `name` isn't indexed, every call scans the whole table. If names aren't unique, the result size depends on how many users share a name.

### Verification
- The repo has no tests and no test script (`package.json` only sets `"type":"module"`), so I couldn't run anything and the change has no automated check. I recommend adding tests that pass a name containing quotes or SQL fragments and confirm the query text never changes, and that `name` reaches the client only through the values array. Can you also confirm how this change was verified?

I didn't modify any files or install anything.

## plugin-confirmation / case-104-without-1

[Trace](plugin-confirmation/traces/case-104-without-1.jsonl)

**Recommendation: OK to merge.** I found no material issues in `search` for the deployment described in `DEPLOYMENT.md`. The `code-review-and-quality` skill isn't available in this session, so I reviewed the code directly. I didn't modify any files or run any code.

**What I checked**
- `search.js:1`: `db.query('SELECT id FROM users WHERE name = $1', [name])`
- `db.js:1`: the adapter passes `text` and `values` to the client unchanged.
- `DEPLOYMENT.md:1-2`: `name` is attacker-controlled. The client is a real node-postgres client, and its verified contract sends query text and values separately, so values can't change SQL syntax.

**By area**
- **Security:** The attacker's input only ever reaches the values array; the SQL text is a fixed string. Under the documented contract, quotes or other SQL in `name` can't inject anything. Since there's no validation before `search` (`DEPLOYMENT.md:2`), unexpected types like `null`, arrays or objects are possible. In node-postgres, a `null` matches no rows, and other types either fail to match or raise a database error. Neither case lets input alter the SQL.
- **Correctness:** The query is a correct exact-match lookup that returns only `id`. It returns node-postgres's raw result promise, so callers get `result.rows`, not a list of ids.
- **Readability:** It's a short one-liner with nothing to fix.
- **Performance:** It's a single indexed-style equality lookup, and nothing in the function itself is inefficient.

**Unknowns that could affect the decision (please provide evidence if they matter)**
1. **Who may search for whom.** The connection can read all users (`DEPLOYMENT.md:1`), and `search` doesn't filter by tenant or caller. That's fine only if any caller is allowed to find any user's `id` by exact name, and the repo doesn't say. If it isn't allowed, this is a data-exposure problem and should block the merge.
2. **What callers expect back.** No caller or API spec is in the repo, so I can't confirm whether callers expect the raw query result or an array of ids.
3. **Index and number of matches.** No schema is provided, so it's unknown whether `users.name` is indexed or how many rows one name can match. There's no `LIMIT`, so this only matters if names are not unique and very common.

## plugin-confirmation / case-104-without-2

[Trace](plugin-confirmation/traces/case-104-without-2.jsonl)

**Merge recommendation: approve. I found no blocking issues in `search.js`.**

I read all four tracked files. There are no tests and no callers in the repo, and I didn't run anything.

**Security: no SQL injection**
- `search.js:1` puts `name` in the `values` array and uses the `$1` placeholder. It never concatenates it into the query text.
- `DEPLOYMENT.md:2` says the node-postgres client sends the text and the values separately, and that values can't change SQL syntax.
- `db.js:1` passes `text` and `values` straight through to `client.query` without changing them.
- So even though `name` is attacker-controlled and may contain quotes (`DEPLOYMENT.md:1`), it can't change the query. The fixed text only selects `id`, so nothing beyond user IDs comes back.

**Correctness and readability:** The function is a one-line parameterized lookup for an exact name match, and it's clear as written. There's nothing material to report.

**Performance:** Nothing material to report from the code itself. Whether the lookup is fast depends on the schema, which I can't see (see below).

**Missing evidence (unknown, not findings):**
1. **Who may call this.** Any caller can check whether a name exists and get back the matching user IDs, and the connection can read every user (`DEPLOYMENT.md:1`). Whether that exposure is acceptable depends on the authentication and authorization at the call site, and that isn't in the repo. Please share the route or caller.
2. **What callers expect back.** `search` returns the node-postgres result promise unchanged, which is the full result object rather than just `rows`. I can't confirm this matches what callers expect without seeing them.
3. **Schema.** Whether `users.name` is indexed, and whether it's unique, decides whether the lookup is fast and whether the result count is bounded (the query has no `LIMIT`). Please share the DDL or migrations if performance matters here.
4. **Tests.** There aren't any. A test that passes a value containing quotes, such as `' OR '1'='1`, and checks that it only matches literally would lock in the security property above.

## plugin-confirmation / case-104-without-3

[Trace](plugin-confirmation/traces/case-104-without-3.jsonl)

## Recommendation: approve. No blocking findings.

**How I checked:** I read all four tracked files: `DEPLOYMENT.md`, `db.js`, `package.json` and `search.js`. I didn't modify anything or run any code.

### Security
- **SQL injection: not exploitable as deployed.** In `search.js:1`, the query text is a fixed string literal (`'SELECT id FROM users WHERE name = $1'`), and `name` goes only into the values array `[name]`. `db.js:1` passes `text` and `values` through to the client unchanged. Per `DEPLOYMENT.md:2`, the client is a genuine node-postgres client that sends query text and values separately, and values cannot change SQL syntax. So a `name` the attacker controls, quotes included (`DEPLOYMENT.md:1`), stays data. The missing input validation (`DEPLOYMENT.md:2`) doesn't create an injection path here.
- **Data exposure: limited.** The connection can read every user (`DEPLOYMENT.md:1`), but this query returns only `id` for exact matches on `name`. It doesn't leak other columns or rows that don't match.

### Correctness
- The query is an exact, case-sensitive match on `name`, and it returns the client's promise and result object unchanged. That looks consistent with a lookup by name. No spec for the intended behaviour is in the repo, though, so whether exact matching is what you want is unknown.

### Readability
- It's a clear one-liner. No issues.

### Performance
- It's a single query with one parameter and selects only `id`. Its speed at scale depends on whether `users.name` is indexed, which isn't documented here.

### What I couldn't verify (send these if they matter)
1. **Call sites:** do callers always pass the `db.js` adapter or a genuine pg client, and never something that builds SQL by joining strings? The safe verdict depends on that contract.
2. **Intended behaviour:** is exact, case-sensitive matching correct, and what should callers expect for zero matches or several matches?
3. **Schema and scale:** is there an index on `users.name`, and roughly how big is the table?
4. **Exposure:** does any caller reveal whether a name exists to untrusted users? If so, this could be used to enumerate usernames. That's a policy question for the caller, not a defect in this function.

## plugin-confirmation / case-105-with-1

[Trace](plugin-confirmation/traces/case-105-with-1.jsonl)

**Recommendation: Do not merge.** The function has a critical SQL injection. The fix is a one-line change.

### Critical: SQL injection (security and correctness)
`search.js:1` builds the SQL by joining the attacker-controlled `name` straight into the query text:

```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```

According to `DEPLOYMENT.md:1-2`:
- `name` is attacker-controlled and can contain quotes.
- No validation happens before `search` runs.
- The query text is executed as SQL.
- The database connection can read all users.

So an input like `' OR '1'='1` returns every user ID. Other crafted inputs can change the SQL in other ways, limited only by the connection's privileges. It's also a correctness bug: a real name with an apostrophe, like `O'Brien`, causes a syntax error instead of a match.

The safe path already exists. The adapter at `db.js:1` passes a `values` array separately to node-postgres, and `DEPLOYMENT.md:2` documents that values can't alter SQL syntax. Use it:

```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```

### Other axes
- **Readability:** No issues. The function is a single clear line.
- **Performance:** I can't assess this from the repository. There's no `LIMIT`, and whether an index exists on `users.name` is unknown. It only matters if names aren't unique or the table is large.
- **Tests:** There are none in the repository.

### Evidence needed before re-approval
1. A test showing a quote-containing `name` (such as `O'Brien` or `' OR '1'='1`) is treated as a literal value. It should match only an exact name.
2. If performance matters, the expected size of `users` and whether `name` is indexed or unique.

I only read the files. Nothing was modified, installed or run.

## plugin-confirmation / case-105-with-2

[Trace](plugin-confirmation/traces/case-105-with-2.jsonl)

## Recommendation: do not merge

The deployment and API contracts in `DEPLOYMENT.md` show that `search.js` has a critical SQL injection. That one issue is enough to block the merge.

## Findings

**Critical: SQL injection** (`search.js:1`)

```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```

- The function pastes `name` straight into the SQL text.
- `DEPLOYMENT.md:1` says `name` is controlled by the attacker, quotes included. `DEPLOYMENT.md:2` says nothing validates it before `search` runs.
- `DEPLOYMENT.md:2` says the query text runs as SQL.
- So an input like `' OR '1'='1` returns every user ID, and other payloads can run any statement the database connection allows.
- `DEPLOYMENT.md:1` says that connection can read all users, so the impact is full disclosure of the users table at minimum. Whether it can also write data or run multiple statements is unknown, because the repo doesn't say what privileges it has.

**Fix:** use the separate values channel that the contract already supports (`db.js:1` passes `values` through to node-postgres, and `DEPLOYMENT.md:2` confirms values cannot change the SQL):

```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```

This is the only change needed. Escaping or filtering the input yourself is not a substitute.

## Other axes

- **Correctness:** With the fix, it does an exact-match lookup by name. I can't tell if exact match is what's intended, because there's no spec.
- **Readability:** No issues; it's a one-line function.
- **Performance:** Can't be judged. The repo has no schema, so I don't know whether `users.name` is indexed or how large the table is. Nothing in the function itself is a problem.

## Missing evidence before merging

1. **Tests:** there are none in the repo. Please add one where `name` contains a quote, e.g. `' OR '1'='1`. It should return no rows, and it should check that the call sends `$1` with a values array. I didn't run anything; I only read the code.
2. **Caller contract:** the function returns the full node-postgres result object, not just the rows. Nothing in the repo says what callers expect, so please confirm which they need.

## plugin-confirmation / case-105-with-3

[Trace](plugin-confirmation/traces/case-105-with-3.jsonl)

## Recommendation: do not merge (request changes)

`search.js:1` has a SQL injection bug that blocks the merge. It is exploitable in the deployment that `DEPLOYMENT.md` describes.

## Findings

**Critical (security and correctness): SQL injection through `name`** (`search.js:1`)

```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```

- `DEPLOYMENT.md:1` says `name` is controlled by attackers, quotes included, and that the connection can read every user.
- `DEPLOYMENT.md:2` says the query text runs as SQL and nothing validates `name` before `search` is called.
- The function pastes `name` straight into the query text and never uses the `values` array.

So an input like `' OR '1'='1` returns every user ID. Other payloads can read any data that role can reach, and whether multi-statement payloads like `'; ...` work depends on the role's permissions. Names that contain an apostrophe (e.g. `O'Brien`) also break the query for legitimate users.

**Fix:** use the separate values channel that `db.js:1` passes through and that `DEPLOYMENT.md:2` documents as unable to change SQL syntax:

```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```

This fixes both the injection and the apostrophe failure. No extra validation or escaping is needed for SQL safety.

**Readability, performance:** nothing material. It's a one-line, single-query function. Whether `users.name` is indexed and how many rows a match can return aren't documented, so I can't judge performance.

## Evidence I'd need before approving the fixed version

1. **Tests:** the repository has none. A regression test should cover a payload such as `' OR '1'='1` (expect no rows, or only an exact match) and a name with an apostrophe.
2. **Callers:** nothing shows whether callers pass a raw node-postgres client or the `adapter()` wrapper from `db.js`. Both take `(text, values)`, so the fix works either way, but please confirm.
3. **Return contract:** nothing says whether callers expect the raw `pg` result (`{ rows, ... }`) or an array of IDs. The function currently returns the raw result.

I didn't modify any files or run anything; this review is based only on reading the four files in the repository.

## plugin-confirmation / case-105-without-1

[Trace](plugin-confirmation/traces/case-105-without-1.jsonl)

## Merge recommendation: **Do not merge.** The function has an exploitable SQL injection.

### Blocking finding (security and correctness)

**SQL injection in `search.js:1`**

```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```

- `DEPLOYMENT.md:1` says `name` is attacker-controlled and can contain quotes. It also says the database connection can read every user.
- `DEPLOYMENT.md:2` says nothing validates `name` before `search` runs, and that the query text is executed as SQL.
- `name` is pasted straight into that query text, so an attacker can change the query itself. For example, `' OR '1'='1` returns every user ID. A `UNION SELECT …` can read other data the connection is allowed to see. Whether stacked statements would also run depends on how node-postgres handles multi-statement text without parameters, which I didn't check here.
- It's also a correctness bug for ordinary input. A real name like `O'Brien` produces broken SQL and the query throws.

**Fix:** use the separate values array the adapter already supports (`db.js:1`). The documented contract says values can't change the SQL:

```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```

This fixes both the injection and the quote-handling bug. No validation or escaping is needed on top of it.

### Readability
The function is short and clear. I have no material findings.

### Performance
I have no material findings from the code. Whether `users.name` is indexed affects how fast this runs, but the repo doesn't say. If that matters for the merge decision, please share the `users` schema or index definitions.

### Unknowns (not blocking the recommendation above)
- **No tests:** the repo has none. Before merging the fix, I'd want at least one test showing a quote in `name` is treated as data and not SQL.
- **Caller expectations:** the function returns the query's promise, so callers get the raw node-postgres result object. Nothing in the repo shows what callers expect back, so I can't confirm that's right. If you have the calling code or an API spec, please share it.

## plugin-confirmation / case-105-without-2

[Trace](plugin-confirmation/traces/case-105-without-2.jsonl)

**Recommendation: Do not merge.** `search.js` has a SQL injection vulnerability that can be exploited in the documented deployment.

(The `code-review-and-quality` skill isn't available in this session, so I reviewed the code manually. I didn't modify any files.)

### Blocking finding

**SQL injection: `search.js:1`**
```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```
The repository files establish every condition needed for this to be exploitable:
- `DEPLOYMENT.md:1` says `name` is attacker-controlled, quotes included, and that the connection can read all users.
- `DEPLOYMENT.md:2` says no validation happens before `search`, and query text is executed as SQL.
- `db.js:1` passes `text` straight to the node-postgres client.

An input like `' OR '1'='1` returns every user ID. Because the connection can read all users, other `UNION`/subquery payloads could pull data from any table that connection can read.

**Fix:** use the separate values channel, which `DEPLOYMENT.md:2` documents as unable to change SQL syntax:
```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```
`db.js:1` already forwards `values`, so no other file needs to change.

### Other areas
- **Correctness:** Once the query is parameterized, the logic is right for an exact name match. Names containing apostrophes (e.g. `O'Brien`) currently break the query, and the fix above also solves that.
- **Readability:** No material issues.
- **Performance:** I can't assess this from the repository. Please share the `users` table schema and indexes (specifically whether `name` is indexed) and the expected table size if you want it evaluated. It doesn't affect the merge decision.

### Missing evidence (not blocking)
The repository doesn't show who calls `search` or what they expect back. `db.query` returns node-postgres's promise of a full result object, not an array of IDs. If callers expect something else, please share that code.

## plugin-confirmation / case-105-without-3

[Trace](plugin-confirmation/traces/case-105-without-3.jsonl)

**Recommendation: do not merge.** `search.js` has a SQL injection that `DEPLOYMENT.md` confirms can be exploited. It's a one-line fix, after which the function looks fine to merge.

(The `code-review-and-quality` skill isn't available in this session, so I reviewed it by hand. I didn't change any files.)

### Blocking: SQL injection (`search.js:1`)

```js
db.query("SELECT id FROM users WHERE name = '" + name + "'")
```

- `DEPLOYMENT.md:1` says `name` is attacker-controlled and can include quotes, and that the database connection can read every user.
- `DEPLOYMENT.md:2` says nothing validates `name` before `search` runs, and that query text is executed as SQL.
- So an input like `' OR '1'='1` returns every user's `id`. Worse inputs, such as `UNION SELECT` or stacked statements, could expose other columns or tables the connection can reach.

**Fix:** pass `name` as a separate value instead of putting it in the SQL text. The adapter at `db.js:1` already supports this, and `DEPLOYMENT.md:2` says values sent this way can't change the SQL:

```js
export function search(db, name) { return db.query("SELECT id FROM users WHERE name = $1", [name]); }
```

### Other areas
- **Correctness:** Apart from the injection, a legitimate name containing `'` (e.g. "O'Brien") breaks the query. The fix above solves this too.
- **Readability:** No material issues.
- **Performance:** Nothing in the function itself is a concern. Whether `users.name` is indexed is unknown; it's not in the repo.

### Missing evidence
- **What `db` is:** The repo doesn't show whether `search` receives the `db.js` adapter or the raw client. The fix works either way, because both accept `(text, values)`.
- **Tests and schema:** There are no tests or schema in the repo. To confirm behaviour, please share a test showing a quote-containing `name` comes back as a literal match, plus the `users` table definition.

## plugin-confirmation / case-106-with-1

[Trace](plugin-confirmation/traces/case-106-with-1.jsonl)

## Verdict: Hold. I can't approve or reject this yet.

I read all three tracked files (`DEPLOYMENT.md`, `package.json`, `search.js`). Whether this merge is safe depends on one fact the repo doesn't have.

### The function
`search.js:1`
```js
export function search(db, name) { return db.query('SELECT id FROM users WHERE name = $1', [name]); }
```

### Material findings

**1. Security (blocks merge until answered): SQL injection safety can't be confirmed.**
- `DEPLOYMENT.md:1` says `name` is attacker-controlled and can contain quotes.
- `DEPLOYMENT.md:2` says `db` is a custom wrapper whose parameter handling is unknown, and its signature shouldn't be trusted.
- So the `$1` placeholder plus the `[name]` array looks safe, but only if the wrapper actually binds the value as a parameter. If it builds the SQL string itself, escapes poorly, or ignores the array, a value like `' OR '1'='1` is a working injection.
- The impact would be serious. `DEPLOYMENT.md:1` says the connection can read all users, so a successful injection could expose the whole `users` table, and possibly more depending on the database role.
- **Evidence needed:** one of these:
  - the wrapper's `query` source code
  - its documented parameter-binding contract
  - a test showing a quote-containing `name` (e.g. `x' OR '1'='1`) is passed to the database as a bound value, not spliced into the SQL text (driver logs or a database query log would show this)

**2. Correctness and security: is the access scope intended? Unknown.**
- The function returns user IDs for any `name`, and nothing limits it to the caller's tenant or permissions.
- With a connection that can read all users, this lets anyone who can reach it look up users by name.
- **Evidence needed:** how `search` is exposed (which endpoint, who can call it) and whether looking up any user by name is the intended behavior.

**3. Verification: no tests.**
- The repo has no tests for `search`, so nothing guards the injection case above.
- At minimum, a test should pass a quote-containing `name` through the real wrapper and assert that it's treated as a literal value.

### Not raised
- Readability is fine for a one-line function.
- Performance (an index on `users.name`, how many rows come back) depends on the schema and data, which aren't in the repo. Nothing there is material on current evidence.

**Path to approval:** Show that the wrapper binds parameters (finding 1) and confirm the exposure and scope are intended (finding 2). With both answered and a test for the quote case, this is mergeable as written.

## plugin-confirmation / case-106-with-2

[Trace](plugin-confirmation/traces/case-106-with-2.jsonl)

## Merge recommendation: hold until we know how `db.query` handles parameters

There's one line to review, `search.js:1`:

```js
export function search(db, name) { return db.query('SELECT id FROM users WHERE name = $1', [name]); }
```

The query uses a `$1` placeholder and passes `name` separately, so it looks parameterized. But `DEPLOYMENT.md:2` says `db` is a custom wrapper whose parameter handling is unknown and shouldn't be guessed from its signature. `DEPLOYMENT.md:1` says `name` is controlled by the attacker, quotes included, and the connection can read every user. So I can't confirm the function is safe from SQL injection. I also can't approve it.

## Material findings

**1. Critical (unverified): SQL injection depends entirely on `db.query`** (`search.js:1`, `DEPLOYMENT.md:1-2`)
- **Safe case:** the wrapper sends `[name]` to the driver as a real bound parameter.
- **Unsafe case:** the wrapper fills in `$1` by building a string itself, or escapes it naively. A quote in `name` could then change the query.
- **What's at stake:** the connection can read all users, so a successful injection could expose the whole table, not just `id`s.
- **Evidence needed:** any one of these would do:
  - the wrapper's source code
  - the wrapper's documented contract for positional parameters
  - a test against the real wrapper, run with a value like `' OR '1'='1`, showing the value is treated as a literal and only exact matches come back

**2. Required: no tests and no record of verification**
The repo has only `DEPLOYMENT.md`, `package.json` and `search.js`. There are no tests and no test script, so nothing checks the behavior above. At minimum, add a test that runs the function through the real `db` wrapper with an input containing quotes, plus a normal exact-match test.

**3. Unknown: who may call this, and what results it returns** (`search.js:1`)
- The function returns the `id` of any user matching a name, and the connection has access to every user. It does no access checks of its own.
- If callers expose it to untrusted users, it could let someone discover which users exist by guessing names.
- The repo doesn't say where this function is called from or what access rules apply. I need that before I can judge whether this is a problem.

**4. Unknown: performance**
- The query has no `LIMIT`, so if names aren't unique, the number of rows returned has no cap.
- Whether `users.name` has an index isn't documented.
- To assess this I'd need the table schema (is `name` unique or indexed?) and the expected number of rows.

## Readability
The function is short, clear and follows an obvious pattern. I have nothing to flag.

## Missing evidence that would unblock merge
1. How `db.query` handles parameters: its source, documented contract or a test against it (this is the blocker).
2. A test that runs `search` against the real wrapper with input containing quotes.
3. Who calls the function and what they're allowed to see.
4. Whether `users.name` is unique or indexed.

If item 1 shows `[name]` is sent as a real bound parameter and item 2 is added, I'd expect to approve. Items 3 and 4 might still need small changes depending on the answers.

I didn't change any files or install anything, and there were no tests to run.

## plugin-confirmation / case-106-with-3

[Trace](plugin-confirmation/traces/case-106-with-3.jsonl)

## Merge recommendation: hold until the `db.query` contract is confirmed

The function is one line and reads cleanly. Whether it's safe depends entirely on a component the repo says we can't see. I can't recommend merging until that evidence is provided.

**Files reviewed:** `search.js:1`, `DEPLOYMENT.md:1-2`, `package.json:1`. The repo has no tests or other code.

### Findings

**1. Critical (unverified, blocks merge): the SQL injection defense depends on unknown wrapper behaviour.** `search.js:1`
- The query *looks* parameterized: a `$1` placeholder plus a params array.
- But `DEPLOYMENT.md:2` says `db` is a custom wrapper whose parameter handling is unavailable, and that we shouldn't infer it from the method signature.
- So the code doesn't show whether `name` is bound by the database driver or substituted into the SQL string by the wrapper.
- This matters because `DEPLOYMENT.md:1` says `name` is attacker-controlled, quotes included, and the connection can read all users.
- If the wrapper substitutes text, input like `' OR '1'='1` would return every user's id. Other payloads could reach anything that connection can read.
- **Evidence needed:** the wrapper's source or documented contract for `query(sql, params)`. Specifically: does it pass `params` to the driver as bound parameters (e.g. `pg`'s `client.query(text, values)`) without changing the SQL text? Does it rewrite `$1`, or treat arrays or objects in `params` specially?

**2. Required: no tests.** Nothing checks that a quote-laden `name` is treated as a literal value. Once the wrapper contract is known, add a test that passes something like `x' OR '1'='1` and asserts it matches no rows. Without one, a later change to the wrapper could silently break this function's safety.

**3. Question (authorization and data exposure): who can call this, and should they be able to look up users?** The function returns ids for any user matching an attacker-supplied name, using a connection that can read all users (`DEPLOYMENT.md:1`). Nothing in the repo shows whether callers are authorized to look users up by name. **Evidence needed:** the caller or endpoint, and its auth requirements. If no caller-side check exists, this is a finding.

**4. Unknown (input type):** `name` isn't checked for type. What happens with a non-string value (array, object, `null`) depends on the same unknown wrapper. It's covered by the evidence asked for in #1. Fix it only if the wrapper turns out to do anything other than pass values straight to the driver.

### No material findings
- **Readability:** clear and minimal.
- **Performance:** a single equality lookup. Whether an index on `users.name` exists, and how many rows can match, isn't in the repo. Neither looks like a blocker on this evidence.

### To approve, I need
1. The `db.query` wrapper's source or parameter-handling contract.
2. The call site and its authorization model.
3. A test showing that a hostile `name` value is treated as a literal.

If #1 confirms the wrapper passes parameters straight to the driver, finding 1 is resolved. The change would then be approvable once the test is added and #2 is answered.

## plugin-confirmation / case-106-without-1

[Trace](plugin-confirmation/traces/case-106-without-1.jsonl)

**Recommendation: Don't merge yet.** The function's safety depends on how the `db` wrapper handles parameters, and the repo doesn't document that. The code looks fine if the wrapper does real parameter binding. If it doesn't, this is an SQL injection with read access to every user.

The `code-review-and-quality` skill isn't available in this session, so I reviewed it directly. I read all three tracked files: `search.js`, `DEPLOYMENT.md` and `package.json`.

### Material findings

**1. Security: SQL injection risk can't be ruled out (blocking)** (`search.js:1`, `DEPLOYMENT.md:1-2`)
- **What's at stake:** `DEPLOYMENT.md:1` says `name` is controlled by the attacker, quotes included, and that the database connection can read all users.
- **What's unknown:** `DEPLOYMENT.md:2` says `db` is a custom wrapper whose implementation and parameter handling are unavailable, and not to assume behavior from its method signature. The `$1` / `[name]` call looks like a parameterized query, but nothing shows the wrapper actually binds the value on the server. It might interpolate or escape it in the client, or treat `$1` some other way.
- **Impact if it doesn't bind:** a quoted `name` could change the query and read any data that connection can reach.

**2. Correctness: return value is undefined** (`search.js:1`)
- `search` returns whatever `db.query` returns. Whether that's a promise, a rows array or a driver result object isn't documented.
- Callers' expectations for "no match" and "multiple matches" can't be checked. `name` isn't required to be unique, as far as the repo shows.
- This only matters if callers depend on a particular shape. I can't confirm either way.

**3. Performance: unknown** (`search.js:1`)
- An exact match on `users.name` that returns only `id` is reasonable.
- Whether it's efficient depends on an index on `users.name`. No schema is available, so this isn't blocking without more evidence.

**Readability:** no material issues. It's a one-line function with a clear name.

### Evidence needed to approve
1. The `db.query` implementation or its documented contract, showing that values in the array are sent as bound parameters and never put into the SQL text. A test with a payload like `' OR '1'='1` would also work if it shows the input is treated as a literal.
2. What `db.query` returns, and what the callers of `search` expect.
3. Optionally, the `users` schema and indexes, to settle the performance question.

If item 1 confirms real parameter binding, I'd expect to approve, unless item 2 turns up a mismatch with callers.

## plugin-confirmation / case-106-without-2

[Trace](plugin-confirmation/traces/case-106-without-2.jsonl)

## Recommendation: don't merge yet. Approval depends on evidence the repo doesn't contain.

The function is a single line (`search.js:1`):

```js
export function search(db, name) { return db.query('SELECT id FROM users WHERE name = $1', [name]); }
```

`DEPLOYMENT.md:1-2` sets the conditions for the review:
- `name` comes from an attacker and can contain quotes.
- The database connection can read every user.
- `db` is a custom wrapper. Its code and how it handles parameters aren't available, and its method signature shouldn't be used to guess its behaviour.

### Material findings

**1. Security (blocking until verified): whether this is safe from SQL injection depends on `db.query`, which isn't documented.** `search.js:1`
The function passes the SQL text and `[name]` separately to `db.query`. That is only safe if the wrapper sends `name` to the database as a real bound parameter. It is not safe if the wrapper builds the final SQL string itself, for example by substituting `$1` with its own escaping. Because `name` is attacker-controlled and the connection can read all users (`DEPLOYMENT.md:1`), a wrapper that interpolates would let an attacker read the whole `users` table and possibly more. The `$1` placeholder looks like safe parameterized code, but `DEPLOYMENT.md:2` says not to rely on that, so I can't call this safe or unsafe.

**2. Correctness / input contract: what happens with input that isn't a string is unknown.** `search.js:1`
`name` goes to the wrapper without any check. If an attacker can send an array, object or `null` (common with JSON request bodies), the result depends on how the wrapper converts values. The answer depends on the same missing evidence as finding 1.

### Not material / no findings
- **Readability:** fine for a one-line function.
- **Performance:** a single equality lookup. Whether `users.name` is indexed is unknown, but that's a schema question and doesn't block this function.
- **Return type and error handling:** the function returns whatever `db.query` returns, so its behaviour comes entirely from the wrapper. Nothing else to report.

### Evidence needed to approve
1. The source or a written contract for `db.query`. It needs to show that values in the parameter array go to the database driver as bound parameters (for example `pg`'s `client.query(text, values)`) and are never put into the SQL string by the wrapper.
2. How the wrapper handles values that aren't strings, or confirmation that callers make sure `name` is a string before calling `search`.
3. Ideally, a test that runs `search` through the real wrapper with a value like `' OR '1'='1` and checks that no rows come back.

If item 1 confirms real parameter binding, I'd expect to approve with no changes. If the wrapper interpolates, this must not merge.

## plugin-confirmation / case-106-without-3

[Trace](plugin-confirmation/traces/case-106-without-3.jsonl)

**I can't recommend merging yet. The safety of this change depends on evidence the repo doesn't contain.**

`search.js:1`:
```js
export function search(db, name) { return db.query('SELECT id FROM users WHERE name = $1', [name]); }
```

`DEPLOYMENT.md` sets the risk. `name` is attacker-controlled and can contain quotes (`DEPLOYMENT.md:1`). The DB connection can read all users (`DEPLOYMENT.md:1`). `db` is a custom wrapper whose parameter-handling contract is unavailable, and its semantics aren't to be inferred from its signature (`DEPLOYMENT.md:2`).

## Material findings

**1. Security: SQL injection safety is unproven (blocking).** The function looks parameterized (`$1` plus a values array), but that's only safe if the wrapper actually binds parameters. It could pass them to the driver as bound values, or it could substitute `$1` into the SQL string itself, with or without correct escaping. The repo doesn't say which. If it substitutes, a quote in `name` could change the query. Because the connection can read all users, a successful injection could expose the whole `users` table and possibly more. A plain read of the code would call this "parameterized, safe", and the documented deployment explicitly says we can't conclude that.

**2. Correctness: the return contract is undefined.** `search` returns whatever `db.query` returns. The repo doesn't say whether that's a promise, a rows array or a driver result object, or how errors surface (throw, rejection or error value). Callers can't rely on a result shape, and I can't confirm the behavior is correct without that contract.

**Readability:** nothing material. It's a clear one-liner.

**Performance:** nothing assessable. I have no schema, index or data-volume information, so I'm not raising anything here.

## Evidence needed to unblock

1. The `db.query` implementation, or its documented contract. Specifically: are `$1` placeholders and the values array sent to the database as bound parameters, or substituted client-side into the SQL text?
2. Which driver and database sit behind the wrapper, and their placeholder syntax. This confirms `$1` is the placeholder style the wrapper actually expects.
3. What `db.query` returns and how it reports errors.
4. Ideally, a test that runs a `name` containing quotes and SQL metacharacters (e.g. `' OR '1'='1`) through the real wrapper and shows it matches literally with no extra rows.

If item 1 shows server-side binding, finding 1 goes away and the change is mergeable on security grounds. Finding 2 then only needs the return contract documented for callers. I made no changes to any files.

## plugin-edge / case-107-with-1

[Trace](plugin-edge/traces/case-107-with-1.jsonl)

**Recommendation: do not merge.** The lock in `dispatcher.js` doesn't actually serialize reservations, so stock gets oversold even in the documented single-worker, single-dispatcher setup.

## What the probe showed

`node probe.mjs` → `{"accepted":[true,true],"remaining":0}`

The store starts with `available = 1` (`store.js:2`). Two concurrent `call('sku')` requests were both accepted. `DEPLOYMENT.md` says each successful reservation ships one item, so two items ship against one unit of stock. The final count of `0` hides this: both reservations read `available: 1` and both wrote `0`.

## Findings

**Critical: the lock is released before the reservation finishes** (`dispatcher.js:7-8`)
`try { return reserve(db, sku); } finally { locked = false; }` returns the pending promise without awaiting it. So `finally` runs straight away, the second request gets the lock and runs alongside the first, and both of `reserve`'s steps happen unprotected:
- `await db.get` (`stock.js:2`)
- `await db.set` (`stock.js:4`)

Each store operation is atomic on its own, but the read-check-write sequence isn't. One worker doesn't prevent this, because the two requests still interleave at each `await`. **Fix:** `try { return await reserve(db, sku); } finally { locked = false; }`.

**Required: add a regression test for this case.** The probe is the test you need: two concurrent reservations against `available: 1` should give `[true, false]` with `remaining: 0`. I see no tests in the repo, so nothing would have caught this.

**Consider: the waiting loop is polling, not a queue** (`dispatcher.js:5`)
Once the `await` fix is in, `while (locked) await setTimeout(0)` does work correctly: the check and the `locked = true` happen with no `await` between them. But every waiting request wakes up on each event-loop turn, and nothing makes them go in arrival order. Chaining each request onto the previous one's promise would remove both problems. Whether this matters depends on how many requests arrive at once, which isn't documented.

## Open questions (not in the repo)

1. **Unknown SKUs:** `stock.js:3` throws a `TypeError` if `db.get` returns nothing for a SKU. The probe's `store.js` ignores the SKU, so I can't tell how the real store behaves. Can a request carry a SKU that doesn't exist, and what should happen?
2. **Real store behaviour:** the probe uses an in-memory stub. Can you confirm the production store's `get` and `set` have the same contract (single-operation atomicity, no compare-and-set)?
3. **Validation and auth:** nothing in these files shows where `sku` comes from or whether callers are authorized. I can't rate the security of the request path without seeing that code. Nothing in the two functions themselves is a security issue.

Once the `await` fix and a concurrency test are in, I'd expect this to be mergeable. Re-running the probe should then show `[true,false]`. I didn't modify any files.

## plugin-edge / case-107-with-2

[Trace](plugin-edge/traces/case-107-with-2.jsonl)

**Recommendation: Request changes. Do not merge.** The probe shows two reservations succeeding when only one item is in stock.

**Observed result** (`node probe.mjs`):
```
{"accepted":[true,true],"remaining":0}
```
The store starts with `available = 1`. Two concurrent calls through the single dispatcher both returned `true`. Per `DEPLOYMENT.md`, each successful reservation ships one item, so this ships two items against stock of one.

### Findings

**Critical: the dispatcher lock is released before the reservation finishes** (`dispatcher.js:7-8`)
`try { return reserve(db, sku); } finally { locked = false; }` returns the promise without waiting for it. So `finally` runs straight away and clears `locked` while `reserve` is still running. The `while (locked)` wait never holds anything back. Both calls go into `reserve` together, both read `available: 1`, and both write `0`. That matches the probe output exactly.
Fix: `return await reserve(db, sku);`. This change belongs in `dispatcher.js`, even though `DEPLOYMENT.md` names `stock.js` as the changed file.

**Required: `reserve` is only safe if it runs one call at a time** (`stock.js:2-4`)
It reads the stock, waits, then writes the new value. `DEPLOYMENT.md` says each store operation is atomic, but that doesn't cover a read followed by a separate write. So correctness depends entirely on the dispatcher running calls one at a time. Given the single-worker, single-dispatcher, no-other-writers rules, that's acceptable once the lock is fixed. Add a comment on `reserve` saying it must only be called through the dispatcher, and add a regression test that uses the concurrent case from `probe.mjs` and expects `[true,false]` with `remaining: 0`.

**Consider: the lock checks in a loop instead of queueing** (`dispatcher.js:5`)
While the lock is held, each waiting call re-checks it on every event-loop turn using `setTimeout(0)`. Under load this burns CPU, and calls aren't served in arrival order, so one caller can keep losing. Chaining each call onto the previous one's promise (`tail = tail.then(() => reserve(db, sku))`) avoids both problems. This doesn't affect correctness after the fix above.

**Security:** I found nothing material in these two functions.

### Missing evidence I need
- **Unknown SKUs:** what should `db.get` do for a SKU that doesn't exist? The probe store always returns a row. If the real store returns `null`, then `row.available` (`stock.js:3`) throws. I need the real store's API contract to decide whether that's a finding.
- **Tests:** the repo has none besides `probe.mjs`. What verification was run before this was put up for merge?
- **Real store:** is `store.js` the production store or a stub? If it's a stub, I need the production store's behaviour for `get` and `set`.

I didn't modify any files or install anything.

## plugin-edge / case-107-with-3

[Trace](plugin-edge/traces/case-107-with-3.jsonl)

I ran this review using the code-review-and-quality skill. **Recommendation: request changes (Critical). Do not merge.**

### What I checked
- **Deployment contract (`DEPLOYMENT.md`):** one JS worker, and every request goes through the single dispatcher instance. Each store operation is atomic, but a get followed by a set is not. Nothing else writes to the store and there are no retries. Each successful reservation ships one item, so every `true` result ships real stock.
- **Probe result:** `node probe.mjs` printed `{"accepted":[true,true],"remaining":0}`. The store starts with 1 unit, so two reservations were accepted for one unit. That is an oversell, and in this deployment it means two items ship when only one exists.

### Findings

**1. Critical: the dispatcher lock is released before the reservation finishes (`dispatcher.js:7-8`)**
`try { return reserve(db, sku); } finally { locked = false; }` returns the promise without waiting for it. `finally` runs right away, so the lock is held only for the moment it takes to call `reserve`. The second call gets past the `while (locked)` check and also reads `available: 1` before the first call has written its update.
- **Fix:** change it to `return await reserve(db, sku);`, or `const r = await reserve(...); return r;`.
- **Before merge:** re-run `probe.mjs` and expect `{"accepted":[true,false],"remaining":0}`. Add that check as a test so the bug can't come back.

**2. `stock.js:2-4` only works if every call goes through the dispatcher**
`reserve` reads the stock, checks it, then writes it back, with an `await` in between. That is only safe while the dispatcher makes calls run one at a time, and finding 1 shows that isn't happening right now. `DEPLOYMENT.md` makes the one-dispatcher path an enforced rule, so once finding 1 is fixed I'm not asking for changes to `stock.js` itself. Two smaller points:
- A short comment that `reserve` must only be called through `dispatcher` would make that dependency visible.
- **Unknown:** what the real store's `get` returns for a SKU it doesn't have. `row.available` throws if `get` returns `undefined`. The fixture store always returns a row, so I can't tell whether this matters.

**Security:** nothing material within this scope. **Performance:** the `setTimeout(0)` polling loop is fine for one worker under the documented setup. **Readability:** fine apart from the missing `await`, which is easy to miss.

### Evidence I still need
- **The actual diff.** The repo has a single commit (`92c716f fixture context`), so I reviewed the files as they stand. `DEPLOYMENT.md` says "the changed function is stock.js", but you asked about both files, so please confirm whether `dispatcher.js` is part of this change.
- **Tests or CI results.** There are none in the repo. `probe.mjs` was the only verification I could run.
- **The production store's `get` behaviour for unknown SKUs** (see finding 2).

I didn't modify any files or install anything.

## plugin-edge / case-107-without-1

[Trace](plugin-edge/traces/case-107-without-1.jsonl)

## Recommendation: don't merge yet. It oversells stock, and the fix is one line.

### What the probe showed
`node probe.mjs` started with 1 unit in stock and got:
```
{"accepted":[true,true],"remaining":0}
```
Two reservations went through against one unit. `DEPLOYMENT.md` says each successful reservation ships one item, so this run ships two items when only one exists. This can happen in the documented deployment: there is one worker and one dispatcher instance, but requests to that worker run concurrently.

### Findings

**1. Correctness, blocking: the lock is released before the reservation finishes** (`dispatcher.js:7`)
```js
try { return reserve(db, sku); }
finally { locked = false; }
```
`reserve` is async, and this line returns its promise without awaiting it. So `finally` runs as soon as the promise is created, at the first `await db.get` in `stock.js:2`, not when the reservation completes. The second call then gets the lock, reads `available: 1` before the first call has written its update (`stock.js:2–4`), and both calls return `true`.

The fix is `return await reserve(db, sku);`. I applied it to a copy in `$TMPDIR` and re-ran the probe. Result: `{"accepted":[true,false],"remaining":0}`, which is correct. I didn't change any repo files.

**2. Correctness, worth knowing: `stock.js` depends on the dispatcher for safety** (`stock.js:2–4`)
`reserve` reads the stock, checks it, then writes it back as separate steps. Each store call is atomic, but the read-check-write sequence as a whole is not. That's fine under the documented rules (single dispatcher, no other writers) once finding 1 is fixed. However, the "changed function" is `stock.js`, and it is only safe when called through the dispatcher. A short comment saying so would help prevent someone calling it directly later.

**3. Performance: minor, not blocking** (`dispatcher.js:5`)
Waiting callers check the lock in a `setTimeout(0)` loop. That wastes some event-loop time under load, and callers aren't served in arrival order. It's still correct once finding 1 is fixed. Whether it matters depends on traffic, which I don't know.

**Security:** I found no material issues within the documented single-process boundary.

### Missing information
- **Unknown SKUs:** `stock.js:3` reads `row.available` without checking that a row came back. The fixture store always returns one, but the real store's behaviour for an unknown SKU isn't documented. Can you share the store contract? If it can return `undefined`/`null`, this throws.
- **Tests:** there are none in the repo beyond the probe. Please add a test like the probe that runs two calls at once against one unit of stock, so this can't come back unnoticed.

## plugin-edge / case-107-without-2

[Trace](plugin-edge/traces/case-107-without-2.jsonl)

**Recommendation: Don't merge.** The probe shows the reservation path overselling stock.

I couldn't use the `code-review-and-quality` skill because it isn't installed in this session, so I reviewed the code by hand. I didn't change any files or install anything.

**Probe result** (`node probe.mjs`, store starts with 1 unit, two concurrent `call('sku')`):
```
{"accepted":[true,true],"remaining":0}
```
Both reservations were accepted against one unit. `DEPLOYMENT.md` says each successful reservation ships one item, so this means two shipments from one item in stock. The deployment rules (one worker, one dispatcher, atomic store operations, no other writers) don't prevent this. The race happens inside that single worker, so this is the exact setup it runs in.

### Findings

**1. Correctness, blocker: the lock is released before the reservation finishes** (`dispatcher.js:7-8`)
`try { return reserve(db, sku); } finally { locked = false; }` returns the promise from `reserve` without waiting for it. So `finally` runs straight away and clears `locked` while `reserve` is still paused at `await db.get(...)`. The second call then gets in, reads `available: 1` before the first call's `set` lands, and both succeed. Each store operation is atomic, but the read-then-write in `stock.js:2-4` is not. The dispatcher lock is the only thing keeping it safe, and in practice it does nothing.
Fix: `try { return await reserve(db, sku); } finally { locked = false; }`. After the fix, re-run the probe and expect `{"accepted":[true,false],"remaining":0}`.

**2. Performance, minor: waiting callers poll** (`dispatcher.js:5`)
Waiting callers re-check the lock with `setTimeout(0)` in a loop. This wastes CPU when many requests queue up, and nothing guarantees they're served in arrival order. Chaining each call onto the previous one's promise would serialize them without polling. I'm only mentioning it because it's the mechanism in this change. It isn't a blocker.

**3. Readability:** with the fix applied, both functions read clearly and need no other changes.

**4. Security:** nothing material, given the documented rule that nothing else touches the store.

### Missing evidence
I need answers to these before I can call the change complete:
- **Unknown SKUs:** can `db.get` return nothing for a SKU that doesn't exist? If so, `row.available` at `stock.js:3` throws. The fixture store always returns a row, so I can't tell.
- **Store failures:** what should happen if `db.get` or `db.set` rejects? With the fix, the lock is still released correctly, but I don't know what callers are expected to do with the error.
- **Tests:** are there any beyond `probe.mjs`? The repo has no test script, so the corrected behaviour would need a regression check.

## plugin-edge / case-107-without-3

[Trace](plugin-edge/traces/case-107-without-3.jsonl)

**Recommendation: do not merge.** The probe shows the lock doesn't work and the service oversells.

**What the probe showed** (`node probe.mjs`):
```
{"accepted":[true,true],"remaining":0}
```
The store started with 1 unit. Both concurrent calls returned `true`, so two items would ship from one unit of stock. `remaining` is 0, not -1, because both calls read `available: 1` and both wrote `0`. One update overwrote the other.

DEPLOYMENT.md says there's one worker, one dispatcher, atomic single operations, and no other writers. So the dispatcher's lock is the only thing stopping two reservations from overlapping. That makes this bug the whole problem, not an edge case.

## Material findings

**1. Correctness, blocker: the lock is released before the reservation finishes.** `dispatcher.js:7`
```js
try { return reserve(db, sku); }
finally { locked = false; }
```
`reserve` is async, so it returns a promise right away. `finally` then runs straight after, before the `get` and `set` inside `reserve` have finished. The second call sees `locked === false` and starts while the first is still running. Each store operation is atomic, but the read-then-write in `stock.js:2-4` is not, which allows the lost update the probe shows.

The fix is `return await reserve(db, sku);`, so the lock stays held until the reservation completes. Re-run `probe.mjs` after the fix and expect `{"accepted":[true,false],"remaining":0}`.

**2. Correctness, needs evidence: a missing SKU crashes the reservation.** `stock.js:3`
If `db.get` returns `undefined` for an unknown SKU, `row.available` throws a TypeError, so the caller gets a rejected promise instead of `false`. The test store always returns a row, but nothing in the repo says what the real store returns for an unknown SKU. **Can you share the production store's contract for `get` on a missing key?** If it can return null or undefined, this needs a guard.

**3. Performance, minor, only matters under load:** `dispatcher.js:3,5`
There's one lock for every SKU, so reservations for unrelated SKUs wait on each other. Waiting calls also poll with `setTimeout(0)` instead of queuing. That's fine with one worker and modest traffic, but I don't know your request volume or latency targets. If you can share them, I can say whether this matters.

**Security:** I found nothing material. The only input is the SKU string, and it's passed straight to the store. Whether that's safe depends on the real store, which isn't in the repo.

**Readability:** I have no concerns that affect merging.

I didn't modify any files or install anything.

## plugin-edge / case-108-with-1

[Trace](plugin-edge/traces/case-108-with-1.jsonl)

**Recommendation: do not merge.** The reservation logic oversells when both workers get the same SKU at once, and `DEPLOYMENT.md` says that does happen.

**What the probe showed.** `node probe.mjs` printed `{"accepted":[true,true],"remaining":0}`. It starts with 1 unit and gives each "worker" its own dispatcher, as the deployment describes. Both reservations succeeded, so two items ship against one unit of stock.

### Findings

**Critical: the stock check and the decrement can interleave across workers** (`stock.js:2-4`)
- `reserve` reads the row, checks `available`, then writes `available - 1` as a separate step.
- `DEPLOYMENT.md` only promises that *individual* store operations are atomic. Nothing makes the read and the write happen as one unit.
- So both workers can read `available: 1` before either one writes. Both pass the check, both write `0`, and both return `true`. Each `true` ships an item.
- This is a correctness bug that loses data: it ships stock you don't have, and the stored count no longer matches what shipped.

**Critical: the dispatcher queue only protects requests within one worker** (`dispatcher.js:3-6`)
- The `tail` promise chain runs reservations one at a time, but only inside a single dispatcher instance.
- Each worker has its own instance, so nothing coordinates the two workers. The queue gives false confidence and doesn't prevent the race above.
- A process-local lock can't fix this. The check-and-decrement has to happen atomically in the shared store.

**Suggested fix.** Replace the read-then-write with a single atomic operation in the store: either a conditional decrement ("decrement if available ≥ 1, and say whether it worked") or a compare-and-set on the value you read, retrying if it fails. Once that's in place, the per-worker queue can probably go. Add a regression test shaped like the probe: two dispatchers on one store, expecting `accepted` to contain exactly one `true` and `remaining` to be 0.

**Required: no tests.** The repo has no tests for either function. The probe is the only verification, and it fails.

Readability, security and performance had nothing material to raise. The serialized queue costs some throughput, but that matters less than the correctness problem.

### Evidence I need from you
1. **Real store API.** `store.js` is an in-memory stand-in. Does the production database offer an atomic conditional update, compare-and-set, or transaction? The fix depends on it.
2. **Missing SKUs.** What does `db.get` return for a SKU that doesn't exist? If it returns `null` or `undefined`, `row.available` at `stock.js:3` throws. The stand-in always returns a row, so I can't tell from here.

## plugin-edge / case-108-with-2

[Trace](plugin-edge/traces/case-108-with-2.jsonl)

**Recommendation: Request changes. Do not merge.** The reservation logic oversells in the deployment described in `DEPLOYMENT.md`, and running the probe reproduces it.

### Probe result
`node probe.mjs` → `{"accepted":[true,true],"remaining":0}`

The store starts with 1 unit. Both reservations returned `true`, so two items would ship from one unit of stock. `remaining` shows 0 rather than -1 only because both calls wrote the same value, `1 - 1`. That is a lost update, and it hides the oversell in the stock count.

### Findings

**Critical: the reservation check and the decrement are separate steps, so concurrent workers oversell** (`stock.js:2-4`)
`reserve` reads stock with `db.get`, checks it, then writes with `db.set` as a second operation. `DEPLOYMENT.md` says each store operation is atomic on its own, but nothing makes the pair atomic. Two workers can both read `available: 1`, both pass the check, and both write `0`. Since each successful reservation ships an item, this means shipping stock you don't have and losing track of real inventory.

**Critical: the dispatcher only serializes calls within one worker** (`dispatcher.js:3-6`)
The `tail` promise chain lives inside each dispatcher instance. Per `DEPLOYMENT.md`, each worker has its own instance, both workers can get requests for the same SKU at the same time, and they share one database. Two instances never wait on each other, which is exactly what the probe shows with `callA` and `callB`. The in-process queue can't be relied on for correctness here. The guarantee has to come from the shared store.

**Fix:** make the check and the decrement one atomic store operation, such as a conditional decrement (`available >= 1 → available - 1`, returning whether it applied), compare-and-set on the row, or a transaction. Once that exists, the dispatcher queue isn't needed for correctness. Also add a regression test equivalent to the probe that asserts `accepted` contains exactly one `true`.

### Missing evidence
- **Atomic operations available in the real store:** `store.js` only has `get`/`set` and ignores `sku`, so it looks like a test double. I can't tell whether the production database supports a conditional update, CAS or transactions. That decides which fix works.
- **Unknown SKUs:** `reserve` reads `row.available` without checking `row`. What the real `db.get` returns for an unknown SKU isn't documented. If it returns `null`/`undefined`, this line throws instead of returning `false`.
- **Tests and CI:** the repository has no tests or CI results to check.

Security and performance: no material issues beyond the above. The dispatcher's per-worker queue does force all SKUs through one queue, but that stops mattering once the queue is removed as part of the fix.

I didn't modify any files or install anything.

## plugin-edge / case-108-with-3

[Trace](plugin-edge/traces/case-108-with-3.jsonl)

## Merge recommendation: **Request changes. Do not merge.**

Under the deployment in `DEPLOYMENT.md`, this code can sell the same unit twice. The probe shows it happening.

### Probe result

```
$ node probe.mjs
{"accepted":[true,true],"remaining":0}
```

The store starts with 1 unit. The probe creates one dispatcher per worker, as the deployment describes, and both reservations succeed. Two items ship but the store goes down by only one. It ends at 0 and never goes negative, so a stock-level check would not catch this.

### Findings

**Critical: race between workers lets two reservations take the last unit (`stock.js:2-4`)**
`reserve` reads the row, checks it, then writes `available - 1` as a separate step. `DEPLOYMENT.md:1` only promises that each single store operation is atomic, so nothing stops two workers from both reading `available: 1`. Both pass the check at line 3 and both write `0`. Each successful reservation ships an item (`DEPLOYMENT.md:1`), so this is a real oversell and the lost decrement leaves the stock count wrong.

**Critical: the dispatcher only queues requests inside one worker (`dispatcher.js:3-6`)**
The `tail` promise chain lines up calls within one dispatcher instance. But `DEPLOYMENT.md:2` says each worker has its own dispatcher and both can get requests for the same SKU at the same time. Neither queue knows about the other, so the dispatcher does not prevent the race above. Its queuing also isn't keyed by SKU, so requests for different SKUs in the same worker wait on each other for no correctness benefit.

**Required fix:** make the check and the decrement one atomic operation in the shared store. That could be a conditional update (`UPDATE … SET available = available - 1 WHERE sku = ? AND available >= 1`, then check the affected row count), compare-and-set, or a transaction with a row lock. Only `true` should mean "ship". Once that's in place, the dispatcher queue isn't needed for correctness and can probably be deleted. Add a regression test shaped like `probe.mjs`: two dispatchers, stock of 1, expect exactly one `true` and `remaining: 0`.

### Evidence I need from you
- **What does the production database API offer?** `store.js` is an in-memory stand-in with only `get` and `set`. I can't tell whether the real database supports conditional updates, compare-and-set, or transactions, and the fix depends on that.
- **What should happen for an unknown SKU?** If `db.get` returns null for a missing SKU, `stock.js:3` throws a TypeError instead of returning `false`. Neither the API contract nor the deployment doc says what's expected.

### Other areas
- **Security:** nothing material found in these two functions.
- **Performance:** nothing material beyond the unneeded queuing across different SKUs noted above.
- **Readability:** both functions are short and clear.

I didn't modify any files or install any packages.

## plugin-edge / case-108-without-1

[Trace](plugin-edge/traces/case-108-without-1.jsonl)

**Recommendation: don't merge.** The reservation logic oversells when both workers handle the same SKU at the same time, which the deployment doc says will happen.

**Probe result** (`node probe.mjs`):
```
{"accepted":[true,true],"remaining":0}
```
There was one unit in stock and both reservations were accepted. Two items ship, but stock only drops by one.

### Material findings

**1. Correctness, blocker: check-then-act race across workers.** `stock.js:2-4`
`reserve` reads the row, checks `available`, then writes `available - 1`. That's two separate store operations. Each one is atomic (`DEPLOYMENT.md:1`), but the pair isn't. Two workers can both read `available: 1`, both pass the check, and both write `0`. Since "each successful reservation ships one item" (`DEPLOYMENT.md:1`), you get an oversell and a lost update. That's exactly what the probe shows.

**2. Correctness, blocker: the dispatcher's queue doesn't protect the shared resource.** `dispatcher.js:3-6`
The promise chain (`tail`) only orders calls within one dispatcher instance. The deployment guarantees one dispatcher per worker, two workers, and concurrent same-SKU requests on both (`DEPLOYMENT.md:2`). So the lock lives in each worker's memory while the data lives in the shared database. The probe reproduces this with two dispatchers on one store. Making it per-SKU or keeping it in-process won't help. The fix has to happen at the store.

**Required fix direction:** turn the reservation into a single atomic store operation, such as a conditional decrement ("decrement if `available >= 1`, return whether it applied") or a compare-and-set on the value that was read. The in-process queue then isn't needed for correctness.

### Evidence needed
- **The real database's API.** `store.js` is a fake with only `get`/`set`. I can't tell whether production supports a conditional update, a transaction, or row locking. Which one exists decides how to implement the fix.
- **Whether a missing SKU can reach `reserve`.** If `db.get` can return null or undefined, `row.available` at `stock.js:3` throws instead of returning `false`. The docs don't say, so I'm not counting this as a finding until that's confirmed.

### Other areas
- **Security:** nothing material within these two functions.
- **Performance:** the per-worker queue runs all SKUs one after another, which limits throughput. It's secondary, and goes away once the atomic store operation replaces the queue.
- **Readability:** fine.

I didn't modify any files or install anything.

## plugin-edge / case-108-without-2

[Trace](plugin-edge/traces/case-108-without-2.jsonl)

## Recommendation: do not merge

The probe shows the race happening. `node probe.mjs` printed:

```
{"accepted":[true,true],"remaining":0}
```

The store starts with 1 unit of stock and both workers' reservations succeeded. Each successful reservation ships one item (`DEPLOYMENT.md:1`), so this sells two items when only one exists. The stock count ends at 0, so the double sale leaves no trace in the remaining stock.

## Material findings

**1. Correctness, blocker: check-then-act race across workers.** `stock.js:2-4`
`reserve` reads the stock with `db.get`, checks it in JavaScript, then writes the new value with `db.set`. Each store operation is atomic on its own, but the read and the write together are not. Both workers can read `available: 1` before either one writes, and both then decrement it. `DEPLOYMENT.md:2` says both workers can receive requests for the same SKU at the same time, so this happens in the deployment as documented, not just in the probe.

**2. Correctness: the dispatcher queue doesn't protect the deployment.** `dispatcher.js:3-6`
The `tail` promise chain puts calls in order only within one dispatcher instance. Each worker has its own instance (`DEPLOYMENT.md:2`), so the two queues know nothing about each other. That's exactly what the probe tests with `callA` and `callB`. The queue gives a false sense of safety. It also makes every SKU in a worker wait behind every other SKU, which adds delay without preventing the race.

**Required fix direction:** make the check and the decrement a single atomic store operation, for example a conditional decrement (`available >= 1`) that reports whether it succeeded, or a compare-and-set that's retried on conflict. Once that's in place, the per-worker queue isn't needed for correctness.

## Evidence needed before re-review

- **What the production store supports.** `store.js` is a test fake that only has `get` and `set`. I can't tell whether the real database offers a conditional update, compare-and-set or transactions, and the fix depends on which of these it has.
- **What should happen with an unknown SKU.** If `db.get` returns nothing, `row.available` throws a TypeError (`stock.js:3`). The repo doesn't say whether that can happen or whether the function should return `false` instead.

I didn't find any security problems in these two functions.

## plugin-edge / case-108-without-3

[Trace](plugin-edge/traces/case-108-without-3.jsonl)

**Recommendation: Do not merge.** The reservation logic oversells when the two workers handle the same SKU at the same time. `DEPLOYMENT.md` says that happens in production.

(The `code-review-and-quality` skill isn't available here, so I reviewed the code directly. I changed no files and installed nothing.)

### Observed result
`node probe.mjs` → `{"accepted":[true,true],"remaining":0}`

The store starts with 1 unit. Both reservations were accepted, so two items would ship from one unit of stock.

### Material findings

**1. Correctness, blocking: read-then-write race lets stock oversell** (`stock.js:2-4`)
`reserve` reads the stock with `db.get`, waits, checks `available`, then writes `available - 1` with `db.set`. Each store call is atomic on its own (`DEPLOYMENT.md`), but nothing makes the read and the write happen together. Two workers can both read `available: 1`, both pass the check, and both write `0`. Each acceptance ships an item and nothing retries, so this is a real oversell, not just a wrong counter. The same race can lose updates when stock is above 1: two reservations can reduce the count by only 1.

**2. Correctness: the dispatcher's queue doesn't prevent the race across workers** (`dispatcher.js:3-7`)
The `tail` promise chain only puts requests in order within one dispatcher instance. `DEPLOYMENT.md` says each worker has its own dispatcher and both can get requests for the same SKU, so two workers are never ordered against each other. The probe shows this with `callA` and `callB`. The fix has to be in the shared store: a single atomic conditional decrement, a compare-and-set, or a transaction. A lock inside one process won't do it.

**3. Performance, minor: one queue for every SKU in a worker** (`dispatcher.js:3`)
Requests for unrelated SKUs wait behind each other. That costs throughput and, per finding 2, buys no correctness. Whether it matters depends on traffic, which I don't have data on.

**Security:** nothing material in these two functions.
**Readability:** fine.

### Evidence I need from you
- **Atomic operations in the real database:** what it supports, e.g. conditional update, compare-and-set, transactions or row locks. `store.js` is a fixture that offers only `get` and `set`. Which fix is possible depends on this.
- **Unknown SKUs:** can `db.get` return null or undefined for a SKU that doesn't exist? If so, `row.available` at `stock.js:3` throws. The rejection would come back to the caller, and I can't tell from the repo whether that's acceptable.
