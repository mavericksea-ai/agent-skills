# Review-likelihood fixtures and evidence

Supporting evidence for the [prevented-failure fixture discussion on PR #441](https://github.com/addyosmani/agent-skills/pull/441#discussion_r4172973250). These are synthetic review tasks, not defects discovered in this repository.

Eight filesystem-backed cases were exercised through the actual Claude Code plugin workflow: **48 completed agent runs, with three trials per case both with and without the plugin**. All four behavioral criteria passed in both arms. This supplies tested regression fixtures; it does **not** demonstrate a skill advantage or establish that PR #441 is ready to merge.

## Start here

- [Case 102: a queue that genuinely prevents overlapping reservations](fixtures/case-102/fixture.sh)
- [Case 107: a lock released before the promise settles](fixtures/case-107/fixture.sh)
- [Case 108: separate worker queues do not coordinate shared stock](fixtures/case-108/fixture.sh)
- [All 48 final answers, with trace links](answers.md)
- [Six-case results and grader votes](plugin-confirmation/runs.json) · [Two additional cases](plugin-edge/runs.json)
- [Executable probe results](fixture-checks.json) · [Edge cases](edge-fixture-checks.json) · [The one-line `return await` fix](early-release-fix-check.json)

| Case | Contract to distinguish | With plugin | Without plugin |
|---|---|---:|---:|
| 101 | One async worker, overlapping requests: reachable oversell | 3/3 pass | 3/3 pass |
| 102 | Exclusive queue held across awaits: prevented oversell | 3/3 pass | 3/3 pass |
| 103 | Dispatcher behavior unavailable: reachability unverified | 3/3 pass | 3/3 pass |
| 104 | Specified node-postgres parameter binding: injection prevented | 3/3 pass | 3/3 pass |
| 105 | Attacker-controlled SQL concatenation: injection reachable | 3/3 pass | 3/3 pass |
| 106 | Custom query wrapper unavailable: binding unverified | 3/3 pass | 3/3 pass |
| 107 | `finally` releases a lock before the returned promise settles | 3/3 pass | 3/3 pass |
| 108 | Correct queues in separate workers over one shared store | 3/3 pass | 3/3 pass |

Every final prompt explicitly asks to invoke `code-review-and-quality` if available. It fired in **24/24 plugin-enabled runs**. This measures behavior when requested, not natural routing accuracy. Native skill-activation checks are unscored; each run's score comes from the four behavioral criteria. Each LLM criterion received three judge votes, preserved in the results.

The concurrent probe in case 107 accepts two reservations against one item. Changing only `return reserve(db, sku)` to `return await reserve(db, sku)` inside its `try/finally` makes the same probe accept one. Case 108 models independent worker queues using two dispatcher instances over a shared in-memory store; it is not a multiprocess database integration test. The SQL cases specify driver contracts, without connecting to a live database.

## What was run

| Component | Pinned value |
|---|---|
| Full plugin, final 48 runs | `addyosmani/agent-skills` at `1be8e34187e34647bb83adc3a1323b26ae6f6abe` |
| Claude Code | `2.1.296` |
| Executor | `claude-opus-5-5` |
| Native plugin judge | `claude-opus-4-6` |
| Trials | Three per case per arm, concurrency three |
| Run groups | Cases 101–106 and cases 107–108 in separate native invocations |
| Reported list-price cost | $63.275745 + $24.5410264 = **$87.8167714** for these 48 runs |

The full-plugin runs used the pinned upstream plugin, **not PR #441's proposed skill revision**. A separate native Tier-3 check ran the six original dialogue fixtures against the base skill (`7829ffd90d973b6325f5f12f1b1226dcace74443`) and proposed skill (`33d0ef21b98f2166309b9adc38bec0bd86dbb35f`). All six scored 4/4 in each revision. The [native fixture patch](native-fixtures.patch) and [base](native/base/grading)/[proposed](native/head/grading) grading evidence are included. Those dialogue cases prohibit tools and are distinct from the filesystem-backed plugin cases above.

A preceding 12-run pilot, excluded from the table, exposed a mistake in our grader: requiring the `Read` tool penalized valid file reads through `Bash`. It also invoked the skill in 0/6 plugin-enabled runs on natural requests. We changed the rubric, explicitly requested the skill, and advanced the pinned plugin snapshot for the final experiment; this is not a controlled attribution of activation gains to wording alone. The original pilot remains retained locally.

The tested fixtures here are unchanged. Two useful wording clarifications for a future PR are to permit temporary probe files while prohibiting edits to the repository, and to make the case 107/108 deployment description explicitly name both reviewed files. Neither clarification is represented as already tested in these results.

## Reproduce

For the deterministic probes, Node.js, Git and Python 3 are sufficient:

```sh
python3 evidence/review-likelihood/verify-fixtures.py
```

For a new paid native evaluation, use an isolated checkout at the pinned upstream commit above, Claude Code 2.1.296, and your normal authentication. Copy this package's `fixtures/` directory to `evals/review-likelihood-pilot/` in that checkout, then run:

```sh
claude plugin eval . \
  --eval-dir evals/review-likelihood-pilot \
  --model claude-opus-5-5 --judge-model claude-opus-4-6 \
  --runs 3 --concurrency 3 --max-cost-usd 120 \
  --scaffold --allow-tools Bash --trust-plugin --no-publish --keep-temp \
  --output-dir /tmp/review-likelihood-new-results \
  --json /tmp/review-likelihood-new-results/results.json
```

This combines the two original groups into one eight-case run. The original groups used budgets of $85 and $30 respectively. The CLI checks its cost limit between runs, so in-flight calls can exceed it. Review the scaffold scripts before allowing execution. Repeated model runs can produce different answers and grades.

## Optional Driftproof export

The unchanged public Driftproof 0.19.0 importer successfully preserved all case/arm score arrays from the final native results. Existing imported receipts are included under each group's `driftproof/` directory, byte for byte.

For a freshly generated native result:

```sh
npx driftproof@0.19.0 import /tmp/review-likelihood-new-results/results.json \
  --from claude-plugin-eval --out /tmp/review-likelihood-receipts
```

Import makes no model calls. Its `DECLARED` provenance and `NOT_MEASURED` summary are the importer's intentional distinction from execution attested by Driftproof itself. Hash validation checks receipt integrity, not independent execution attestation. This is an optional reporting command; it does not change the fixtures or native runner.

## Publication and evidence integrity

The public results are explicitly labeled **projections**, not original native `results.json` files. All case definitions, per-run grades, judge votes, costs and completion flags are preserved. Repeated embedded trace strings are replaced with links to the published traces.

Published traces retain assistant/user text, tool requests, tool results and final result events. System initialization events, reasoning blocks, request/session metadata and local machine paths are omitted or redacted. Tool identifiers remain to connect requests to their results. Original raw records remain local and unchanged. Use [publication-provenance.json](publication-provenance.json) for original-versus-published SHA-256 digests and transformations, and [manifest.json](manifest.json) for this package's file digests. These hashes detect changes; they do not independently prove who executed a run. The projected results are not offered as native-import inputs.
