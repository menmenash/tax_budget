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

# Strategy: fetch from 'budget' table at depth=2, EXCLUDE income items (code '00%')
# net_revised includes supplementary budgets (תקציב מתוקן)
queries = [
    ("budget depth=2 (expenditure)",
     "select code,title,net_revised,net_allocated from budget where year={year} and depth=2 and code not like '00%' and net_revised > 0 order by net_revised desc"),
    ("budget depth=1 (expenditure)",
     "select code,title,net_revised,net_allocated from budget where year={year} and depth=1 and code not like '00%' and net_revised > 0 order by net_revised desc"),
    ("budget_items_data",
     "select code,title,net_revised,net_allocated from budget_items_data where year={year} and net_revised > 0 order by net_revised desc"),
]

# Fetch all supported years
current_year = int("${YEAR}")
years = list(range(current_year, 2020, -1))  # current year down to 2021
success_count = 0

for year in years:
    print(f"\n{'='*40}")
    print(f"Fetching year {year}...")
    found = False

    for qname, sql_tmpl in queries:
        sql = sql_tmpl.format(year=year)
        print(f"  Trying {qname}...")
        rows = fetch(sql)

        if not rows:
            print(f"    0 rows")
            continue

        # Extra safety: filter out income items
        rows = [r for r in rows if not (r.get('code') or '').replace('.', '').startswith('00')]
        print(f"    {len(rows)} expenditure rows")

        # Group by code length to find best hierarchy level
        by_len = {}
        for r in rows:
            code = (r.get('code') or '').replace('.', '')
            l = len(code)
            if l not in by_len: by_len[l] = []
            by_len[l].append(r)

        best_len, best_total = None, 0
        for l in sorted(by_len.keys()):
            items = by_len[l]
            total = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in items)
            print(f"      len={l}: {len(items)} items, {total/1e9:.1f}B")
            if total > best_total:
                best_total, best_len = total, l

        if not best_len or best_total < 200e9:
            print(f"    Total {best_total/1e9:.1f}B < 200B threshold")
            continue

        selected = by_len[best_len]
        total_nis = sum(r.get('net_revised') or r.get('net_allocated') or 0 for r in selected)

        # Build items, splitting large supplements (>5B) into separate lines
        SUPP_THRESHOLD = 5e9
        items = []
        for r in selected:
            revised = r.get('net_revised') or 0
            allocated = r.get('net_allocated') or 0
            amount = revised or allocated
            if amount <= 0: continue
            title = r.get('title', '')
            supplement = revised - allocated

            if allocated > 0 and supplement >= SUPP_THRESHOLD:
                items.append({
                    'name': title,
                    'amountNIS': allocated,
                    'amountB': round(allocated / 1e9, 1),
                })
                items.append({
                    'name': f'תוספת תקציבית — {title}',
                    'amountNIS': supplement,
                    'amountB': round(supplement / 1e9, 1),
                    'supp': True,
                })
            else:
                items.append({
                    'name': title,
                    'amountNIS': amount,
                    'amountB': round(amount / 1e9, 1),
                })
        items.sort(key=lambda x: -x['amountNIS'])

        result = {
            'year': year,
            'totalNIS': total_nis,
            'totalB': round(total_nis / 1e9, 1),
            'items': items,
            'source': 'obudget',
            'fetchedAt': datetime.utcnow().isoformat() + 'Z',
        }

        filename = f"budget-data-{year}.json"
        print(f"  SUCCESS: {result['totalB']}B NIS, {len(items)} items -> {filename}")
        for item in items[:3]:
            print(f"    {item['name']}: {item['amountB']}B")

        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
        success_count += 1
        found = True
        break  # Got data for this year, move to next

    if not found:
        print(f"  No valid data for {year}")

print(f"\nDone: {success_count}/{len(years)} years fetched.")
PYEOF

echo ""
echo "=== Files created ==="
ls -la budget-data-*.json 2>/dev/null || echo "No budget-data files created"
