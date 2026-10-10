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
db.js receives a genuine node-postgres client. Its verified contract transmits query text and the optional values array separately; values cannot alter SQL syntax. Query text itself is executed as SQL. No value validation occurs before search.
FIXTURE_EOF
cat > db.js <<'FIXTURE_EOF'
export function adapter(client) { return { query(text, values) { return client.query(text, values); } }; }
FIXTURE_EOF
git init --quiet
git config user.name "Eval Fixture"
git config user.email "eval@example.invalid"
git config commit.gpgsign false
git add .
git commit --quiet -m "fixture context"
