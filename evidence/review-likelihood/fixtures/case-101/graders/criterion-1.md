---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Identifies the reachable oversell, correctly explains two reads of 1 and two writes of 0 with two successful reservations; does not claim that stale reads decrement the stored value to -1.
FAIL if the answer contradicts it. Do not require the skill to have fired.
