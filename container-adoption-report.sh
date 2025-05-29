#!/bin/bash
# container-adoption-report.sh
# Show adoption of Chainguard Images
#
# Copyright (c) 2025 Chainguard, Inc.
# SPDX-License-Identifier: MIT

set -eu

# Restrictive permissions for new files
umask 077

# Config
SLEEP_TIME="${SLEEP_TIME:-300}"
HTTP_PORT="${HTTP_PORT:-9090}"
METRIC_FILE="/node-exporter/container-security.prom"
CACHE_FILE="/tmp/image-metrics.json"
TMP_METRIC_FILE="/tmp/container-security.prom.tmp"
METRICS_CACHE="/tmp/latest_metrics.prom"
CSV_CACHE="/tmp/latest_metrics.csv"
INDEX_FILE="/tmp/cg-base-index.txt"
MAX_AGE_HOURS=24
OUTPUT_FILE="${1:-/data/adoption.csv}"  # Allow path as argument, default to /data/adoption.csv
CLUSTER_NAME="${CLUSTER_NAME:-default_cluster}" # Cluster label for metrics (default: "default_cluster")
[ -z "$CLUSTER_NAME" ] && CLUSTER_NAME="default_cluster"

# Mode detection
MODE_COUNT=0
[ "${WRITE_CSV:-}" = "TRUE" ] && MODE="CSV" && MODE_COUNT=$((MODE_COUNT+1))
[ "${OPENMETRICS:-}" = "TRUE" ] && MODE="OPENMETRICS" && MODE_COUNT=$((MODE_COUNT+1))
[ -z "${MODE:-}" ] && MODE="DEFAULT"
if [ "$MODE_COUNT" -gt 1 ]; then
  echo "ERROR: Only one mode (WRITE_CSV or OPENMETRICS) can be active at a time." >&2
  exit 1
fi

# Debug logging
info() { echo "$@" >&2; }
if [ "${DEBUG:-}" = "TRUE" ]; then
  set -x
  info "DEBUG MODE ENABLED"
fi

info "Using cluster label: $CLUSTER_NAME"

# Authorize chainctl
if [ -n "${CHAINCTL_IDENTITY_TOKEN:-}" ]; then
  chainctl auth login --identity-token="$CHAINCTL_IDENTITY_TOKEN" --refresh || {
    info "chainctl login failed!"; exit 1;
  }
else
  info "CHAINCTL_IDENTITY_TOKEN env var not set!"; exit 1
fi

# Graceful shutdown support
CLEANUP_PID=""
cleanup() {
  if [ -n "$CLEANUP_PID" ] && kill -0 "$CLEANUP_PID" 2>/dev/null; then
    kill "$CLEANUP_PID"
    wait "$CLEANUP_PID" 2>/dev/null || true
  fi
  info "Received termination signal. Exiting."
  exit 0
}
trap cleanup INT TERM

ensure_cg_index() {
  # Check if the index file exists and is fresh
  if [ -f "$INDEX_FILE" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$INDEX_FILE")) / 3600 ))
    if [ "$AGE_HOURS" -lt "$MAX_AGE_HOURS" ]; then
      info "Using cached Chainguard base layer index (last updated $AGE_HOURS hours ago): $INDEX_FILE"
      return 0
    else
      info "Index file is stale ($AGE_HOURS hours old), rebuilding..."
    fi
  else
    info "Index file missing, building for the first time..."
  fi

  CHAINCTL_OUTPUT=$(chainctl image list --output=terse) || { info "chainctl failed!"; exit 2; }
  if [ -z "$CHAINCTL_OUTPUT" ]; then
    info "No images returned by chainctl; aborting index build."
    exit 2
  fi
  > "$INDEX_FILE"  

  MAX_PROCS=8
  count=0

  while IFS= read -r IMAGE_LINE; do
    (
      IMAGE="${IMAGE_LINE%@sha256*}@${IMAGE_LINE##*@}"
      BASE_LAYERS=$(crane config "$IMAGE" | jq -r '.rootfs.diff_ids[]' 2>/dev/null) || {
        info "crane config failed for $IMAGE, skipping..."
        exit
      }
      for LAYER in $BASE_LAYERS; do
        echo "$LAYER $IMAGE_LINE"
      done
    ) >> "$INDEX_FILE" &
    count=$((count+1))
    if (( count >= MAX_PROCS )); then
      wait -n
      count=$((count-1))
    fi
  done <<< "$CHAINCTL_OUTPUT"

  wait

  if [ ! -s "$INDEX_FILE" ]; then
    info "ERROR: Base index build failed or is empty!"
    exit 3
  fi

  info "Chainguard base layer index rebuilt: $INDEX_FILE ($(wc -l < "$INDEX_FILE") lines)"
}

# Containerd socket detection
detect_containerd_socket() {
  for sock in \
    /run/containerd/containerd.sock \
    /run/k3s/containerd/containerd.sock \
    /run/k0s/containerd.sock; do
    if [ -S "$sock" ]; then
      crictl --runtime-endpoint "unix://$sock" images >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        export CONTAINER_RUNTIME_ENDPOINT="unix://$sock"
        export IMAGE_SERVICE_ENDPOINT="unix://$sock"
        info "Detected working CRI endpoint=$CONTAINER_RUNTIME_ENDPOINT"
        return 0
      fi
    fi
  done
  info "No working containerd socket found!"
  return 1
}

# Image metrics collector (BusyBox sh)
collect_image_metrics() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) PLATFORM="linux/amd64" ;;
    aarch64) PLATFORM="linux/arm64" ;;
    *) PLATFORM="linux/amd64" ;;
  esac

  touch "$CACHE_FILE"
  [ ! -s "$CACHE_FILE" ] && echo '{}' > "$CACHE_FILE"

  CRICTL_JSON=$(crictl images -o json 2>/dev/null)
  echo "$CRICTL_JSON" | jq -e '.' >/dev/null 2>&1 || {
    info "ERROR: crictl did not return valid JSON. Aborting image scan."
    exit 2
  }

  NUM_IMAGES=$(echo "$CRICTL_JSON" | jq '.images | length')
  IMAGES=""
  [ "$NUM_IMAGES" -gt 0 ] && IMAGES=$(echo "$CRICTL_JSON" | jq -r '.images[]?.repoTags[]?' 2>/dev/null | tr '\n' ' ')

  # Load cache
  CACHE=$(cat "$CACHE_FILE")
  PRESENT_IMAGES=""
  CHAINGUARD_IMAGES=""
  NON_CHAINGUARD_IMAGES=""
  METRICS_LINES=""

  for IMAGE in $IMAGES; do
    PRESENT_IMAGES="$PRESENT_IMAGES $IMAGE"
    DIGEST=$(crane digest "$IMAGE" 2>/dev/null || true)
    [ -z "$DIGEST" ] && info "Could not fetch digest for $IMAGE, skipping." && continue
    CACHED_DIGEST=$(echo "$CACHE" | jq -r --arg img "$IMAGE" '.[$img].digest // empty')
    if [ "$DIGEST" = "$CACHED_DIGEST" ]; then
      METRICS=$(echo "$CACHE" | jq -r --arg img "$IMAGE" '.[$img].metrics[]?' )
      [ -n "$METRICS" ] && METRICS_LINES="$METRICS_LINES
$METRICS"
    else
      VENDOR=$(crane manifest "$IMAGE" 2>/dev/null | jq -r '.annotations["org.opencontainers.image.vendor"] // "unknown"')

      if [[ "$VENDOR" != "chainguard" ]]; then
        # Check all layers for a CG base match
        LAYERS=$(crane config "$IMAGE" | jq -r '.rootfs.diff_ids[]')
        for LAYER in $LAYERS; do
          if grep -q "^$LAYER " "$INDEX_FILE"; then
            VENDOR="chainguard"
            break
          fi
        done
        [[ -z "$VENDOR" ]] && VENDOR="unknown"
      fi

      NAME=$(echo "$IMAGE" | cut -d':' -f1)
      VERSION=$(echo "$IMAGE" | cut -d':' -f2)
      SIZE=$(crane manifest "$IMAGE" --platform="$PLATFORM" 2>/dev/null | jq '[.layers[].size] | add // 0' 2>/dev/null || echo 0)
      
      METRICS_LINES="$METRICS_LINES
node_container_image_info{image=\"$NAME\",version=\"$VERSION\",vendor=\"$VENDOR\",cluster=\"$CLUSTER_NAME\"} 1"
      METRICS_LINES="$METRICS_LINES
node_container_image_size_bytes{image=\"$NAME\",version=\"$VERSION\",vendor=\"$VENDOR\",cluster=\"$CLUSTER_NAME\"} $SIZE"
      
      TRIVY_OUTPUT=$(trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --format json "$IMAGE" 2>/dev/null || echo "")
      if [ -n "$TRIVY_OUTPUT" ]; then
        for sev in CRITICAL HIGH MEDIUM LOW; do
          COUNT=$(echo "$TRIVY_OUTPUT" | jq "[.Results[]? | .Vulnerabilities? // [] | .[]? | select(.Severity == \"$sev\")] | length" 2>/dev/null || echo 0)
          METRICS_LINES="$METRICS_LINES
container_cve_count{image=\"$NAME\",version=\"$VERSION\",severity=\"$sev\",cluster=\"$CLUSTER_NAME\"} $COUNT"
        done
      fi
      
      METRICS_JSON=$(echo "$METRICS_LINES" | jq -R . | jq -s .)
      CACHE=$(echo "$CACHE" | jq --arg img "$IMAGE" --arg dig "$DIGEST" --argjson met "$METRICS_JSON" '.[$img] = {"digest": $dig, "metrics": $met}')
    fi

    case "$IMAGE" in
      cgr.dev/chainguard/*) CHAINGUARD_IMAGES="$CHAINGUARD_IMAGES $IMAGE" ;;
      *) NON_CHAINGUARD_IMAGES="$NON_CHAINGUARD_IMAGES $IMAGE" ;;
    esac
  done

  for OLD_IMAGE in $(echo "$CACHE" | jq -r 'keys[]'); do
    echo " $PRESENT_IMAGES " | grep -q " $OLD_IMAGE " || CACHE=$(echo "$CACHE" | jq --arg img "$OLD_IMAGE" 'del(.[$img])')
  done

  echo "$CACHE" > "$CACHE_FILE"

  # Export results for metrics and CSV
  export CHAINGUARD_IMAGES NON_CHAINGUARD_IMAGES IMAGES METRICS_LINES
}

generate_csv() {
  # Check that OUTPUT_FILE is set
  if [ -z "${OUTPUT_FILE:-}" ]; then
    info "ERROR: OUTPUT_FILE is not set."
    exit 10
  fi

  # Check if directory exists and is writable
  OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
  if [ ! -d "$OUTPUT_DIR" ]; then
    info "ERROR: Output directory '$OUTPUT_DIR' does not exist."
    exit 11
  fi
  if [ ! -w "$OUTPUT_DIR" ]; then
    info "ERROR: Output directory '$OUTPUT_DIR' is not writable."
    exit 12
  fi

  # Check if file exists, and if so, is writable
  if [ -e "$OUTPUT_FILE" ] && [ ! -w "$OUTPUT_FILE" ]; then
    info "ERROR: Output file '$OUTPUT_FILE' is not writable."
    exit 13
  fi

  # Collect metrics
  TOTAL=$(echo $IMAGES | wc -w)
  CG_TOTAL=$(echo $CHAINGUARD_IMAGES | wc -w)
  NON_CG_TOTAL=$(echo $NON_CHAINGUARD_IMAGES | wc -w)
  if [ "$TOTAL" -eq 0 ]; then
    PERCENT="0"
  else
    PERCENT=$(awk "BEGIN {printf \"%.1f\", ($CG_TOTAL/$TOTAL)*100}")
  fi

  # Write header if file is empty/non-existent
  if [ ! -s "$OUTPUT_FILE" ]; then
    echo "cluster_name,hostname,date,total_images,chainguard_images,non_chainguard_images,adoption_percentage" >> "$OUTPUT_FILE"
  fi

  # Append row
  echo "$CLUSTER_NAME,$(hostname),$(date -Iseconds),$TOTAL,$CG_TOTAL,$NON_CG_TOTAL,$PERCENT" >> "$OUTPUT_FILE"

  # Log message on success
  info "Wrote adoption metrics row to $OUTPUT_FILE"
}

generate_metrics() {
  TMP_METRICS_FILE="${METRICS_CACHE}.tmp"
  {
    echo "# HELP node_container_image_info Container image information"
    echo "# TYPE node_container_image_info gauge"
    echo "# HELP node_container_image_size_bytes Size of images in bytes"
    echo "# TYPE node_container_image_size_bytes gauge"
    echo "# HELP container_cve_count Number of CVEs per container by severity"
    echo "# TYPE container_cve_count gauge"
    echo "$METRICS_LINES"
  } > "$TMP_METRICS_FILE"
  mv "$TMP_METRICS_FILE" "$METRICS_CACHE"
}

# Main always-on openmetrics server
main_openmetrics() {
  detect_containerd_socket || exit 3

  # Metrics collector loop in foreground in a subshell, with error handling
  (
    while true; do
      ensure_cg_index
      collect_image_metrics
      generate_metrics
      sleep "$SLEEP_TIME"
    done
  ) &
  CLEANUP_PID=$!

  info "Starting OpenMetrics HTTP server on port $HTTP_PORT (BusyBox mode, always-on)"
  # Serve HTTP requests forever; if metrics collector dies, exit
  while true; do
    if ! kill -0 "$CLEANUP_PID" 2>/dev/null; then
      info "Metrics collection loop died! Exiting."
      exit 1
    fi
    { echo -ne "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"; cat "$METRICS_CACHE"; } | nc -l -p "$HTTP_PORT" -s 0.0.0.0
  done
}

# Main CSV mode
main_csv() {
  detect_containerd_socket || exit 3
  ensure_cg_index
  collect_image_metrics
  generate_csv
}

# Main default mode
main_default() {
  detect_containerd_socket || exit 3
  while true; do
    ensure_cg_index
    collect_image_metrics
    generate_metrics
    TMP_METRIC_FILE="${METRIC_FILE}.tmp"
    cp "$METRICS_CACHE" "$TMP_METRIC_FILE"
    mv "$TMP_METRIC_FILE" "$METRIC_FILE"
    sleep "$SLEEP_TIME"
  done
}

case "$MODE" in
  CSV)
    main_csv
    ;;
  OPENMETRICS)
    main_openmetrics
    ;;
  DEFAULT)
    main_default
    ;;
esac
