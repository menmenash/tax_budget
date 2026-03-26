#!/bin/bash
# Fetch budget data from obudget.org API and save as JSON
# Runs in GitHub Actions (server-side, no CORS issues)

set -euo pipefail

YEAR="${1:-$(( $(date +%Y) - 1 ))}"
OUTPUT="budget-data.json"
API="https://next.obudget.org/api/query"

echo "=== Fetching budget data for year ${YEAR} ==="

# Function to query the API
query_api() {
  local sql="$1"
  local label="$2"
  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$sql")
  local url="${API}?query=${encoded}&page_size=500"

  echo ""
  echo "--- ${label} ---"
  echo "SQL: ${sql}"

  local tmpfile="/tmp/budget_query_${RANDOM}.json"
  local http_code
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" "$url") || { echo "curl failed"; return 1; }

  if [ "$http_code" != "200" ]; then
    echo "HTTP ${http_code}"
    head -c 200 "$tmpfile" 2>/dev/null
    echo ""
    return 1
  fi

  local row_count
  row_count=$(python3 -c "
import json
with open('$tmpfile') as f: data=json.load(f)
rows=data.get('rows', data if isinstance(data,list) else [])
print(len(rows))
" 2>/dev/null) || { echo "JSON parse failed"; return 1; }

  echo "Rows: ${row_count}"

  # Analyze the data
  python3 -c "
import json

with open('$tmpfile') as f:
    data = json.load(f)
rows = data.get('rows', data if isinstance(data, list) else [])

if not rows:
    print('No rows')
    exit(0)

# Show sample
print(f'Sample: code={rows[0].get(\"code\")}, title={rows[0].get(\"title\")}, net_revised={rows[0].get(\"net_revised\")}')

# Group by code length
by_len = {}
for r in rows:
    code = (r.get('code') or '').replace('.', '')
    l = len(code)
    if l not in by_len: by_len[l] = []
    by_len[l].append(r)

for l in sorted(by_len.keys()):
    items = by_len[l]
    total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
    print(f'  len={l}: {len(items)} items, {total/1e9:.1f}B NIS')
    # Show first 3 items
    for item in items[:3]:
        print(f'    {item.get(\"code\")} | {item.get(\"title\")} | {(item.get(\"net_revised\") or 0)/1e9:.1f}B')
"
  echo "$tmpfile"
}

# Try many strategies to find the right query
echo ""
echo "========================================="
echo "STRATEGY 1: budget table, all depths (500 rows)"
echo "========================================="
query_api "select code,title,depth,net_revised,net_allocated from budget where year=${YEAR} and net_revised > 0 order by net_revised desc" "All items sorted by size"
# Save the latest query result for the build step
ls -t /tmp/budget_query_*.json 2>/dev/null | head -1 | xargs -I{} cp {} /tmp/budget_strategy1.json 2>/dev/null || true

echo ""
echo "========================================="
echo "STRATEGY 2: budget table, code like '00__' (4-char ministry codes)"
echo "========================================="
RESULT2=$(query_api "select code,title,net_revised,net_allocated from budget where year=${YEAR} and code like '00__' and net_revised > 0 order by net_revised desc" "4-char codes starting with 00")

echo ""
echo "========================================="
echo "STRATEGY 3: budget table, code like '____' (any 4-char codes)"
echo "========================================="
query_api "select code,title,net_revised,net_allocated from budget where year=${YEAR} and code like '____' and net_revised > 0 order by net_revised desc limit 50" "Any 4-char codes"

echo ""
echo "========================================="
echo "STRATEGY 4: budget_items_data table"
echo "========================================="
query_api "select code,title,net_revised,net_allocated from budget_items_data where year=${YEAR} and net_revised > 0 order by net_revised desc limit 50" "budget_items_data"

echo ""
echo "========================================="
echo "STRATEGY 5: budget table depth=0"
echo "========================================="
query_api "select code,title,net_revised,net_allocated from budget where year=${YEAR} and depth=0 order by net_revised desc" "depth=0"

echo ""
echo "========================================="
echo "STRATEGY 6: budget table with func_cls_title_1"
echo "========================================="
query_api "select func_cls_title_1,sum(net_revised) as total from budget where year=${YEAR} and depth=2 group by func_cls_title_1 order by total desc" "Functional classification"

echo ""
echo "========================================="
echo "STRATEGY 7: budget table code = '00' (root item)"
echo "========================================="
query_api "select code,title,net_revised,net_allocated from budget where year=${YEAR} and code='00'" "Root item code=00"

echo ""
echo "========================================="
echo "BUILDING OUTPUT"
echo "========================================="

# The 'budget' table contains INCOME items (taxes, bonds), NOT expenditure.
# The 'budget_items_data' table should contain expenditure but is empty for 2025.
# Only create budget-data.json from budget_items_data (expenditure).
# If empty, skip — the browser will use the hardcoded fallback.

python3 << PYEOF
import json, urllib.request, urllib.parse, sys
from datetime import datetime

API = "https://next.obudget.org/api/query"

def fetch(sql):
    url = f"{API}?query={urllib.parse.quote(sql)}&page_size=500"
    try:
        with urllib.request.urlopen(url) as resp:
            data = json.loads(resp.read())
        return data.get('rows', data if isinstance(data, list) else [])
    except Exception as e:
        print(f"  Fetch error: {e}")
        return []

# Try budget_items_data for multiple years (2025, 2024, 2023)
for year in [${YEAR}, ${YEAR}-1, ${YEAR}-2]:
    print(f"Trying budget_items_data year={year}...")
    rows = fetch(f"select code,title,net_revised,net_allocated from budget_items_data where year={year} and net_revised > 0 order by net_revised desc")

    if not rows:
        print(f"  0 rows for {year}")
        continue

    print(f"  {len(rows)} rows for {year}")

    # Group by code length
    by_len = {}
    for r in rows:
        code = (r.get('code') or '').replace('.', '')
        l = len(code)
        if l not in by_len: by_len[l] = []
        by_len[l].append(r)

    for l in sorted(by_len.keys()):
        items = by_len[l]
        total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
        print(f"    len={l}: {len(items)} items, {total/1e9:.1f}B")

    # Pick the code length where total is 400-900B (reasonable for Israeli expenditure budget)
    best_len, best_total = None, 0
    for l, items in by_len.items():
        total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
        if 200e9 < total < 1000e9 and total > best_total:
            best_total, best_len = total, l

    if not best_len:
        # Just pick the largest
        for l, items in by_len.items():
            total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
            if total > best_total: best_total, best_len = total, l

    if not best_len or best_total < 50e9:
        print(f"  No valid expenditure data for {year}")
        continue

    selected = by_len[best_len]

    # Verify it's expenditure (should NOT have "מס הכנסה" or "מלוות" as top items)
    top_titles = ' '.join(r.get('title', '') for r in selected[:5])
    if 'מס הכנסה' in top_titles or 'מלוות' in top_titles or 'מע"מ' in top_titles:
        print(f"  WARNING: looks like income data, not expenditure. Skipping.")
        continue

    total_nis = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in selected)
    items = sorted([{
        'name': r.get('title', ''),
        'amountNIS': r.get('net_revised') or r.get('net_allocated') or 0,
        'amountB': round((r.get('net_revised') or r.get('net_allocated') or 0) / 1e9, 1),
    } for r in selected if (r.get('net_revised') or r.get('net_allocated') or 0) > 0],
    key=lambda x: -x['amountNIS'])

    result = {
        'year': year,
        'totalNIS': total_nis,
        'totalB': round(total_nis / 1e9, 1),
        'items': items,
        'source': 'obudget',
        'fetchedAt': datetime.utcnow().isoformat() + 'Z',
    }

    print(f"\nSUCCESS: year={year}, {result['totalB']}B NIS, {len(items)} items")
    for item in items[:5]:
        print(f"  {item['name']}: {item['amountB']}B")

    with open('budget-data.json', 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print("Saved to budget-data.json")
    sys.exit(0)

print("\nNo expenditure data found in budget_items_data for any year.")
print("Browser will use hardcoded fallback data.")
PYEOF

if [ -f "${OUTPUT}" ]; then
  echo ""
  echo "=== SUCCESS ==="
  python3 -c "import json; d=json.load(open('${OUTPUT}')); print(f'Total: {d[\"totalB\"]}B NIS, {len(d[\"items\"])} items')"
else
  echo ""
  echo "=== FAILED - no output file ==="
fi
