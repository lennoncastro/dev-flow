Show the status of all DevFlow runs in this repository.

Read all JSONL files under `.devflow/runs/` (or the path configured in `telemetry.path`) and produce a summary table.

```bash
TELEMETRY_DIR=".devflow/runs"
if [ -f ".devflow.yaml" ]; then
  CONFIGURED=$(yq e '.telemetry.path // ""' .devflow.yaml 2>/dev/null || \
    grep -E '^  path:' .devflow.yaml | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
  [ -n "$CONFIGURED" ] && TELEMETRY_DIR="$CONFIGURED"
fi

if [ ! -d "$TELEMETRY_DIR" ] || [ -z "$(ls -A "$TELEMETRY_DIR" 2>/dev/null)" ]; then
  echo "No DevFlow runs found in ${TELEMETRY_DIR}."
  exit 0
fi

for file in "$TELEMETRY_DIR"/*.jsonl; do
  run_id=$(basename "$file" .jsonl)
  last_event=$(tail -1 "$file")
  event=$(echo "$last_event" | jq -r '.event // "unknown"')
  ts=$(echo "$last_event" | jq -r '.ts // "unknown"')
  status=$(echo "$last_event" | jq -r '.status // "-"')
  echo "Run: ${run_id} | Last event: ${event} | Status: ${status} | At: ${ts}"
done
```

For each run, show:
- Run ID
- Last recorded event (start / phase / stop / fail)
- Status if present
- Timestamp of last event

Format as a readable list or table.
