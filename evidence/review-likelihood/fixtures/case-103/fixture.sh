#!/bin/bash
set -eu
cat > package.json <<'FIXTURE_EOF'
{"type":"module"}
FIXTURE_EOF
cat > stock.js <<'FIXTURE_EOF'
export async function reserve(db, sku) {
  const row = await db.get(sku);
  if (row.available < 1) return false;
  await db.set(sku, {available: row.available - 1});
  return true;
}
FIXTURE_EOF
cat > store.js <<'FIXTURE_EOF'
export function store() {
  let available = 1;
  return { async get() { return {available}; }, async set(sku, row) { available = row.available; }, value() { return available; } };
}
FIXTURE_EOF
cat > DEPLOYMENT.md <<'FIXTURE_EOF'
This service has one JavaScript worker. Each successful reservation ships one item. Individual store operations are atomic. No retries or other stock writers exist. The changed function is stock.js.
Dispatcher code and request scheduling configuration are unavailable. Whether calls overlap is unknown. Worker count alone does not document scheduling.
FIXTURE_EOF
git init --quiet
git config user.name "Eval Fixture"
git config user.email "eval@example.invalid"
git config commit.gpgsign false
git add .
git commit --quiet -m "fixture context"
