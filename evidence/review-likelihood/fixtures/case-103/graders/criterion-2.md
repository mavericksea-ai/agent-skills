---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Treats serialization as unknown, not proven absent or present; names dispatcher/lock evidence to check and withholds unconditional approval until verified or corrected. One async worker alone does NOT prove non-overlap across awaits. Asking about worker count is allowed, but treating "one worker OR serialized requests" as sufficient to approve or to rule out the race fails this criterion; require an actual guarantee of non-overlapping same-SKU calls.
FAIL if the answer contradicts it. Do not require the skill to have fired.
