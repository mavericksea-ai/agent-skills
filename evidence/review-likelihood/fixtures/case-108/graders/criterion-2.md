---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Requires a fix before merge that coordinates all workers, such as a database atomic conditional decrement/transaction with appropriate concurrency guarantees, or shared exclusion. Merely adding another process-local queue is not sufficient.
FAIL if the answer contradicts it. Do not require the skill to have fired.
