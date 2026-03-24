#!/bin/bash
# migrate-layers.sh
# Migrates a single layer and its style from one GeoServer to another using the REST API.
# Usage: ./migrate-layers.sh <src_env> <tgt_env> <src_workspace> <tgt_workspace> <layer_name>
#   <src_env>: source environment name (e.g., dev, tst, prd)
#   <tgt_env>: destination environment name (e.g., dev, tst, prd)
#   <src_workspace>: source GeoServer workspace name
#   <tgt_workspace>: target GeoServer workspace name
#   <layer_name>: Name of the layer to migrate

# Exit immediately if a command exits with a non-zero status
set -e

# Get the parameters
SRC_NAME="$1"
TGT_NAME="$2"
SRC_WORKSPACE="$3"
TGT_WORKSPACE="$4"
LAYER="$5"

# Show usage if any parameter is missing
if [ -z "$SRC_NAME" ] || [ -z "$TGT_NAME" ] || [ -z "$SRC_WORKSPACE" ] || [ -z "$TGT_WORKSPACE" ] || [ -z "$LAYER" ]; then
  echo "Usage: $0 <src_env> <tgt_env> <src_workspace> <tgt_workspace> <layer_name>"
  echo "  <src_env>: source environment name (e.g., dev, tst, prd)"
  echo "  <tgt_env>: destination environment name (e.g., dev, tst, prd)"
  echo "  <src_workspace>: source GeoServer workspace name"
  echo "  <tgt_workspace>: target GeoServer workspace name"
  echo "  <layer_name>: Name of the layer to migrate"
  exit 1
fi

# Define env file names based on parameters
SRC_ENV=".env.$SRC_NAME"
TGT_ENV=".env.$TGT_NAME"

# Load source env
if [ ! -f "$SRC_ENV" ]; then
  echo "Source env file $SRC_ENV not found!"; exit 1;
fi
set -a
source "$SRC_ENV"
SRC_URL="$GEOSERVER_URL"
SRC_USER="$GEOSERVER_USER"
SRC_PASS="$GEOSERVER_PASS"
set +a

# Load target env
if [ ! -f "$TGT_ENV" ]; then
  echo "Target env file $TGT_ENV not found!"; exit 1;
fi
set -a
source "$TGT_ENV"
TGT_URL="$GEOSERVER_URL"
TGT_USER="$GEOSERVER_USER"
TGT_PASS="$GEOSERVER_PASS"
set +a

# Reload GeoServer config for both source and target before starting
echo "Reloading GeoServer configuration on source ($SRC_NAME) and target ($TGT_NAME)..."
curl -XPOST -u "$SRC_USER:$SRC_PASS" "$SRC_URL/reload"
curl -XPOST -u "$TGT_USER:$TGT_PASS" "$TGT_URL/reload"
echo "Reload requests sent. Waiting a few seconds for reload to complete..."
sleep 5

# Display migration summary
echo
echo "Migrating layer $SRC_WORKSPACE:$LAYER to $TGT_WORKSPACE:$LAYER"
echo "Source: $SRC_URL"
echo "Target: $TGT_URL"
echo
echo "Processing layer: $LAYER"

# Ensure tmp directory exists
mkdir -p ./tmp

# Check if source workspace exists
echo "Checking if source workspace '$SRC_WORKSPACE' exists on $SRC_URL..."
WORKSPACE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -u "$SRC_USER:$SRC_PASS" "$SRC_URL/workspaces/$SRC_WORKSPACE.json")
if [ "$WORKSPACE_CHECK" = "200" ]; then
  echo "Source workspace '$SRC_WORKSPACE' exists."
else
  echo "Source workspace '$SRC_WORKSPACE' does not exist or is not accessible. Aborting."
  exit 2
fi

# Check if source layer exists
echo "Checking if source layer '$LAYER' exists in workspace '$SRC_WORKSPACE'..."
SRC_LAYER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -u "$SRC_USER:$SRC_PASS" "$SRC_URL/workspaces/$SRC_WORKSPACE/layers/$LAYER.json")
if [ "$SRC_LAYER_CHECK" = "200" ]; then
  echo "Source layer '$LAYER' exists."
else
  echo "Source layer '$LAYER' does not exist or is not accessible. Aborting."
  exit 2
fi

# Fetch layer config from source (JSON)
echo "Fetching layer config from: $SRC_URL/workspaces/$SRC_WORKSPACE/layers/$LAYER.json"
curl -s -u "$SRC_USER:$SRC_PASS" "$SRC_URL/workspaces/$SRC_WORKSPACE/layers/$LAYER.json" -o "./tmp/$LAYER.json"

# Export layer config (JSON)
curl -f -s -u "$SRC_USER:$SRC_PASS" -H "Accept: application/json" \
  "$SRC_URL/workspaces/$SRC_WORKSPACE/layers/$LAYER.json" -o "./tmp/$LAYER-layer.json" || { echo "Failed to fetch layer config"; exit 2; }

# Auto-discover datastore from layer JSON
RESOURCE_HREF=$(jq -r '.layer.resource.href' "./tmp/$LAYER-layer.json")
if [ -z "$RESOURCE_HREF" ] || [ "$RESOURCE_HREF" = "null" ]; then
  echo "Could not find resource href in layer config."; exit 2;
fi

# The resource href is like .../workspaces/<ws>/datastores/<datastore>/featuretypes/<featuretype>.json
DATASTORE=$(echo "$RESOURCE_HREF" | sed -E 's#.*/datastores/([^/]+)/featuretypes/.*#\1#')
if [ -z "$DATASTORE" ]; then
  echo "Could not extract datastore from resource href: $RESOURCE_HREF"; exit 2;
fi

echo "Discovered datastore: $DATASTORE"

# Export featuretype config (JSON)
FEATURETYPE_URL="$SRC_URL/workspaces/$SRC_WORKSPACE/datastores/$DATASTORE/featuretypes/$LAYER.json"
echo "Fetching featuretype config from: $FEATURETYPE_URL"
set +e
CURL_OUTPUT=$(curl -v -f -u "$SRC_USER:$SRC_PASS" -H "Accept: application/json" "$FEATURETYPE_URL" -o "./tmp/$LAYER-ft.json" 2>&1)
CURL_EXIT=$?
set -e
if [ $CURL_EXIT -ne 0 ]; then
  echo "Failed to fetch featuretype config. Curl output was:"
  echo "$CURL_OUTPUT"
  exit 2
fi

# Get style name from layer config (JSON)
STYLE=$(jq -r '.layer.defaultStyle.name' "./tmp/$LAYER-layer.json")
if [ -z "$STYLE" ] || [ "$STYLE" = "null" ]; then
  echo "Could not determine style for $LAYER, skipping."
  exit 1
fi

echo "Found style: $STYLE"

# Export style SLD (fetch only from global styles)
GLOBAL_STYLE_SLD_URL="$SRC_URL/styles/$STYLE.sld"
set +e
curl -f -s -u "$SRC_USER:$SRC_PASS" -H "Accept: application/vnd.ogc.sld+xml" \
  "$GLOBAL_STYLE_SLD_URL" -o "./tmp/$STYLE.sld"
CURL_EXIT=$?
if [ $CURL_EXIT -ne 0 ]; then
  echo "Failed to fetch style SLD from global styles."
  exit 2
fi
set -e

# Find image references (png, jpg, jpeg, gif) in the SLD 
IMAGES=$(grep -oE '([a-zA-Z0-9_.\/\-]+\.(png|jpg|jpeg|gif))' "./tmp/$STYLE.sld" | sort | uniq)
if [ -n "$IMAGES" ]; then
  echo "Found image references in SLD: $IMAGES"
  for IMG in $IMAGES; do
    # Download the image from the source GeoServer, overwriting any local copy
    SRC_IMG_URL="$SRC_URL/resource/styles/$IMG"
    echo "Downloading $IMG from $SRC_IMG_URL ..."
    set +e
    curl -f -s -u "$SRC_USER:$SRC_PASS" "$SRC_IMG_URL" -o "./tmp/$IMG"
    CURL_EXIT=$?
    set -e
    if [ $CURL_EXIT -eq 0 ] && [ -f "./tmp/$IMG" ]; then
      echo "Downloaded $IMG from source GeoServer."
      IMG_PATH="./tmp/$IMG"
    else
      echo "Warning: Could not download $IMG from source GeoServer (curl exit code $CURL_EXIT). Skipping upload."
      continue
    fi

    # Determine content type based on extension
    EXT="${IMG##*.}"
    case "$EXT" in
      png)  CONTENT_TYPE="image/png" ;;
      jpg)  CONTENT_TYPE="image/jpeg" ;;
      jpeg) CONTENT_TYPE="image/jpeg" ;;
      gif)  CONTENT_TYPE="image/gif" ;;
      *)    CONTENT_TYPE="application/octet-stream" ;;
    esac

    # Upload image to target GeoServer styles resource endpoint
    echo "Uploading $IMG_PATH to $TGT_URL/resource/styles/$IMG ..."
    curl -XPUT "$TGT_URL/resource/styles/$IMG" \
      -u "$TGT_USER:$TGT_PASS" \
      --data-binary "@$IMG_PATH" \
      -H "Content-Type: $CONTENT_TYPE" -v
  done
else
  echo "No image references found in SLD."
fi

# Check if target workspace exists
echo "Checking if target workspace '$TGT_WORKSPACE' exists on $TGT_URL..."
WORKSPACE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -u "$TGT_USER:$TGT_PASS" "$TGT_URL/workspaces/$TGT_WORKSPACE.json")
if [ "$WORKSPACE_CHECK" = "200" ]; then
  echo "Target workspace '$TGT_WORKSPACE' exists."
else
  echo "Target workspace '$TGT_WORKSPACE' does not exist or is not accessible. Aborting."
  exit 2
fi

# Check if style exists in target (global only)
STYLE_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$TGT_USER:$TGT_PASS" "$TGT_URL/styles/$STYLE.sld")
if [ "$STYLE_EXISTS" = "200" ]; then
  echo "Style $STYLE already exists in target (global). Skipping import."
else
  # Import style to target (global SLD)
  set +e
  CURL_OUTPUT=$(curl -f -s -u "$TGT_USER:$TGT_PASS" -XPOST -H "Content-Type: application/vnd.ogc.sld+xml" \
    --data-binary "@./tmp/$STYLE.sld" "$TGT_URL/styles?name=$STYLE" 2>&1)
  CURL_EXIT=$?
  set -e
  if [ $CURL_EXIT -ne 0 ]; then
    echo "Failed to import style to target (global). Curl output was:"
    echo "$CURL_OUTPUT"
    echo "Style SLD was:"
    cat "./tmp/$STYLE.sld"
    exit 2
  fi
fi

# Clean the layer JSON for import
# Only remove .layer.defaultStyle.href and set .layer.enabled = true
jq 'del(.layer.defaultStyle.href) | .layer.enabled = true' "./tmp/$LAYER.json" > "./tmp/$LAYER-clean.json"
mv "./tmp/$LAYER-clean.json" "./tmp/$LAYER.json"

# Ensure feature type exists in target before importing layer
FT_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$TGT_USER:$TGT_PASS" "$TGT_URL/workspaces/$TGT_WORKSPACE/datastores/$DATASTORE/featuretypes/$LAYER.json")
if [ ! -f "./tmp/$LAYER-ft.json" ]; then
  echo "Feature type JSON file ./tmp/$LAYER-ft.json does not exist. Skipping feature type import."
  exit 2
fi
if [ "$FT_EXISTS" != "200" ]; then
  echo "Feature type $LAYER does not exist in target. Importing feature type..."
  set +e
  CURL_OUTPUT=$(curl -f -s -u "$TGT_USER:$TGT_PASS" -XPOST -H "Content-Type: application/json" \
    -d @"./tmp/$LAYER-ft.json" "$TGT_URL/workspaces/$TGT_WORKSPACE/datastores/$DATASTORE/featuretypes" 2>&1)
  CURL_EXIT=$?
  set -e
  if [ $CURL_EXIT -ne 0 ]; then
    echo "Failed to import feature type to target. Curl output was:"
    echo "$CURL_OUTPUT"
    echo "Feature type JSON was:"
    cat "./tmp/$LAYER-ft.json"
    exit 2
  fi
else
  echo "Feature type $LAYER already exists in target. Overwriting with PUT..."
fi
# Always PUT feature type to ensure overwrite
set +e
CURL_OUTPUT=$(curl -f -s -u "$TGT_USER:$TGT_PASS" -XPUT -H "Content-Type: application/json" \
  -d @"./tmp/$LAYER-ft.json" "$TGT_URL/workspaces/$TGT_WORKSPACE/datastores/$DATASTORE/featuretypes/$LAYER" 2>&1)
CURL_EXIT=$?
set -e
if [ $CURL_EXIT -ne 0 ]; then
  echo "Failed to update feature type in target. Curl output was:"
  echo "$CURL_OUTPUT"
  echo "Feature type JSON was:"
  cat "./tmp/$LAYER-ft.json"
  exit 2
fi

# Check if layer exists in target
LAYER_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$TGT_USER:$TGT_PASS" "$TGT_URL/workspaces/$TGT_WORKSPACE/layers/$LAYER.json")
if [ "$LAYER_EXISTS" = "200" ]; then
  echo "Layer $LAYER already exists in target. Updating with PUT."
  if [ ! -f "./tmp/$LAYER.json" ]; then
    echo "Layer JSON file ./tmp/$LAYER.json does not exist. Skipping layer update."
    exit 2
  fi
  set +e
  CURL_OUTPUT=$(curl -f -s -u "$TGT_USER:$TGT_PASS" -XPUT -H "Content-Type: application/json" \
    -d @"./tmp/$LAYER.json" "$TGT_URL/workspaces/$TGT_WORKSPACE/layers/$LAYER" 2>&1)
  CURL_EXIT=$?
  set -e
  if [ $CURL_EXIT -ne 0 ]; then
    echo "Failed to update layer config in target. Curl output was:"
    echo "$CURL_OUTPUT"
    echo "Layer JSON was:"
    cat "./tmp/$LAYER.json"
    exit 2
  fi
else
  # Import layer config to target (JSON)
  if [ ! -f "./tmp/$LAYER.json" ]; then
    echo "Layer JSON file ./tmp/$LAYER.json does not exist. Skipping layer import."
    exit 2
  fi
  set +e
  CURL_OUTPUT=$(curl -f -s -u "$TGT_USER:$TGT_PASS" -XPOST -H "Content-Type: application/json" \
    -d @"./tmp/$LAYER.json" "$TGT_URL/workspaces/$TGT_WORKSPACE/layers" 2>&1)
  CURL_EXIT=$?
  set -e
  if [ $CURL_EXIT -ne 0 ]; then
    echo "Failed to import layer config to target. Curl output was:"
    echo "$CURL_OUTPUT"
    echo "Layer JSON was:"
    cat "./tmp/$LAYER.json"
    exit 2
  fi
fi

echo "Comparing source and target layer configs for $LAYER..."

# Fetch final source and target layer configs
curl -s -u "$SRC_USER:$SRC_PASS" "$SRC_URL/workspaces/$SRC_WORKSPACE/layers/$LAYER.json" -o "./tmp/$LAYER-src-final.json"
curl -s -u "$TGT_USER:$TGT_PASS" "$TGT_URL/workspaces/$TGT_WORKSPACE/layers/$LAYER.json" -o "./tmp/$LAYER-tgt-final.json"

# Extract and normalize key fields for comparison
jq '{name: .layer.name, defaultStyle: .layer.defaultStyle.name, resource: .layer.resource.name}' "./tmp/$LAYER-src-final.json" > "./tmp/$LAYER-src-compare.json"
jq '{name: .layer.name, defaultStyle: .layer.defaultStyle.name, resource: .layer.resource.name}' "./tmp/$LAYER-tgt-final.json" > "./tmp/$LAYER-tgt-compare.json"

# Compare the normalized JSON
if diff "./tmp/$LAYER-src-compare.json" "./tmp/$LAYER-tgt-compare.json" > /dev/null; then
  echo "Source and target layers match on key fields."
else
  echo "WARNING: Source and target layers differ! See diff below:"
  diff "./tmp/$LAYER-src-compare.json" "./tmp/$LAYER-tgt-compare.json"
fi

# Reload GeoServer config for target to ensure new layer and style are active
echo "Reloading GeoServer configuration on target ($TGT_NAME)..."
curl -XPOST -u "$TGT_USER:$TGT_PASS" "$TGT_URL/reload"
echo "Reload request sent to target. Waiting a few seconds for reload to complete..."
sleep 5

# Display migration summary
echo "Migrated $LAYER and style $STYLE."
echo "Migration complete."