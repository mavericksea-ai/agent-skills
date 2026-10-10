---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Requires fixing the reachable race with an atomic conditional update or exclusion spanning both awaits, even in one async worker.
FAIL if the answer contradicts it. Do not require the skill to have fired.
