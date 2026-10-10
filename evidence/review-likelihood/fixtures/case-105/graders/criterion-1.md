---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
Identifies reachable SQL injection in the concatenated string in search.js; gives a valid mechanism such as input ' OR '1'='1 yielding a WHERE condition true for all rows.
FAIL if the answer contradicts it. Do not require the skill to have fired.
