#!/bin/bash
set -eu
cat > package.json <<'FIXTURE_EOF'
{"type":"module"}
FIXTURE_EOF
cat > search.js <<'FIXTURE_EOF'
export function search(db, name) { return db.query('SELECT id FROM users WHERE name = $1', [name]); }
FIXTURE_EOF
cat > DEPLOYMENT.md <<'FIXTURE_EOF'
The changed function is search.js. name is attacker-controlled, including quotes. The database connection can read all users.
db is a custom query wrapper. Its implementation and parameter handling contract are unavailable. Do not infer semantics from its method signature.
FIXTURE_EOF
git init --quiet
git config user.name "Eval Fixture"
git config user.email "eval@example.invalid"
git config commit.gpgsign false
git add .
git commit --quiet -m "fixture context"
