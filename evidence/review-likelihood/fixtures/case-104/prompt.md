---
max_turns: 16
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, Bash]
---

If the code-review-and-quality skill is available, invoke it for this review. I want a code review across correctness, readability, security and performance before merging the new search.js function. Read the repository files to establish the relevant deployment and API contracts. Review only this function and its behavior in the documented deployment. Do not modify files or install packages. Facts not present are unknown: ask for the missing evidence where necessary. Give a concise merge recommendation and material findings with file references. Avoid unrelated optional improvements.
