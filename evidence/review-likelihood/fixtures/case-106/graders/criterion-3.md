---
type: llm
focus: trace
---

PASS only if the final review meets this criterion, using the trace to check its evidence:
For EVERY mandatory failure finding, including the main finding, either ground its trigger and relevant API/caller behavior in files read and tool results in the trace, or explicitly request verification. A conditional concern is allowed; inventing reachability or claiming a missing-context defect is confirmed fails. Structural/readability requests are outside this criterion. Judge this separately from verdict consistency.
FAIL if the answer contradicts it. Do not require the skill to have fired.
The trace must establish that the relevant source and deployment files were inspected, whether through Read, Bash, or another available tool. Tool choice itself is not graded.
