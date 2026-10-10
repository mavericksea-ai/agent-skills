"""Recheck synthetic fixture oracles locally; no model calls or network access."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EXPECTED = {101: [True, True], 102: [True, False], 107: [True, True], 108: [True, True]}
for case in sorted((ROOT / 'fixtures').iterdir()):
    number = int(case.name.split('-')[-1])
    with tempfile.TemporaryDirectory(prefix='likelihood-fixture-') as directory:
        subprocess.run(['bash', str(case / 'fixture.sh')], cwd=directory, check=True, capture_output=True)
        if number in EXPECTED:
            def probe():
                result = subprocess.run(['node', 'probe.mjs'], cwd=directory, check=True, capture_output=True, text=True)
                return json.loads(result.stdout)
            result = probe()
            assert result == {'accepted': EXPECTED[number], 'remaining': 0}, (case.name, result)
            if number == 107:
                dispatcher = Path(directory) / 'dispatcher.js'
                source = dispatcher.read_text()
                assert source.count('return reserve(db, sku);') == 1
                dispatcher.write_text(source.replace('return reserve(db, sku);', 'return await reserve(db, sku);'))
                assert probe() == {'accepted': [True, False], 'remaining': 0}
        print(f'{case.name}: setup and applicable oracle checks passed')
