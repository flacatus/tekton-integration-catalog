#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export RESULTS_DIR="$TEST_TEMP_DIR/results"
  export MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
  export MOCK_DATA_DIR="$TEST_TEMP_DIR/mock-data"
  mkdir -p "$RESULTS_DIR" "$MOCK_BIN" "$MOCK_DATA_DIR"
  export PATH="$MOCK_BIN:$PATH"

  export BUNDLE_IMAGE="quay.io/test/bundle:latest"

  # Create dummy utils.sh to mock functions sourced by the script
  cat << 'EOF' > "$TEST_TEMP_DIR/utils.sh"
#!/bin/bash
render_opm() {
  local code=$(cat "$MOCK_DATA_DIR/render_opm_exit_code")
  if [ "$code" -ne 0 ]; then
    return "$code"
  fi
  cat "$MOCK_DATA_DIR/render_opm_out"
}
get_bundle_arches() {
  local code=$(cat "$MOCK_DATA_DIR/get_bundle_arches_exit_code")
  if [ "$code" -ne 0 ]; then
    return "$code"
  fi
  cat "$MOCK_DATA_DIR/get_bundle_arches_out"
}
EOF

  # Default mock data for happy path
  echo "0" > "$MOCK_DATA_DIR/render_opm_exit_code"
  echo "0" > "$MOCK_DATA_DIR/get_bundle_arches_exit_code"
  echo "dummy_render_out" > "$MOCK_DATA_DIR/render_opm_out"
  echo "amd64" > "$MOCK_DATA_DIR/get_bundle_arches_out"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/usr/bin/env bash
set -euo pipefail
. /utils.sh

if [ -z "$BUNDLE_IMAGE" ]; then
  echo "Error: BUNDLE_IMAGE parameter is required." >&2
  exit 1
fi

# Run opm render on a bundle image
if ! bundle_render_out=$(render_opm -t "$BUNDLE_IMAGE"); then
  echo "Failed to render the bundle image" >&2
  exit 1
fi

echo "Retrieving bundle-supported architectures..."
if ! arches=$(get_bundle_arches "$bundle_render_out"); then
  echo "Could not get bundle-supported architectures" >&2
  exit 1
fi

# If arm64 is supported, return it; otherwise, return amd64
if echo "$arches" | grep -q "^arm64$"; then
  echo "arm64 architecture is supported"
  printf "m6g.large" > $(step.results.bundleArch.path)
else
  echo "amd64 architecture is supported"
  printf "m5.large" > $(step.results.bundleArch.path)
fi
SCRIPT_EOF

  # Replace paths with temp paths
  sed -i'' -e "s|\. /utils\.sh|\. $TEST_TEMP_DIR/utils.sh|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(step.results.bundleArch.path)|$RESULTS_DIR/bundleArch|g" "$SCRIPT_FILE"
  chmod +x "$SCRIPT_FILE"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Fails when BUNDLE_IMAGE is missing" {
  export BUNDLE_IMAGE=""
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: BUNDLE_IMAGE parameter is required."* ]]
}

@test "Fails when render_opm fails" {
  echo "1" > "$MOCK_DATA_DIR/render_opm_exit_code"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to render the bundle image"* ]]
}

@test "Fails when get_bundle_arches fails" {
  echo "1" > "$MOCK_DATA_DIR/get_bundle_arches_exit_code"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not get bundle-supported architectures"* ]]
}

@test "Returns m6g.large when arm64 is supported" {
  echo "arm64" > "$MOCK_DATA_DIR/get_bundle_arches_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm64 architecture is supported"* ]]
  [ -f "$RESULTS_DIR/bundleArch" ]
  run cat "$RESULTS_DIR/bundleArch"
  [ "$output" == "m6g.large" ]
}

@test "Returns m5.large when only amd64 is supported" {
  echo "amd64" > "$MOCK_DATA_DIR/get_bundle_arches_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"amd64 architecture is supported"* ]]
  [ -f "$RESULTS_DIR/bundleArch" ]
  run cat "$RESULTS_DIR/bundleArch"
  [ "$output" == "m5.large" ]
}

@test "Returns m6g.large when multiple architectures including arm64 are supported" {
  printf "amd64\narm64\nppc64le\n" > "$MOCK_DATA_DIR/get_bundle_arches_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm64 architecture is supported"* ]]
  [ -f "$RESULTS_DIR/bundleArch" ]
  run cat "$RESULTS_DIR/bundleArch"
  [ "$output" == "m6g.large" ]
}

@test "Returns m5.large when multiple architectures without arm64 are supported" {
  printf "amd64\nppc64le\ns390x\n" > "$MOCK_DATA_DIR/get_bundle_arches_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"amd64 architecture is supported"* ]]
  [ -f "$RESULTS_DIR/bundleArch" ]
  run cat "$RESULTS_DIR/bundleArch"
  [ "$output" == "m5.large" ]
}

@test "Returns m5.large when architecture labels are not defined (empty output)" {
  printf "" > "$MOCK_DATA_DIR/get_bundle_arches_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"amd64 architecture is supported"* ]]
  [ -f "$RESULTS_DIR/bundleArch" ]
  run cat "$RESULTS_DIR/bundleArch"
  [ "$output" == "m5.large" ]
}
