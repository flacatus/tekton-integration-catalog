#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export MOCK_BIN="$TEST_TEMP_DIR/mock_bin"
  export MOCK_DATA_DIR="$TEST_TEMP_DIR/mock_data"
  export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
  
  mkdir -p "$MOCK_BIN" "$MOCK_DATA_DIR" "$WORKSPACE_DIR"
  export PATH="$MOCK_BIN:$PATH"

  # Embed the script via heredoc
  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/bin/bash
set -e

PLR_NAME="$(params.pipelinerun-name)"
CURRENT_TR_NAME="$(context.taskRun.name)"

echo "Waiting for all TaskRuns in PipelineRun '$PLR_NAME' to complete (excluding the TaskRun: $CURRENT_TR_NAME)..."

while true; do
  incomplete=$(kubectl get taskruns -l tekton.dev/pipelineRun=$PLR_NAME -o json | jq --arg current "$CURRENT_TR_NAME" '
    [.items[]
      | select(.metadata.name != $current)
      | select(.status.conditions[0].status != "True" and .status.conditions[0].status != "False")
    ] | length')

  if [ "$incomplete" -eq 0 ]; then
    echo "✅ All other TaskRuns are complete."
    break
  fi

  echo "⏳ Still waiting for $incomplete TaskRuns to complete..."
  sleep 1
done

if [[ "$EVENT_TYPE" != "push" && -n "$PULL_REQUEST_NUMBER" ]]; then
  EVENT_TYPE="pull_request"
elif [[ -z "$PULL_REQUEST_NUMBER" && "$EVENT_TYPE" != "push" ]]; then
  EVENT_TYPE="push"
fi

PLR_STATUS=$(kubectl get pipelinerun "$PLR_NAME" -o jsonpath='{.status.conditions[0].reason}')

# Determine the pipeline status based on the pipeline-aggregate-status param and $PLR_STATUS
if [ "$(params.pipeline-aggregate-status)" == "Succeeded" ] || [ "$(params.pipeline-aggregate-status)" == "Completed" ]; then
  echo "[INFO] PipelineRun succeeded."
  PLR_STATUS="Succeeded"
elif [ "${PLR_STATUS}" = "CancelledRunningFinally" ]; then
  echo "[INFO] PipelineRun was cancelled."
  PLR_STATUS="Cancelled"
else
  echo "[INFO] PipelineRun failed."
  PLR_STATUS="Failed"
fi

OUTPUT_FILE="./pipeline-status.json"
NOW_SECS=$(date +%s)

echo "Summarizing PipelineRun: $PLR_NAME (excluding the TaskRun: $CURRENT_TR_NAME)"
echo "Output file: $OUTPUT_FILE"

# Get PipelineRun JSON for extracting additional fields
PLR_JSON=$(kubectl get pipelinerun "$PLR_NAME" -o json)
NAMESPACE=$(echo "$PLR_JSON" | jq -r '.metadata.namespace')
CREATED_AT=$(echo "$PLR_JSON" | jq -r '.metadata.creationTimestamp')
STARTED_AT=$(echo "$PLR_JSON" | jq -r '.status.startTime // empty')

# Convert NOW_SECS to ISO 8601 format for finishedAt
FINISHED_AT=$(date -u -d "@${NOW_SECS}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "${NOW_SECS}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

# Get commit SHA from PipelineRun labels or annotations
COMMIT_SHA=$(echo "$PLR_JSON" | jq -r '.metadata.labels["pac.test.appstudio.openshift.io/sha"] // .metadata.annotations["pac.test.appstudio.openshift.io/sha"] // .metadata.labels["pac.test.appstudio.openshift.io/git-revision"] // .metadata.annotations["pac.test.appstudio.openshift.io/git-revision"] // empty')

# Get console URL - use BUILD_CONSOLE_URL as-is
CONSOLE_URL="${BUILD_CONSOLE_URL:-}"

{
  echo '{'
  echo "  \"pipelineRunName\": \"$PLR_NAME\","
  echo "  \"namespace\": \"$NAMESPACE\","

  PR_START=$(echo "$PLR_JSON" | jq -r '.status.startTime // empty')
  if [[ -n "$PR_START" && "$PR_START" != "null" ]]; then
    PR_START_SECS=$(date -d "$PR_START" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$PR_START" +%s 2>/dev/null || echo "")
    if [[ -n "$PR_START_SECS" ]]; then
      DURATION=$((NOW_SECS - PR_START_SECS))
      echo "  \"duration\": \"${DURATION}s\","
    else
      echo "  \"duration\": \"0s\","
    fi
  else
    echo "  \"duration\": \"0s\","
  fi

  echo "  \"status\": \"${PLR_STATUS}\","
  echo "  \"eventType\": \"$EVENT_TYPE\","
  echo "  \"scenario\": \"$SCENARIO_NAME\","
  echo "  \"consoleUrl\": \"${CONSOLE_URL:-}\","
  echo '  "git": {'
  echo "    \"gitOrganization\": \"$TARGET_GIT_ORGANIZATION\","
  echo -n "    \"gitRepository\": \"$TARGET_GIT_REPOSITORY\""
  if [[ -n "$PULL_REQUEST_NUMBER" && "$PULL_REQUEST_NUMBER" != "null" ]]; then
    echo ","
    echo -n "    \"pullRequestNumber\": \"$PULL_REQUEST_NUMBER\""
  fi
  if [[ -n "$COMMIT_SHA" && "$COMMIT_SHA" != "null" ]]; then
    echo ","
    echo -n "    \"commitSha\": \"$COMMIT_SHA\""
  fi
  echo ","
  echo -n "    \"pullRequestAuthor\": \"\""
  echo
  echo '  },'
  echo '  "timestamps": {'
  echo -n "    \"createdAt\": \"${CREATED_AT:-}\""
  if [[ -n "$STARTED_AT" && "$STARTED_AT" != "null" ]]; then
    echo ","
    echo -n "    \"startedAt\": \"$STARTED_AT\""
  else
    echo ","
    echo -n "    \"startedAt\": \"\""
  fi
  echo ","
  echo -n "    \"finishedAt\": \"${FINISHED_AT:-}\""
  echo
  echo '  },'
  echo "  \"taskRuns\": ["

  TR_NAMES=$(kubectl get taskruns -l tekton.dev/pipelineRun=$PLR_NAME -o jsonpath="{.items[*].metadata.name}")

  FIRST=true
  for TR in $TR_NAMES; do
    if [ "$TR" = "$CURRENT_TR_NAME" ]; then
      continue
    fi

    TR_JSON=$(kubectl get taskrun "$TR" -o json)
    TASK_NAME=$(echo "$TR_JSON" | jq -r '.metadata.labels["tekton.dev/pipelineTask"]')
    STATUS=$(echo "$TR_JSON" | jq -r '.status.conditions[0].reason')
    START_TIME=$(echo "$TR_JSON" | jq -r '.status.startTime')
    COMPLETION_TIME=$(echo "$TR_JSON" | jq -r '.status.completionTime // empty')

    START_SECS=$(date -d "$START_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$START_TIME" +%s)
    if [ -z "$COMPLETION_TIME" ]; then
      END_SECS=$NOW_SECS
    else
      END_SECS=$(date -d "$COMPLETION_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$COMPLETION_TIME" +%s)
    fi
    TASK_DURATION=$((END_SECS - START_SECS))

    if [ "$FIRST" = false ]; then
      echo ","
    fi
    FIRST=false

    echo "    {"
    echo "      \"name\": \"$TASK_NAME\","
    echo "      \"status\": \"$STATUS\","
    echo "      \"duration\": \"${TASK_DURATION}s\""
    echo -n "    }"
  done

  echo
  echo "  ]"
  echo '}'
} > "$OUTPUT_FILE"
jq -r < $OUTPUT_FILE
SCRIPT_EOF

  # Replace Tekton variables and paths
  sed -i'' -e 's/$(params.pipelinerun-name)/test-plr/g' "$SCRIPT_FILE"
  sed -i'' -e 's/$(context.taskRun.name)/current-tr/g' "$SCRIPT_FILE"
  sed -i'' -e 's/$(params.pipeline-aggregate-status)/$PIPELINE_AGGREGATE_STATUS/g' "$SCRIPT_FILE"
  sed -i'' -e "s|./pipeline-status.json|$WORKSPACE_DIR/pipeline-status.json|g" "$SCRIPT_FILE"

  chmod +x "$SCRIPT_FILE"

  # Mock sleep
  cat << 'EOF' > "$MOCK_BIN/sleep"
#!/bin/bash
exit 0
EOF
  chmod +x "$MOCK_BIN/sleep"

  # Mock date
  cat << 'EOF' > "$MOCK_BIN/date"
#!/bin/bash
if [[ "$*" == *"+%s"* ]]; then
  if [[ "$*" == *"2023-01-01T00:00:00Z"* ]]; then
    echo "1672531200"
  elif [[ "$*" == *"2023-01-01T00:01:00Z"* ]]; then
    echo "1672531260"
  else
    echo "1672531300"
  fi
elif [[ "$*" == *"+%Y-%m-%dT%H:%M:%SZ"* ]]; then
  echo "2023-01-01T00:01:40Z"
else
  /bin/date "$@"
fi
EOF
  chmod +x "$MOCK_BIN/date"

  # Mock kubectl
  cat << 'EOF' > "$MOCK_BIN/kubectl"
#!/bin/bash
if [[ "$1" == "get" && "$2" == "taskruns" ]]; then
  if [[ "$*" == *"-o jsonpath"* ]]; then
    cat "$MOCK_DATA_DIR/taskruns_names.txt"
  elif [[ "$*" == *"-o json"* ]]; then
    if [ -f "$MOCK_DATA_DIR/taskruns_incomplete.json" ]; then
      cat "$MOCK_DATA_DIR/taskruns_incomplete.json"
      rm "$MOCK_DATA_DIR/taskruns_incomplete.json"
    else
      cat "$MOCK_DATA_DIR/taskruns.json"
    fi
  fi
elif [[ "$1" == "get" && "$2" == "pipelinerun" ]]; then
  if [[ "$*" == *"-o jsonpath"* ]]; then
    cat "$MOCK_DATA_DIR/plr_status.txt"
  elif [[ "$*" == *"-o json"* ]]; then
    cat "$MOCK_DATA_DIR/pipelinerun.json"
  fi
elif [[ "$1" == "get" && "$2" == "taskrun" ]]; then
  cat "$MOCK_DATA_DIR/$3.json"
fi
EOF
  chmod +x "$MOCK_BIN/kubectl"

  # Default mock data
  cat << 'EOF' > "$MOCK_DATA_DIR/taskruns.json"
{
  "items": [
    {
      "metadata": { "name": "tr-1" },
      "status": { "conditions": [ { "status": "True" } ] }
    },
    {
      "metadata": { "name": "current-tr" },
      "status": { "conditions": [ { "status": "Unknown" } ] }
    }
  ]
}
EOF

  cat << 'EOF' > "$MOCK_DATA_DIR/pipelinerun.json"
{
  "metadata": {
    "namespace": "test-namespace",
    "creationTimestamp": "2023-01-01T00:00:00Z",
    "labels": {
      "pac.test.appstudio.openshift.io/sha": "abcdef123456"
    }
  },
  "status": {
    "startTime": "2023-01-01T00:00:00Z"
  }
}
EOF

  echo "tr-1 current-tr" > "$MOCK_DATA_DIR/taskruns_names.txt"
  echo "Succeeded" > "$MOCK_DATA_DIR/plr_status.txt"

  cat << 'EOF' > "$MOCK_DATA_DIR/tr-1.json"
{
  "metadata": {
    "name": "tr-1",
    "labels": {
      "tekton.dev/pipelineTask": "task-1"
    }
  },
  "status": {
    "conditions": [
      { "reason": "Succeeded" }
    ],
    "startTime": "2023-01-01T00:00:00Z",
    "completionTime": "2023-01-01T00:01:00Z"
  }
}
EOF

  # Default env vars
  export TARGET_GIT_ORGANIZATION="my-org"
  export TARGET_GIT_REPOSITORY="my-repo"
  export EVENT_TYPE="pull_request"
  export PULL_REQUEST_NUMBER="123"
  export SCENARIO_NAME="my-scenario"
  export BUILD_CONSOLE_URL="https://console.url"
  export PIPELINE_AGGREGATE_STATUS="Succeeded"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Happy path: PipelineRun Succeeded, 1 other TaskRun" {
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ All other TaskRuns are complete."* ]]
  [[ "$output" == *"[INFO] PipelineRun succeeded."* ]]
  
  [ -f "$WORKSPACE_DIR/pipeline-status.json" ]
  
  run jq -r '.status' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "Succeeded" ]
  
  run jq -r '.duration' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "100s" ]
  
  run jq -r '.taskRuns[0].duration' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "60s" ]
  
  run jq -r '.git.commitSha' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "abcdef123456" ]
}

@test "Loop waits for incomplete TaskRuns" {
  cat << 'EOF' > "$MOCK_DATA_DIR/taskruns_incomplete.json"
{
  "items": [
    {
      "metadata": { "name": "tr-1" },
      "status": { "conditions": [ { "status": "Unknown" } ] }
    },
    {
      "metadata": { "name": "current-tr" },
      "status": { "conditions": [ { "status": "Unknown" } ] }
    }
  ]
}
EOF

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⏳ Still waiting for 1 TaskRuns to complete..."* ]]
  [[ "$output" == *"✅ All other TaskRuns are complete."* ]]
}

@test "PipelineRun Cancelled" {
  export PIPELINE_AGGREGATE_STATUS="Failed"
  echo "CancelledRunningFinally" > "$MOCK_DATA_DIR/plr_status.txt"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] PipelineRun was cancelled."* ]]
  
  run jq -r '.status' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "Cancelled" ]
}

@test "PipelineRun Failed" {
  export PIPELINE_AGGREGATE_STATUS="Failed"
  echo "Failed" > "$MOCK_DATA_DIR/plr_status.txt"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] PipelineRun failed."* ]]
  
  run jq -r '.status' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "Failed" ]
}

@test "Event type fallback to push" {
  export EVENT_TYPE="unknown"
  export PULL_REQUEST_NUMBER=""
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.eventType' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "push" ]
}

@test "Event type push remains push even with PR number" {
  export EVENT_TYPE="push"
  export PULL_REQUEST_NUMBER="123"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.eventType' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "push" ]
}

@test "Missing timestamps results in duration 0s" {
  cat << 'EOF' > "$MOCK_DATA_DIR/pipelinerun.json"
{
  "metadata": {
    "namespace": "test-namespace",
    "creationTimestamp": "2023-01-01T00:00:00Z"
  },
  "status": {}
}
EOF

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.duration' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "0s" ]
}

@test "TaskRun missing completionTime uses NOW_SECS" {
  cat << 'EOF' > "$MOCK_DATA_DIR/tr-1.json"
{
  "metadata": {
    "name": "tr-1",
    "labels": {
      "tekton.dev/pipelineTask": "task-1"
    }
  },
  "status": {
    "conditions": [
      { "reason": "Running" }
    ],
    "startTime": "2023-01-01T00:00:00Z"
  }
}
EOF

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.taskRuns[0].duration' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "100s" ]
}

@test "Empty COMMIT_SHA omits commitSha field" {
  cat << 'EOF' > "$MOCK_DATA_DIR/pipelinerun.json"
{
  "metadata": {
    "namespace": "test-namespace",
    "creationTimestamp": "2023-01-01T00:00:00Z"
  },
  "status": {
    "startTime": "2023-01-01T00:00:00Z"
  }
}
EOF

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.git | has("commitSha")' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "false" ]
}

@test "Multiple TaskRuns are formatted correctly" {
  echo "tr-1 tr-2 current-tr" > "$MOCK_DATA_DIR/taskruns_names.txt"
  
  cat << 'EOF' > "$MOCK_DATA_DIR/tr-2.json"
{
  "metadata": {
    "name": "tr-2",
    "labels": {
      "tekton.dev/pipelineTask": "task-2"
    }
  },
  "status": {
    "conditions": [
      { "reason": "Failed" }
    ],
    "startTime": "2023-01-01T00:00:00Z",
    "completionTime": "2023-01-01T00:01:00Z"
  }
}
EOF

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.taskRuns | length' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "2" ]
  
  run jq -r '.taskRuns[1].name' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "task-2" ]
  
  run jq -r '.taskRuns[1].status' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "Failed" ]
}

@test "No other TaskRuns" {
  echo "current-tr" > "$MOCK_DATA_DIR/taskruns_names.txt"
  
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  
  run jq -r '.taskRuns | length' "$WORKSPACE_DIR/pipeline-status.json"
  [ "$output" == "0" ]
}
