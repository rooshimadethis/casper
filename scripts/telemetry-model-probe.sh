#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${TELEMETRY_PROBE_DERIVED_DATA:-$ROOT_DIR/.deriveddata}"
OUTPUT_FILE="${TELEMETRY_PROBE_OUTPUT:-$ROOT_DIR/scripts/output/telemetryprobe/output.txt}"
SAMPLE_FILE="$HOME/Library/Application Support/Casper/telemetry/events/telemetry_events_2026-06-24_15-58-20.jsonl"

# Parse arguments
EVENTS_FILE=""
MODEL=""
ALL_MODELS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input|-i)
      EVENTS_FILE="$2"
      shift 2
      ;;
    --model|-m)
      MODEL="$2"
      shift 2
      ;;
    --all-models|-a)
      ALL_MODELS=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--input <events.jsonl>] [--model <kind>] [--all-models]"
      echo ""
      echo "Feed a telemetry events file through the local LLM and show the output."
      echo ""
      echo "Options:"
      echo "  --input, -i <path>     Path to telemetry events JSONL file"
      echo "                         (default: sample file)"
      echo "  --model, -m <kind>     Model kind: fast (default), full,"
      echo "                         qwen35_0_8b_q4_k_m, deepseek_r1_qwen_7b_q4_k_m"
      echo "  --all-models, -a       Run on every downloaded model"
      echo "  --help, -h             Show this help"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--input <path>] [--model <kind>] [--all-models]"
      exit 1
      ;;
  esac
done

# Default to sample file if no input provided
if [ -z "$EVENTS_FILE" ]; then
  if [ -f "$SAMPLE_FILE" ]; then
    EVENTS_FILE="$SAMPLE_FILE"
  else
    echo "Error: No --input provided and sample file not found at:"
    echo "  $SAMPLE_FILE"
    exit 1
  fi
fi

# Resolve the test filter
if [ "$ALL_MODELS" = true ]; then
  TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnAllAvailableModels"
elif [ -n "$MODEL" ]; then
  case "$MODEL" in
    fast|qwen35_2b_q4_k_m)
      TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnQwen35_2B_Fast"
      ;;
    full|qwen35_4b_q4_k_m)
      TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnQwen35_4B_Full"
      ;;
    qwen35_0_8b_q4_k_m)
      TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnQwen35_0_8B"
      ;;
    deepseek_r1_qwen_7b_q4_k_m)
      TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnDeepSeekR1_7B"
      ;;
    *)
      echo "Error: Unknown model '$MODEL'"
      echo "Valid models: fast, full, qwen35_0_8b_q4_k_m, deepseek_r1_qwen_7b_q4_k_m"
      exit 1
      ;;
  esac
else
  # Default to fast
  TEST_FILTER="CasperTests/TelemetryModelProbeTests/testProbeOnQwen35_2B_Fast"
fi

echo "Telemetry Model Probe"
echo "File:  $EVENTS_FILE"
echo "Model: $([ "$ALL_MODELS" = true ] && echo 'all' || echo "${MODEL:-fast}")"
echo ""

xcodebuild test \
  -project "$ROOT_DIR/Casper.xcodeproj" \
  -scheme Casper \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  -only-testing:"$TEST_FILTER" \
  TELEMETRY_EVENTS_FILE="$EVENTS_FILE" \
  TELEMETRY_PROBE_OUTPUT="$OUTPUT_FILE"

echo ""
if [ "$ALL_MODELS" = true ]; then
  echo "=== ALL MODEL OUTPUTS ==="
  output_dir="$(dirname "$OUTPUT_FILE")"
  for f in "$output_dir"/telemetry_probe_output_*.txt; do
    [ -f "$f" ] || continue
    model_name=$(basename "$f" .txt | sed 's/telemetry_probe_output_//')
    echo ""
    echo "--- $model_name ---"
    cat "$f"
  done
else
  echo "=== LLM OUTPUT ==="
  MODEL_SLUG="${MODEL:-qwen35_2b_q4_k_m}"
  output_dir="$(dirname "$OUTPUT_FILE")"
  OUTPUT_FILE="$output_dir/telemetry_probe_output_${MODEL_SLUG}.txt"
  if [ -f "$OUTPUT_FILE" ]; then
    cat "$OUTPUT_FILE"
  else
    echo "(no output file found at $OUTPUT_FILE)"
  fi
fi
