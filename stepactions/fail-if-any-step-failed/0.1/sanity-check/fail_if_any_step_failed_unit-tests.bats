#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export TEKTON_STEPS_DIR="$TEST_TEMP_DIR/tekton/steps"
  mkdir -p "$TEKTON_STEPS_DIR"

  # Embed the script via heredoc
  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/bin/bash
set -e

# Loop through "exitCode" files containing exit codes of all executed steps within the Task
find -L "/tekton/steps/" -path "*/step-*/exitCode" | while read -r file; do
    exitCode=$(<"$file")

    # If some of the steps exited with non-zero code, exit the script with that code
    if [ "$exitCode" != "0" ]; then
        stepname=${file##*step-}
        stepname=${stepname%%/*}
        echo -e "[ERROR]: Step '$stepname' failed with exit code '$exitCode', which was previously ignored - exiting now"
        exit $exitCode
    fi
done

echo -e "[INFO]: Did not find any failed steps"
SCRIPT_EOF

  # Replace Tekton paths with temp paths
  sed -i'' -e "s|/tekton/steps/|$TEKTON_STEPS_DIR/|g" "$SCRIPT_FILE"
  chmod +x "$SCRIPT_FILE"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "No exitCode files found" {
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO]: Did not find any failed steps"* ]]
}

@test "One step succeeded (exitCode 0)" {
  mkdir -p "$TEKTON_STEPS_DIR/step-build"
  echo "0" > "$TEKTON_STEPS_DIR/step-build/exitCode"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO]: Did not find any failed steps"* ]]
}

@test "One step failed (exitCode 1)" {
  mkdir -p "$TEKTON_STEPS_DIR/step-test"
  echo "1" > "$TEKTON_STEPS_DIR/step-test/exitCode"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERROR]: Step 'test' failed with exit code '1'"* ]]
}

@test "Multiple steps, one failed (exitCode 2)" {
  mkdir -p "$TEKTON_STEPS_DIR/step-build"
  echo "0" > "$TEKTON_STEPS_DIR/step-build/exitCode"
  
  mkdir -p "$TEKTON_STEPS_DIR/step-lint"
  echo "2" > "$TEKTON_STEPS_DIR/step-lint/exitCode"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[ERROR]: Step 'lint' failed with exit code '2'"* ]]
}

@test "Multiple steps, all succeeded" {
  mkdir -p "$TEKTON_STEPS_DIR/step-build"
  echo "0" > "$TEKTON_STEPS_DIR/step-build/exitCode"
  
  mkdir -p "$TEKTON_STEPS_DIR/step-lint"
  echo "0" > "$TEKTON_STEPS_DIR/step-lint/exitCode"
  
  mkdir -p "$TEKTON_STEPS_DIR/step-test"
  echo "0" > "$TEKTON_STEPS_DIR/step-test/exitCode"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO]: Did not find any failed steps"* ]]
}

@test "Step name extraction works correctly with complex paths" {
  mkdir -p "$TEKTON_STEPS_DIR/step-my-complex-name"
  # Using exit code 3 instead of 127 to avoid BATS "Command not found" warning/interception
  echo "3" > "$TEKTON_STEPS_DIR/step-my-complex-name/exitCode"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[ERROR]: Step 'my-complex-name' failed with exit code '3'"* ]]
}

@test "Empty exitCode file" {
  mkdir -p "$TEKTON_STEPS_DIR/step-empty"
  touch "$TEKTON_STEPS_DIR/step-empty/exitCode"
  
  run "$SCRIPT_FILE"
  # exitCode is empty, so `exit $exitCode` becomes `exit` (no args), which exits with the status of the echo command (0)
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ERROR]: Step 'empty' failed with exit code ''"* ]]
}