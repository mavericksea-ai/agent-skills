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
This service has two JavaScript workers sharing one database. Each successful reservation ships one item. Individual store operations are atomic. No retries or other stock writers exist. The changed function is stock.js.
Each worker has its own dispatcher instance. Every request uses its worker's dispatcher. Both workers can receive requests for the same SKU concurrently; no other paths access the shared store. These are enforced deployment invariants.
FIXTURE_EOF
cat > dispatcher.js <<'FIXTURE_EOF'
import {reserve} from './stock.js';
export function dispatcher(db) {
  let tail = Promise.resolve();
  return sku => {
    const result = tail.then(() => reserve(db, sku));
    tail = result.then(() => undefined, () => undefined);
    return result;
  };
}
FIXTURE_EOF
cat > probe.mjs <<'FIXTURE_EOF'
import {store} from './store.js';
import {dispatcher} from './dispatcher.js';
const db=store(); const callA=dispatcher(db); const callB=dispatcher(db);
console.log(JSON.stringify({accepted:await Promise.all([callA('sku'),callB('sku')]),remaining:db.value()}));
FIXTURE_EOF
git init --quiet
git config user.name "Eval Fixture"
git config user.email "eval@example.invalid"
git config commit.gpgsign false
git add .
git commit --quiet -m "fixture context"
