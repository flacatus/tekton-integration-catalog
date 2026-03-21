#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export RESULTS_DIR="$TEST_TEMP_DIR/results"
  export MOCK_BIN="$TEST_TEMP_DIR/mock_bin"
  export MOCK_DATA_DIR="$TEST_TEMP_DIR/mock_data"
  
  mkdir -p "$RESULTS_DIR" "$MOCK_BIN" "$MOCK_DATA_DIR"
  export PATH="$MOCK_BIN:$PATH"

  # Create empty utils.sh to mock the sourced file
  touch "$TEST_TEMP_DIR/utils.sh"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/usr/bin/env bash
set -euo pipefail
. /utils.sh

if [ -z "$FBC_FRAGMENT" ]; then
  echo "Error: FBC_FRAGMENT parameter is required." >&2
  exit 1
fi

echo "Retrieving unreleased bundles..."
if ! unreleased_bundles=$(get_unreleased_bundles -i "$FBC_FRAGMENT"); then
  echo "Could not get unreleased bundle images from the fragment. Make sure you have ImagePullCredentials for registry.redhat.io" >&2
  exit 1
fi

if [ -z "${unreleased_bundles}" ]; then
  echo "No unreleased bundles found. Exiting as a no-op."
  echo -n "" > "$(step.results.unreleasedBundle.path)"
  exit 0
fi
echo "Unreleased bundles found: $unreleased_bundles"

# Render the FBC fragment
if ! RENDER_OUT_FBC=$(render_opm -t "$FBC_FRAGMENT"); then
  echo "Failed to render the FBC fragment" >&2
  exit 1
fi

# Determine PACKAGE_NAME if not provided
if [ -z "$PACKAGE_NAME" ]; then
  echo "Checking package association of unreleased bundles..."
  package_image_map=$(group_bundle_images_by_package "$RENDER_OUT_FBC" "$unreleased_bundles")
  echo "Package-image map: $package_image_map"
  package_count=$(echo "$package_image_map" | jq 'keys | length')

  if [[ "$package_count" -gt 1 ]]; then
    echo "Error: Multiple packages detected. User must specify PACKAGE_NAME." >&2
    exit 1
  fi

  PACKAGE_NAME=$(echo "$package_image_map" | jq -r 'keys[0]')
fi
echo "Using package: $PACKAGE_NAME"

# Determine CHANNEL_NAME if not provided
if [ -z "$CHANNEL_NAME" ]; then
  CHANNEL_NAME=$(get_channel_from_catalog "$RENDER_OUT_FBC" "$PACKAGE_NAME")
  if [ -z "$CHANNEL_NAME" ]; then
    echo "Failed to determine a default channel for package '$PACKAGE_NAME'" >&2
    exit 1
  fi
fi
echo "Using channel: $CHANNEL_NAME"

if ! highest_version_from_bundles_list=$(get_highest_version_from_bundles_list "$RENDER_OUT_FBC" "$PACKAGE_NAME" "$CHANNEL_NAME" "$unreleased_bundles"); then
  echo "No unreleased bundle(s) found matching the specified package and/or channel. Exiting as a no-op."
  echo -n "" > "$(step.results.unreleasedBundle.path)"
  exit 0
fi

echo "Highest bundle: $highest_version_from_bundles_list"
echo -n -e "$highest_version_from_bundles_list" > "$(step.results.unreleasedBundle.path)"
echo -n "$PACKAGE_NAME" > "$(step.results.packageName.path)"
echo -n "$CHANNEL_NAME" > "$(step.results.channelName.path)"
SCRIPT_EOF

  # Replace sourced file path
  sed -i'' -e "s|\. /utils\.sh|\. $TEST_TEMP_DIR/utils.sh|g" "$SCRIPT_FILE"
  
  # Replace result paths
  sed -i'' -e "s|\$(step.results.unreleasedBundle.path)|$RESULTS_DIR/unreleasedBundle|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(step.results.packageName.path)|$RESULTS_DIR/packageName|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(step.results.channelName.path)|$RESULTS_DIR/channelName|g" "$SCRIPT_FILE"

  chmod +x "$SCRIPT_FILE"

  # Default env vars
  export FBC_FRAGMENT="quay.io/test/fragment:latest"
  export PACKAGE_NAME=""
  export CHANNEL_NAME=""

  # Mocks for functions in utils.sh
  cat << 'EOF' > "$MOCK_BIN/get_unreleased_bundles"
#!/bin/bash
if [ -f "$MOCK_DATA_DIR/get_unreleased_bundles_exit" ]; then
  exit $(cat "$MOCK_DATA_DIR/get_unreleased_bundles_exit")
fi
cat "$MOCK_DATA_DIR/get_unreleased_bundles_out"
EOF
  chmod +x "$MOCK_BIN/get_unreleased_bundles"

  cat << 'EOF' > "$MOCK_BIN/render_opm"
#!/bin/bash
if [ -f "$MOCK_DATA_DIR/render_opm_exit" ]; then
  exit $(cat "$MOCK_DATA_DIR/render_opm_exit")
fi
cat "$MOCK_DATA_DIR/render_opm_out"
EOF
  chmod +x "$MOCK_BIN/render_opm"

  cat << 'EOF' > "$MOCK_BIN/group_bundle_images_by_package"
#!/bin/bash
cat "$MOCK_DATA_DIR/group_bundle_images_by_package_out"
EOF
  chmod +x "$MOCK_BIN/group_bundle_images_by_package"

  cat << 'EOF' > "$MOCK_BIN/get_channel_from_catalog"
#!/bin/bash
cat "$MOCK_DATA_DIR/get_channel_from_catalog_out"
EOF
  chmod +x "$MOCK_BIN/get_channel_from_catalog"

  cat << 'EOF' > "$MOCK_BIN/get_highest_version_from_bundles_list"
#!/bin/bash
if [ -f "$MOCK_DATA_DIR/get_highest_version_from_bundles_list_exit" ]; then
  exit $(cat "$MOCK_DATA_DIR/get_highest_version_from_bundles_list_exit")
fi
cat "$MOCK_DATA_DIR/get_highest_version_from_bundles_list_out"
EOF
  chmod +x "$MOCK_BIN/get_highest_version_from_bundles_list"

  # Default mock data
  echo "bundle1 bundle2" > "$MOCK_DATA_DIR/get_unreleased_bundles_out"
  echo "rendered_fbc_content" > "$MOCK_DATA_DIR/render_opm_out"
  echo '{"pkg1":["bundle1", "bundle2"]}' > "$MOCK_DATA_DIR/group_bundle_images_by_package_out"
  echo "stable" > "$MOCK_DATA_DIR/get_channel_from_catalog_out"
  echo "bundle2" > "$MOCK_DATA_DIR/get_highest_version_from_bundles_list_out"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Error: FBC_FRAGMENT parameter is required" {
  export FBC_FRAGMENT=""
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: FBC_FRAGMENT parameter is required."* ]]
}

@test "Error: get_unreleased_bundles fails" {
  echo "1" > "$MOCK_DATA_DIR/get_unreleased_bundles_exit"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not get unreleased bundle images from the fragment."* ]]
}

@test "No unreleased bundles found" {
  echo -n "" > "$MOCK_DATA_DIR/get_unreleased_bundles_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unreleased bundles found. Exiting as a no-op."* ]]
  [ -f "$RESULTS_DIR/unreleasedBundle" ]
  [ ! -s "$RESULTS_DIR/unreleasedBundle" ]
}

@test "Error: render_opm fails" {
  echo "1" > "$MOCK_DATA_DIR/render_opm_exit"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to render the FBC fragment"* ]]
}

@test "Error: Multiple packages detected" {
  echo '{"pkg1":["bundle1"], "pkg2":["bundle2"]}' > "$MOCK_DATA_DIR/group_bundle_images_by_package_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Multiple packages detected. User must specify PACKAGE_NAME."* ]]
}

@test "Error: Failed to determine a default channel" {
  echo -n "" > "$MOCK_DATA_DIR/get_channel_from_catalog_out"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to determine a default channel for package 'pkg1'"* ]]
}

@test "No unreleased bundle(s) found matching the specified package and/or channel" {
  echo "1" > "$MOCK_DATA_DIR/get_highest_version_from_bundles_list_exit"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unreleased bundle(s) found matching the specified package and/or channel. Exiting as a no-op."* ]]
  [ -f "$RESULTS_DIR/unreleasedBundle" ]
  [ ! -s "$RESULTS_DIR/unreleasedBundle" ]
}

@test "Happy path: determines package and channel successfully" {
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Highest bundle: bundle2"* ]]
  [ -f "$RESULTS_DIR/unreleasedBundle" ]
  [ "$(cat "$RESULTS_DIR/unreleasedBundle")" == "bundle2" ]
  [ -f "$RESULTS_DIR/packageName" ]
  [ "$(cat "$RESULTS_DIR/packageName")" == "pkg1" ]
  [ -f "$RESULTS_DIR/channelName" ]
  [ "$(cat "$RESULTS_DIR/channelName")" == "stable" ]
}

@test "Happy path: uses provided package and channel" {
  export PACKAGE_NAME="my-pkg"
  export CHANNEL_NAME="my-channel"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using package: my-pkg"* ]]
  [[ "$output" == *"Using channel: my-channel"* ]]
  [[ "$output" == *"Highest bundle: bundle2"* ]]
  [ -f "$RESULTS_DIR/unreleasedBundle" ]
  [ "$(cat "$RESULTS_DIR/unreleasedBundle")" == "bundle2" ]
  [ -f "$RESULTS_DIR/packageName" ]
  [ "$(cat "$RESULTS_DIR/packageName")" == "my-pkg" ]
  [ -f "$RESULTS_DIR/channelName" ]
  [ "$(cat "$RESULTS_DIR/channelName")" == "my-channel" ]
}
