#!/bin/bash
# Fetch budget data from obudget.org API and save as JSON
# Runs in GitHub Actions (no CORS issues from server-side)

set -euo pipefail

YEAR="${1:-$(( $(date +%Y) - 1 ))}"
OUTPUT="budget-data.json"
API="https://next.obudget.org/api/query"

echo "Fetching budget data for year ${YEAR}..."

# Try to get all items, sorted by size
SQL="select code,title,net_revised,net_allocated from budget_items_data where year=${YEAR} order by net_revised desc limit 300"
URL="${API}?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SQL}'))")&page_size=300"

HTTP_CODE=$(curl -s -o /tmp/budget_raw.json -w "%{http_code}" "${URL}")

if [ "$HTTP_CODE" != "200" ]; then
  echo "API returned HTTP ${HTTP_CODE}, trying without limit..."
  SQL="select code,title,net_revised,net_allocated from budget_items_data where year=${YEAR} order by net_revised desc"
  URL="${API}?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SQL}'))")"
  curl -sf "${URL}" -o /tmp/budget_raw.json || { echo "API failed entirely"; exit 0; }
fi

# Process with Python: pick the right hierarchy level
python3 -c "
import json, sys

with open('/tmp/budget_raw.json') as f:
    data = json.load(f)

rows = data.get('rows', data if isinstance(data, list) else [])
if not rows:
    print('No rows returned')
    sys.exit(0)

# Group by code length (without dots)
by_length = {}
for r in rows:
    code = (r.get('code') or '').replace('.', '')
    length = len(code)
    if length not in by_length:
        by_length[length] = []
    by_length[length].append(r)

print(f'Code lengths found: {[(l, len(items)) for l, items in sorted(by_length.items())]}')

# Find code length with largest total = ministry level
best_len = None
best_total = 0
for length, items in by_length.items():
    total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
    if total > best_total:
        best_total = total
        best_len = length

if best_len is None or best_total < 100e9:
    print(f'No valid ministry level found (best: {best_total/1e9:.1f}B)')
    sys.exit(0)

items = by_length[best_len]
total_nis = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)

result = {
    'year': ${YEAR},
    'totalNIS': total_nis,
    'totalB': round(total_nis / 1e9, 1),
    'items': sorted([{
        'name': r.get('title', ''),
        'amountNIS': r.get('net_revised') or r.get('net_allocated') or 0,
        'amountB': round((r.get('net_revised') or r.get('net_allocated') or 0) / 1e9, 1),
    } for r in items if (r.get('net_revised') or r.get('net_allocated') or 0) > 0],
    key=lambda x: -x['amountNIS']),
    'source': 'obudget',
    'fetchedAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'codeLength': best_len,
}

print(f'Budget {${YEAR}}: {result[\"totalB\"]}B NIS, {len(result[\"items\"])} items (code length={best_len})')

with open('${OUTPUT}', 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
print(f'Saved to ${OUTPUT}')
"

if [ -f "${OUTPUT}" ]; then
  echo "Budget data saved successfully"
  cat "${OUTPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Total: {d[\"totalB\"]}B NIS, {len(d[\"items\"])} items')"
else
  echo "No budget data file created (API may be unavailable)"
fi
