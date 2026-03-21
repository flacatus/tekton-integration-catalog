#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/bin/bash
set -x

qe-tools analyze-test-results \
--oci-ref=$OCI_REF \
--junit-report-name=$JUNIT_REPORT_NAME \
--e2e-log-name=$E2E_LOG_NAME \
--cluster-provision-log-name=$CLUSTER_PROVISION_LOG_NAME \
--output-file=$ANALYSIS_OUTPUT_FILE
SCRIPT_EOF

  chmod +x "$SCRIPT_FILE"

  cat << 'EOF' > "$MOCK_BIN/qe-tools"
#!/bin/bash
if [[ "$1" == "analyze-test-results" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "--oci-ref=" ]]; then
      echo "Missing required flag: oci-ref" >&2
      exit 1
    fi
    if [[ "$arg" == "--oci-ref=fail" ]]; then
      echo "Error analyzing test results" >&2
      exit 1
    fi
  done
  echo "Successfully analyzed test results"
  exit 0
fi
echo "Unknown command: $1" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/qe-tools"

  export OCI_REF="quay.io/test/artifact:latest"
  export JUNIT_REPORT_NAME="junit.xml"
  export E2E_LOG_NAME="e2e-tests.log"
  export CLUSTER_PROVISION_LOG_NAME="cluster-provision.log"
  export ANALYSIS_OUTPUT_FILE="$TEST_TEMP_DIR/analysis.md"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Happy path: qe-tools succeeds" {
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Successfully analyzed test results"* ]]
}

@test "Error path: qe-tools fails" {
  export OCI_REF="fail"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error analyzing test results"* ]]
}

@test "Error path: missing OCI_REF" {
  export OCI_REF=""
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required flag: oci-ref"* ]]
}
