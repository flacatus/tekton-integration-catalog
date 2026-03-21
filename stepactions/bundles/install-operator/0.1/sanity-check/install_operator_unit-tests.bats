#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export MOCK_BIN="$TEST_TEMP_DIR/mock_bin"
  export MOCK_DATA_DIR="$TEST_TEMP_DIR/mock_data"
  export ARTIFACT_DIR="$TEST_TEMP_DIR/workspace/konflux-artifacts"
  mkdir -p "$MOCK_BIN" "$MOCK_DATA_DIR" "$ARTIFACT_DIR"
  export PATH="$MOCK_BIN:$PATH"

  export FBC_FRAGMENT="my-fbc"
  export BUNDLE_IMAGE="my-bundle-image"
  export PACKAGE_NAME="my-package"
  export CHANNEL_NAME="my-channel"

  # Create mock /utils.sh
  export UTILS_FILE="$TEST_TEMP_DIR/utils.sh"
  cat << 'EOF' > "$UTILS_FILE"
get_bundle_suggested_namespace() { cat "$MOCK_DATA_DIR/suggested_namespace" 2>/dev/null || echo ""; }
get_bundle_install_modes() { cat "$MOCK_DATA_DIR/install_modes" 2>/dev/null || echo "AllNamespaces"; }
resolve_to_0th_manifest_digest() { cat "$MOCK_DATA_DIR/fbc_fragment" 2>/dev/null || echo "resolved-fbc"; }
get_bundle_name() { cat "$MOCK_DATA_DIR/bundle_name" 2>/dev/null || echo "my-bundle"; }
EOF

  cat << 'EOF' > "$MOCK_BIN/date"
#!/bin/bash
echo "2023-01-01T00:00:00.000Z"
EOF
  chmod +x "$MOCK_BIN/date"

  cat << 'EOF' > "$MOCK_BIN/sleep"
#!/bin/bash
exit 0
EOF
  chmod +x "$MOCK_BIN/sleep"

  cat << 'EOF' > "$MOCK_BIN/opm"
#!/bin/bash
if [[ "$1" == "render" ]]; then
  if [ -f "$MOCK_DATA_DIR/opm_fail" ]; then
    exit 1
  fi
  echo "rendered"
fi
EOF
  chmod +x "$MOCK_BIN/opm"

  cat << 'EOF' > "$MOCK_BIN/oc"
#!/bin/bash

# Extract resource type and name
CMD=""
RES=""
for arg in "$@"; do
  if [[ "$arg" == "get" || "$arg" == "create" || "$arg" == "apply" || "$arg" == "patch" ]]; then
    CMD="$arg"
  elif [[ "$CMD" == "get" && -z "$RES" && "$arg" != -* ]]; then
    RES="$arg"
  elif [[ "$CMD" == "patch" && -z "$RES" && "$arg" != -* ]]; then
    RES="$arg"
  fi
done

if [[ "$CMD" == "get" && "$RES" == "namespace" ]]; then
  if [[ "$*" == *"-o yaml"* ]]; then
    echo "ns-yaml"
    exit 0
  fi
  if [ -f "$MOCK_DATA_DIR/ns_exists" ]; then
    exit 0
  else
    exit 1
  fi
elif [[ "$CMD" == "create" ]]; then
  if [[ "$*" == *"-f -"* ]]; then
    input=$(cat)
    if [[ "$input" == *"kind: Namespace"* ]]; then
      echo "oo-ns-123"
    elif [[ "$input" == *"kind: OperatorGroup"* ]]; then
      echo "oo-og-123"
    elif [[ "$input" == *"kind: CatalogSource"* ]]; then
      echo "oo-cs-123"
    elif [[ "$input" == *"kind: Subscription"* ]]; then
      echo "oo-sub-123"
    fi
  fi
elif [[ "$CMD" == "apply" ]]; then
  if [[ "$*" == *"-f -"* ]]; then
    input=$(cat)
    if [[ "$input" == *"kind: OperatorGroup"* ]]; then
      echo "existing-og"
    fi
  fi
elif [[ "$CMD" == "get" && "$RES" == "operatorgroup" ]]; then
  if [[ "$*" == *"-o jsonpath"* ]]; then
    cat "$MOCK_DATA_DIR/operatorgroup" 2>/dev/null || echo ""
  elif [[ "$*" == *"-o yaml"* ]]; then
    echo "og-yaml"
  fi
elif [[ "$CMD" == "get" && "$RES" == catalogsources/* ]]; then
  cat "$MOCK_DATA_DIR/catsrc_state" 2>/dev/null || echo "READY"
elif [[ "$CMD" == "get" && "$RES" == "catalogsource" ]]; then
  if [[ "$*" == *"-o yaml"* ]]; then
    echo "cs-yaml"
  elif [[ "$*" == *"-o jsonpath"* ]]; then
    echo "cs-status"
  fi
elif [[ "$CMD" == "get" && "$RES" == "subscription" ]]; then
  if [[ "$*" == *"-o jsonpath"* ]]; then
    if [[ "$*" == *"{.status.installplan.name}"* ]]; then
      cat "$MOCK_DATA_DIR/installplan_name" 2>/dev/null || echo "ip-123"
    elif [[ "$*" == *"{.status.installedCSV}"* ]]; then
      cat "$MOCK_DATA_DIR/installed_csv" 2>/dev/null || echo "csv-123"
    elif [[ "$*" == *"{.status."* ]]; then
      echo "sub-status"
    fi
  elif [[ "$*" == *"-o yaml"* ]]; then
    echo "sub-yaml"
  fi
elif [[ "$CMD" == "patch" && "$RES" == "installPlan" ]]; then
  exit 0
elif [[ "$CMD" == "get" && "$RES" == "csv" ]]; then
  if [[ "$*" == *"-o jsonpath"* ]]; then
    if [[ "$*" == *"{.status.phase}"* ]]; then
      cat "$MOCK_DATA_DIR/csv_phase" 2>/dev/null || echo "Succeeded"
    elif [[ "$*" == *"{.status."* ]]; then
      echo "csv-status"
    fi
  elif [[ "$*" == *"-o yaml"* ]]; then
    echo "csv-yaml"
  fi
elif [[ "$CMD" == "get" && "$RES" == "installplans" ]]; then
  echo "ip-yaml"
fi
EOF
  chmod +x "$MOCK_BIN/oc"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/usr/bin/env bash
set -euo pipefail
. /utils.sh

for var in FBC_FRAGMENT BUNDLE_IMAGE PACKAGE_NAME CHANNEL_NAME; do
  if [[ -z "${!var}" ]]; then
      echo "Error: $var parameter is required." >&2
      exit 1
  fi
done

# Run opm render on a bundle image
if ! bundle_render_out=$(opm render "$BUNDLE_IMAGE"); then
  echo "Failed to render the bundle image" >&2
  exit 1
fi

# Set the artifact directory path relative to current working directory
ARTIFACT_DIR="workspace/konflux-artifacts"

# Ensure the directory exists
mkdir -p "$ARTIFACT_DIR"

echo "[$(date --utc +%FT%T.%3NZ)] Retrieving 'operatorframework.io/suggested-namespace' metadata annotation if exists..."
INSTALL_NAMESPACE=$(get_bundle_suggested_namespace "$bundle_render_out")

if [[ -z "$INSTALL_NAMESPACE" || "$INSTALL_NAMESPACE" == null ]]; then
  echo "[$(date --utc +%FT%T.%3NZ)] No suggested namespace found, creating a new one"
  NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$INSTALL_NAMESPACE"; then
  echo "[$(date --utc +%FT%T.%3NZ)] Suggested namespace is '$INSTALL_NAMESPACE' which does not exist: creating"
  NS_NAMESTANZA="name: $INSTALL_NAMESPACE"
else
  echo "[$(date --utc +%FT%T.%3NZ)] INSTALL_NAMESPACE is '$INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
  INSTALL_NAMESPACE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
  )
fi

echo "[$(date --utc +%FT%T.%3NZ)] Retrieving bundle install modes..."
if ! TARGET_NAMESPACES=$(get_bundle_install_modes "$bundle_render_out"); then
  echo "Could not get target namespaces for the bundle" >&2
  exit 1
fi

TARGET_NAMESPACES_FINAL=""

# Prioritize install modes in the correct order
if echo "$TARGET_NAMESPACES" | grep -q "AllNamespaces"; then
    echo "AllNamespaces is supported"
    TARGET_NAMESPACES_FINAL=""
elif echo "$TARGET_NAMESPACES" | grep -q "SingleNamespace"; then
    echo "SingleNamespace is supported"
    TARGET_NAMESPACES_FINAL="default"
elif echo "$TARGET_NAMESPACES" | grep -q "OwnNamespace"; then
    echo "OwnNamespace is supported"
    TARGET_NAMESPACES_FINAL="$INSTALL_NAMESPACE"
elif echo "$TARGET_NAMESPACES" | grep -q "MultiNamespace"; then
    echo "MultiNamespace is supported"
    TARGET_NAMESPACES_FINAL="openshift-marketplace,default"
else
    echo "Error: Unsupported TARGET_NAMESPACES value: $TARGET_NAMESPACES" >&2
    exit 1
fi

TARGET_NAMESPACES="$TARGET_NAMESPACES_FINAL"

OPERATORGROUP=$(oc -n "$INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)

if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Error: multiple OperatorGroups in namespace \"$INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    oc -n "$INSTALL_NAMESPACE" get operatorgroup -o yaml >"$ARTIFACT_DIR/operatorgroups-$INSTALL_NAMESPACE.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures!"
    exit 1
elif [[ -n "$OPERATORGROUP" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    OG_OPERATION=apply
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup does not exist: creating it"
    OG_OPERATION=create
    OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
    oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $INSTALL_NAMESPACE
spec:
  targetNamespaces: [$TARGET_NAMESPACES]
EOF
)

echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup name is \"$OPERATORGROUP\""

# Update the image digest with the 0th manifest digest
if updated_fbc_image=$(resolve_to_0th_manifest_digest "$FBC_FRAGMENT"); then
    echo "Updating FBC fragment image from $FBC_FRAGMENT to $updated_fbc_image"
    FBC_FRAGMENT="$updated_fbc_image"
else
    echo "Failed to resolve 0th manifest digest" >&2
    exit 1
fi

CS_NAMESTANZA="generateName: oo-"

CS_MANIFEST=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  $CS_NAMESTANZA
  namespace: $INSTALL_NAMESPACE
spec:
  sourceType: grpc
  image: $FBC_FRAGMENT
  grpcPodConfig:
    securityContextConfig: restricted
    extractContent:
      catalogDir: /configs
      cacheDir: /tmp/cache
EOF
)

echo "[$(date --utc +%FT%T.%3NZ)] Creating CatalogSource:"
echo "$CS_MANIFEST"
CATSRC=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${CS_MANIFEST}" )
echo "[$(date --utc +%FT%T.%3NZ)] CatalogSource name is \"$CATSRC\""

# Waits up to 10 minutes until the Catalog source state is 'READY'
IS_CATSRC_CREATED=false
for i in $(seq 1 120); do
  CATSRC_STATE=$(oc get catalogsources/"$CATSRC" -n "$INSTALL_NAMESPACE" -o jsonpath='{.status.connectionState.lastObservedState}')
  echo $CATSRC_STATE
  if [ "$CATSRC_STATE" = "READY" ]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Catalogsource created successfully after waiting $((5*i)) seconds"
    echo "[$(date --utc +%FT%T.%3NZ)] Current state of catalogsource is \"$CATSRC_STATE\""
    IS_CATSRC_CREATED=true
    break
  fi
  sleep 5
done

if [ $IS_CATSRC_CREATED = false ]; then
  echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for the catalog source $CATSRC to become ready after 10 minutes."
  echo "[$(date --utc +%FT%T.%3NZ)] Catalogsource state at timeout is \"$CATSRC_STATE\""
  CS_ART="$ARTIFACT_DIR/catalogsource-$CATSRC.yaml"
  echo "[$(date --utc +%FT%T.%3NZ)] Dumping CatalogSource $CATSRC as $CS_ART"
  oc get -n "$INSTALL_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
  echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures!"
  exit 1
fi

echo "[$(date --utc +%FT%T.%3NZ)] Set the deployment start time"

SUB_NAMESTANZA="generateName: oo-"

echo "[$(date --utc +%FT%T.%3NZ)] Getting bundle name from image"
if ! bundleName=$(get_bundle_name "$bundle_render_out"); then
  echo "Could not get a bundle name from a given image" >&2
  exit 1
fi

SUB_MANIFEST=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  $SUB_NAMESTANZA
  namespace: $INSTALL_NAMESPACE
spec:
  name: $PACKAGE_NAME
  channel: $CHANNEL_NAME
  source: $CATSRC
  sourceNamespace: $INSTALL_NAMESPACE
  installPlanApproval: Manual
  startingCSV: $bundleName
EOF
)

echo "[$(date --utc +%FT%T.%3NZ)] Creating Subscription:"
echo "${SUB_MANIFEST}"

SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${SUB_MANIFEST}" )

echo "[$(date --utc +%FT%T.%3NZ)] Subscription name is \"$SUB\""

echo "[$(date --utc +%FT%T.%3NZ)] Waiting up to 5 minutes for installPlan to be created"
FOUND_INSTALLPLAN=false
for _ in $(seq 1 60); do
  INSTALL_PLAN=$(oc -n "$INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installplan.name}' || true)

  if [[ -n "$INSTALL_PLAN" ]]; then
    oc -n "$INSTALL_NAMESPACE" patch installPlan "${INSTALL_PLAN}" --type merge --patch '{"spec":{"approved":true}}'
    FOUND_INSTALLPLAN=true
    break
  fi
  sleep 5
done

if [ "$FOUND_INSTALLPLAN" = true ]; then
  echo "[$(date --utc +%FT%T.%3NZ)] Install Plan approved"
  echo "[$(date --utc +%FT%T.%3NZ)] Waiting up to 10 minutes for ClusterServiceVersion to become ready..."

  for _ in $(seq 1 60); do
    CSV=$(oc -n "$INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath="{.status.installedCSV}" || true)
    if [[ -n "$CSV" ]]; then
      if [[ "$(oc -n "$INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion \"$CSV\" ready"
        echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
        exit 0
      fi
    fi
    sleep 10
  done

  echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for CSV to become ready"
else
  echo "[$(date --utc +%FT%T.%3NZ)] Failed to find installPlan for subscription"
fi

NS_ART="$ARTIFACT_DIR/namespace-$INSTALL_NAMESPACE.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping Namespace $INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$INSTALL_NAMESPACE" -o yaml >"$NS_ART"

OG_ART="$ARTIFACT_DIR/operatorgroup-$OPERATORGROUP.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping OperatorGroup $OPERATORGROUP as $OG_ART"
oc get -n "$INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml >"$OG_ART"

CS_ART="$ARTIFACT_DIR/catalogsource-$CATSRC.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping CatalogSource $CATSRC as $CS_ART"
oc get -n "$INSTALL_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
for field in message reason; do
    VALUE="$(oc get -n "$INSTALL_NAMESPACE" catalogsource "$CATSRC" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] CatalogSource $CATSRC status $field: $VALUE"
    fi
done

SUB_ART="$ARTIFACT_DIR/subscription-$SUB.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping Subscription $SUB as $SUB_ART"
oc get -n "$INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "${CSV:-}" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion $CSV was created but never became ready"
    echo "[$(date --utc +%FT%T.%3NZ)] Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/all-csvs-$INSTALL_NAMESPACE.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion was never created"
    echo "[$(date --utc +%FT%T.%3NZ)] Dumping all ClusterServiceVersions in namespace $INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi

INSTALLPLANS_ART="$ARTIFACT_DIR/installPlans-$INSTALL_NAMESPACE.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping all installPlans in namespace $INSTALL_NAMESPACE as $INSTALLPLANS_ART"
oc get -n "$INSTALL_NAMESPACE" installplans -o yaml >"$INSTALLPLANS_ART"

echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures!"
exit 1
SCRIPT_EOF

  sed -i'' -e "s|workspace/konflux-artifacts|$ARTIFACT_DIR|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/utils.sh|$UTILS_FILE|g" "$SCRIPT_FILE"
  chmod +x "$SCRIPT_FILE"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Missing required parameter" {
  export FBC_FRAGMENT=""
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: FBC_FRAGMENT parameter is required."* ]]
}

@test "opm render fails" {
  touch "$MOCK_DATA_DIR/opm_fail"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to render the bundle image"* ]]
}

@test "Successful execution with AllNamespaces" {
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AllNamespaces is supported"* ]]
  [[ "$output" == *"Script Completed Execution Successfully !"* ]]
}

@test "Successful execution with SingleNamespace" {
  echo "SingleNamespace" > "$MOCK_DATA_DIR/install_modes"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SingleNamespace is supported"* ]]
  [[ "$output" == *"Script Completed Execution Successfully !"* ]]
}

@test "Successful execution with OwnNamespace" {
  echo "OwnNamespace" > "$MOCK_DATA_DIR/install_modes"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OwnNamespace is supported"* ]]
  [[ "$output" == *"Script Completed Execution Successfully !"* ]]
}

@test "Successful execution with MultiNamespace" {
  echo "MultiNamespace" > "$MOCK_DATA_DIR/install_modes"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MultiNamespace is supported"* ]]
  [[ "$output" == *"Script Completed Execution Successfully !"* ]]
}

@test "Unsupported install mode" {
  echo "UnsupportedMode" > "$MOCK_DATA_DIR/install_modes"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Unsupported TARGET_NAMESPACES value: UnsupportedMode"* ]]
}

@test "Multiple OperatorGroups error" {
  echo "og1 og2" > "$MOCK_DATA_DIR/operatorgroup"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: multiple OperatorGroups in namespace"* ]]
}

@test "Existing OperatorGroup modified" {
  echo "existing-og" > "$MOCK_DATA_DIR/operatorgroup"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OperatorGroup \"existing-og\" exists: modifying it"* ]]
}

@test "CatalogSource timeout" {
  echo "PENDING" > "$MOCK_DATA_DIR/catsrc_state"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Timed out waiting for the catalog source"* ]]
}

@test "InstallPlan not found" {
  echo "" > "$MOCK_DATA_DIR/installplan_name"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to find installPlan for subscription"* ]]
}

@test "CSV timeout" {
  echo "Pending" > "$MOCK_DATA_DIR/csv_phase"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Timed out waiting for CSV to become ready"* ]]
}

@test "CSV never created" {
  echo "" > "$MOCK_DATA_DIR/installed_csv"
  run "$SCRIPT_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ClusterServiceVersion was never created"* ]]
}

@test "Suggested namespace exists" {
  echo "my-ns" > "$MOCK_DATA_DIR/suggested_namespace"
  touch "$MOCK_DATA_DIR/ns_exists"
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_NAMESPACE is 'my-ns'"* ]]
}
