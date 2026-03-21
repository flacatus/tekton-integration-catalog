#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export RESULTS_DIR="$TEST_TEMP_DIR/results"
  export MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
  
  mkdir -p "$RESULTS_DIR"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Default env vars
  export IMAGES=""
  export LABEL_SELECTOR=""
  export NAMESPACE=""
  export TEST_NAME=""
  export COVERAGE_PORT="9095"
  export OUTPUT_PATH="$TEST_TEMP_DIR/workspace/coverage"
  export COVERAGE_FILTERS="coverage_server.go"
  export GENERATE_REPORTS="true"
  export REMAP_PATHS="false"
  export TIMEOUT="120"
  export VERBOSE="false"

  # Mock date
  cat << 'EOF' > "$MOCK_BIN/date"
#!/bin/sh
echo "20241119-123456"
EOF
  chmod +x "$MOCK_BIN/date"

  # Mock coverport
  cat << 'EOF' > "$MOCK_BIN/coverport"
#!/bin/sh
echo "Mock coverport called with: $@"
for arg in "$@"; do
  if [[ "$arg" == --output=* ]]; then
    OUTDIR="${arg#--output=}"
    COUNT=${MOCK_COMPONENTS:-2}
    i=1
    while [ $i -le $COUNT ]; do
      mkdir -p "$OUTDIR/comp$i"
      touch "$OUTDIR/comp$i/cov.out"
      i=$((i + 1))
    done
  fi
done
EOF
  chmod +x "$MOCK_BIN/coverport"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/bin/sh
set -e

log() { echo "📋 $*"; }
error() { echo "❌ ERROR: $*" >&2; exit 1; }
warn() { echo "⚠️  WARNING: $*"; }

log "Starting coverport coverage collection"

# Validate inputs
if [ -z "$IMAGES" ] && [ -z "$LABEL_SELECTOR" ]; then
  error "Must specify one of: images, or label-selector"
fi

# Build coverport collect command
CMD="coverport collect"

# Discovery method
if [ -n "$IMAGES" ]; then
  log "Using instrumented image list for pod discovery"
  CMD="$CMD --images=$IMAGES"
elif [ -n "$LABEL_SELECTOR" ]; then
  log "Using label selector for pod discovery"
  CMD="$CMD --label-selector=$LABEL_SELECTOR"
  if [ -z "$NAMESPACE" ]; then
    error "namespace is required when using label-selector"
  fi
fi

# Namespace
if [ -n "$NAMESPACE" ]; then
  CMD="$CMD --namespace=$NAMESPACE"
fi

# Test name
if [ -z "$TEST_NAME" ]; then
  TEST_NAME="coverage-$(date +%Y%m%d-%H%M%S)"
fi
CMD="$CMD --test-name=$TEST_NAME"

# Output directory
mkdir -p "$OUTPUT_PATH"
CMD="$CMD --output=$OUTPUT_PATH"

# Collection options
CMD="$CMD --port=$COVERAGE_PORT"
CMD="$CMD --timeout=$TIMEOUT"

if [ -n "$COVERAGE_FILTERS" ]; then
  CMD="$CMD --filters=$COVERAGE_FILTERS"
fi

# Processing options
if [ "$GENERATE_REPORTS" = "false" ]; then
  CMD="$CMD --skip-generate"
fi

if [ "$REMAP_PATHS" = "false" ]; then
  CMD="$CMD --remap-paths=false"
fi

# Note: HTML generation moved to coverport-upload (process phase)

# Verbose mode
if [ "$VERBOSE" = "true" ]; then
  CMD="$CMD --verbose"
  set -x
fi

# Execute collection
log "Executing: $CMD"
eval "$CMD"

# Count collected components
COMPONENT_COUNT=0
if [ -d "$OUTPUT_PATH" ]; then
  COMPONENT_COUNT=$(find "$OUTPUT_PATH" -mindepth 1 -maxdepth 1 -type d | wc -l)
fi

# Write results
printf "%s" "$OUTPUT_PATH" > "$(step.results.coverage-path.path)"
printf "%s" "$COMPONENT_COUNT" > "$(step.results.components-collected.path)"
printf "%s" "$TEST_NAME" > "$(step.results.test-name.path)"

log "✅ Coverage collection complete"
log "   Output path: $OUTPUT_PATH"
log "   Components: $COMPONENT_COUNT"
log "   Test name: $TEST_NAME"

# List collected files for visibility
if [ "$VERBOSE" = "true" ] && [ -d "$OUTPUT_PATH" ]; then
  log "Collected files:"
  find "$OUTPUT_PATH" -type f | head -20
fi
SCRIPT_EOF

  sed -i'' -e "s|\$(step.results.coverage-path.path)|$RESULTS_DIR/coverage-path|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(step.results.components-collected.path)|$RESULTS_DIR/components-collected|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(step.results.test-name.path)|$RESULTS_DIR/test-name|g" "$SCRIPT_FILE"

  chmod +x "$SCRIPT_FILE"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Fails if neither images nor label-selector is provided" {
  export IMAGES=""
  export LABEL_SELECTOR=""
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Must specify one of: images, or label-selector"* ]]
}

@test "Fails if label-selector is provided but namespace is empty" {
  export IMAGES=""
  export LABEL_SELECTOR="app=myapp"
  export NAMESPACE=""
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"namespace is required when using label-selector"* ]]
}

@test "Succeeds with images and generates test name" {
  export IMAGES="img1,img2"
  export TEST_NAME=""
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using instrumented image list for pod discovery"* ]]
  [[ "$output" == *"Executing: coverport collect --images=img1,img2"* ]]
  [[ "$output" == *"--test-name=coverage-20241119-123456"* ]]
  
  [ -f "$RESULTS_DIR/coverage-path" ]
  [ "$(cat "$RESULTS_DIR/coverage-path")" == "$OUTPUT_PATH" ]
  
  [ -f "$RESULTS_DIR/test-name" ]
  [ "$(cat "$RESULTS_DIR/test-name")" == "coverage-20241119-123456" ]
  
  [ -f "$RESULTS_DIR/components-collected" ]
  ACTUAL_COUNT=$(cat "$RESULTS_DIR/components-collected" | tr -d ' ')
  [ "$ACTUAL_COUNT" == "2" ]
}

@test "Succeeds with label-selector and namespace" {
  export IMAGES=""
  export LABEL_SELECTOR="app=myapp"
  export NAMESPACE="test-ns"
  export TEST_NAME="my-custom-test"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using label selector for pod discovery"* ]]
  [[ "$output" == *"Executing: coverport collect"* ]]
  [[ "$output" == *"--label-selector=app=myapp"* ]]
  [[ "$output" == *"--namespace=test-ns"* ]]
  [[ "$output" == *"--test-name=my-custom-test"* ]]
  
  [ -f "$RESULTS_DIR/test-name" ]
  [ "$(cat "$RESULTS_DIR/test-name")" == "my-custom-test" ]
}

@test "Prefers images over label-selector if both provided" {
  export IMAGES="img1"
  export LABEL_SELECTOR="app=myapp"
  export NAMESPACE="test-ns"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using instrumented image list for pod discovery"* ]]
  [[ "$output" != *"Using label selector"* ]]
}

@test "Applies correct flags for processing options" {
  export IMAGES="img1"
  export GENERATE_REPORTS="false"
  export REMAP_PATHS="false"
  export COVERAGE_FILTERS="filter1,filter2"
  export COVERAGE_PORT="8080"
  export TIMEOUT="60"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-generate"* ]]
  [[ "$output" == *"--remap-paths=false"* ]]
  [[ "$output" == *"--filters=filter1,filter2"* ]]
  [[ "$output" == *"--port=8080"* ]]
  [[ "$output" == *"--timeout=60"* ]]
}

@test "Omits filters flag if COVERAGE_FILTERS is empty" {
  export IMAGES="img1"
  export COVERAGE_FILTERS=""
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--filters="* ]]
}

@test "Verbose mode lists files and sets -x" {
  export IMAGES="img1"
  export VERBOSE="true"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" == *"Collected files:"* ]]
  [[ "$output" == *"cov.out"* ]]
}

@test "Counts components correctly when 0" {
  export IMAGES="img1"
  export MOCK_COMPONENTS=0
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  [ -f "$RESULTS_DIR/components-collected" ]
  ACTUAL_COUNT=$(cat "$RESULTS_DIR/components-collected" | tr -d ' ')
  [ "$ACTUAL_COUNT" == "0" ]
}

@test "Handles missing output directory gracefully" {
  export IMAGES="img1"
  export MOCK_COMPONENTS=0
  
  # Mock coverport to delete the output directory to test the if [ -d "$OUTPUT_PATH" ] branch
  cat << 'EOF' > "$MOCK_BIN/coverport"
#!/bin/sh
for arg in "$@"; do
  if [[ "$arg" == --output=* ]]; then
    OUTDIR="${arg#--output=}"
    rm -rf "$OUTDIR"
  fi
done
EOF
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  [ -f "$RESULTS_DIR/components-collected" ]
  ACTUAL_COUNT=$(cat "$RESULTS_DIR/components-collected" | tr -d ' ')
  [ "$ACTUAL_COUNT" == "0" ]
}