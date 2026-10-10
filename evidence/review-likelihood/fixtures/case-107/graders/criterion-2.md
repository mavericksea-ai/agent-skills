---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Requires a fix before merge: hold the lock through the entire asynchronous operation (for example return await inside try/finally), or use another actually atomic reservation mechanism. A process-local lock can suffice under this one-worker exclusive-access deployment if correctly held.
FAIL if the answer contradicts it. Do not require the skill to have fired.
