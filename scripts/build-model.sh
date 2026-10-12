#!/usr/bin/env bash
#
# build-model.sh — build a config-model plugin from a model directory.
#
# Usage:
#   ./scripts/build-model.sh <model-dir>              run every step
#   ./scripts/build-model.sh <model-dir> 3            run one step
#   ./scripts/build-model.sh <model-dir> --no-patches use upstream ygot/goyang
#   ./scripts/build-model.sh clean                    drop intermediate files
#
# Example:
#   ./scripts/build-model.sh models/openroadm-13.1.0
#
# Requirements: Go 1.19+, Docker, network access.
#
# The model directory must contain:
#   metadata.yaml   model description (see README)
#   yang/           the YANG files
#
# Everything else (api/, plugin/, go.mod, *.tree, openapi/) is generated.
#
# ---------------------------------------------------------------------
# Why the compiler is built from source
# ---------------------------------------------------------------------
#
# The published onosproject/model-compiler image was built in 2022 and its
# bundled templates/main.go.tpl predates the chunked plugin API. A plugin
# produced by that image is rejected by onos-config v1.1.4:
#
#   code = Unimplemented desc = unknown method ValidateConfigChunked
#          for service onos.config.admin.ModelPluginService
#
# This repository's templates/ already emit the chunked methods, so the
# compiler is built from the local source tree and mounted into the image.
# Only pyang is taken from the image.
#
# ---------------------------------------------------------------------
# Why ygot and goyang are patched
# ---------------------------------------------------------------------
#
# Both patches fix upstream gaps that affect any model using the construct,
# not just OpenROADM. They are applied by default and are no-ops for models
# that do not use these features. Pass --no-patches to skip them.
#
#   ygot-v0.28.3-anydata.patch        anydata/anyxml nodes abort generation
#                                     even with -ignore_unsupported
#   goyang-v1.4.0-uses-augment.patch  augment inside uses is parsed but never
#                                     applied (RFC 7950 section 7.13)
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

PATCHES=$REPO/patches
TEMPLATES=$REPO/templates
MC_IMAGE=${MODEL_COMPILER_IMAGE:-onosproject/model-compiler:latest}

YGOT_VER=${YGOT_VER:-v0.28.3}
GOYANG_VER=${GOYANG_VER:-v1.4.0}

APPLY_PATCHES=1

PASS=0; FAIL=0
hr(){ printf '%.0s-' $(seq 1 78); echo; }
step(){ echo; hr; printf '  Step %s: %s\n' "$1" "$2"; hr; }
cmd(){ printf '\n  \033[36m$ %s\033[0m\n' "$*"; }
out(){ sed 's/^/    /'; }
ok(){   printf '\n  \033[32m[OK]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){  printf '\n  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

do_clean(){
  echo "  Removing intermediate files..."
  rm -rf /tmp/ygot-patched /tmp/goyang-patched /tmp/cm-compiler /tmp/cm-generator
  echo "  Done. Model directories are left untouched."
}

# ====================================================================
s1(){
  step 1 "Check prerequisites"

  cmd "go version"
  if ! command -v go >/dev/null 2>&1; then
    bad "Go not found in PATH. Install Go 1.19 or newer:
      https://go.dev/dl/
    If Go is installed elsewhere, add it to PATH first."
    return
  fi
  go version | out

  cmd "docker info"
  if ! sudo docker info >/dev/null 2>&1; then
    bad "Docker is not usable. The compiler runs inside a container to
    reuse its pyang installation."
    return
  fi
  echo "    Docker is available" | out

  cmd "# Model directory layout"
  if [ ! -f "$MODEL_DIR/metadata.yaml" ]; then
    bad "$MODEL_DIR/metadata.yaml not found. See README for the format."
    return
  fi
  local nyang
  nyang=$(find "$MODEL_DIR/yang" -name "*.yang" 2>/dev/null | wc -l)
  printf "    metadata.yaml  %s entry modules\n" "$(grep -c '\- name:' "$MODEL_DIR/metadata.yaml")"
  printf "    yang/          %s files\n" "$nyang"
  if [ "$nyang" -eq 0 ]; then
    bad "$MODEL_DIR/yang/ holds no .yang files"
    return
  fi

  cmd "# Repository templates must emit the chunked plugin API"
  local n
  n=$(grep -c "ValidateConfigChunked" "$TEMPLATES/main.go.tpl" 2>/dev/null; true)
  printf "    templates/main.go.tpl  %s references to ValidateConfigChunked\n" "$n"
  if [ "$n" -eq 0 ]; then
    bad "templates/main.go.tpl does not emit the chunked methods.
    A plugin built from it will be rejected by onos-config v1.1.4."
    return
  fi

  ok "Prerequisites satisfied"
}

s2(){
  step 2 "Prepare ygot and goyang"

  if [ "$APPLY_PATCHES" -eq 0 ]; then
    echo "    --no-patches given, using upstream versions" | out
    ok "Skipped (upstream ygot/goyang)"
    return
  fi

  local M; M=$(go env GOMODCACHE)
  if [ ! -d "$M/github.com/openconfig/ygot@$YGOT_VER" ]; then
    cmd "go mod download   # populate the module cache"
    ( cd "$REPO" && timeout 600 go mod download github.com/openconfig/ygot \
        github.com/openconfig/goyang 2>&1 | head -3 | out )
  fi

  cmd "# Copy from the module cache, then patch the copy"
  echo "    The cache itself is read-only and must not be modified." | out
  for spec in "ygot@$YGOT_VER:ygot-patched:ygot-$YGOT_VER-anydata" \
              "goyang@$GOYANG_VER:goyang-patched:goyang-$GOYANG_VER-uses-augment"; do
    IFS=: read -r src dst pf <<< "$spec"
    if [ ! -d "$M/github.com/openconfig/$src" ]; then
      bad "$M/github.com/openconfig/$src not in the module cache.
    Run 'go mod download' in the repository root first."
      return
    fi
    rm -rf "/tmp/$dst"
    cp -r "$M/github.com/openconfig/$src" "/tmp/$dst"
    chmod -R u+w "/tmp/$dst"
    if ( cd "/tmp/$dst" && patch -p1 -s --forward < "$PATCHES/$pf.patch" ); then
      printf "    %-44s applied\n" "$pf.patch"
    else
      printf "    %-44s FAILED\n" "$pf.patch"
      bad "Patch did not apply. The pinned version may have changed;
    see patches/README.md."
      return
    fi
  done

  cmd "# Verify the patches took effect"
  local pok=1
  grep -q "no Go representation" /tmp/ygot-patched/gogen/gogen.go \
    && echo "    ygot    anydata nodes are skipped" | out || { echo "    ygot    MISSING" | out; pok=0; }
  grep -q "Augment     \[\]\*Augment" /tmp/goyang-patched/pkg/yang/yang.go \
    && echo "    goyang  Uses.Augment is a slice" | out || { echo "    goyang  MISSING" | out; pok=0; }
  grep -q "lenientDuplicate" /tmp/goyang-patched/pkg/yang/entry.go \
    && echo "    goyang  lenient merge for conditional augments" | out || { echo "    goyang  MISSING" | out; pok=0; }
  [ "$pok" -eq 0 ] && { bad "Patch verification failed"; return; }

  ok "Patched copies ready under /tmp"
}

s3(){
  step 3 "Build the model compiler and the ygot generator"

  cd "$REPO" || return
  cmd "go mod edit -replace ... && go build ./cmd/model-compiler"

  if [ "$APPLY_PATCHES" -eq 1 ]; then
    go mod edit -replace "github.com/openconfig/ygot=/tmp/ygot-patched"
    go mod edit -replace "github.com/openconfig/goyang=/tmp/goyang-patched"
  fi

  # A static binary is required: it is mounted into an Alpine-based image.
  export CGO_ENABLED=0

  if timeout 900 go build -ldflags="-s -w" -o /tmp/cm-compiler ./cmd/model-compiler 2>/tmp/cm-build.log; then
    printf "    model-compiler  %s\n" "$(stat -c %s /tmp/cm-compiler | numfmt --to=iec 2>/dev/null)"
  else
    head -6 /tmp/cm-build.log | cut -c1-150 | out
    git checkout -- go.mod go.sum 2>/dev/null
    bad "model-compiler build failed"
    return
  fi

  if timeout 900 go build -ldflags="-s -w" -o /tmp/cm-generator github.com/openconfig/ygot/generator 2>/tmp/cm-gen.log; then
    printf "    ygot generator  %s\n" "$(stat -c %s /tmp/cm-generator | numfmt --to=iec 2>/dev/null)"
  else
    head -6 /tmp/cm-gen.log | cut -c1-150 | out
    git checkout -- go.mod go.sum 2>/dev/null
    bad "generator build failed"
    return
  fi

  cmd "git checkout -- go.mod go.sum   # drop the /tmp replace directives"
  echo "    Those paths are machine-specific and must not be committed." | out
  echo "    The binaries are built, so later steps do not need them." | out
  git checkout -- go.mod go.sum 2>/dev/null
  local tmpn; tmpn=$(grep -c "/tmp/" go.mod 2>/dev/null; true)
  printf "    /tmp paths left in go.mod: %s\n" "$tmpn"

  [ "$tmpn" -eq 0 ] && ok "Compiler and generator built, go.mod restored" \
    || bad "go.mod still carries machine-specific paths"
}

s4(){
  step 4 "Run the compiler"

  cmd "sudo docker run --rm \\
      -e GOYANG_LENIENT_DUPLICATE=1 \\
      -v $MODEL_DIR:/config-model \\
      -v $TEMPLATES:/var/model-compiler/templates:ro \\
      -v /tmp/cm-compiler:/usr/local/bin/cm-compiler:ro \\
      -v /tmp/cm-generator:/usr/local/bin/generator:ro \\
      --entrypoint /usr/local/bin/cm-compiler \\
      $MC_IMAGE"
  echo
  echo "    What each mount is for:" | out
  echo "      /config-model   model input and generated output" | out
  echo "      templates       required: the compiler resolves templates by" | out
  echo "                      relative path from /var/model-compiler, so" | out
  echo "                      without this mount the image's 2022 templates" | out
  echo "                      are used and the plugin loses the chunked API" | out
  echo "      generator       patched ygot generator" | out
  echo "      cm-compiler     locally built compiler" | out
  echo "    Only pyang is taken from the image." | out

  timeout 2400 sudo docker run --rm \
    -e GOYANG_LENIENT_DUPLICATE=1 \
    -v "$MODEL_DIR":/config-model \
    -v "$TEMPLATES":/var/model-compiler/templates:ro \
    -v /tmp/cm-compiler:/usr/local/bin/cm-compiler:ro \
    -v /tmp/cm-generator:/usr/local/bin/generator:ro \
    --entrypoint /usr/local/bin/cm-compiler \
    "$MC_IMAGE" > /tmp/cm-run.log 2>&1
  local rc=$?
  printf "    exit=%s\n" "$rc"

  cmd "# Generation steps"
  grep -aoE "(Appending generator flags.*|Generating [A-Za-z ]+'[^']+')" /tmp/cm-run.log \
    | cut -c1-110 | out

  if [ "$rc" -ne 0 ]; then
    cmd "# Errors"
    grep -aE "ERROR|error:" /tmp/cm-run.log | grep -avE "^\s+/go|^\s+/usr" \
      | head -4 | cut -c1-160 | out
    bad "Compiler failed (full log: /tmp/cm-run.log)"
    return
  fi

  sudo chown -R "$(id -u):$(id -g)" "$MODEL_DIR"

  cmd "# The generated plugin must expose the chunked methods"
  grep -oE "^func \(s server\) [A-Za-z]+" "$MODEL_DIR/plugin/main.go" | awk '{print "    "$4}'
  local ch; ch=$(grep -c "ValidateConfigChunked" "$MODEL_DIR/plugin/main.go")

  [ "$ch" -gt 0 ] && ok "Compiler finished, plugin exposes the chunked API" \
    || bad "plugin/main.go lacks the chunked methods: templates were not mounted"
}

s5(){
  step 5 "Compile the generated code"

  cd "$MODEL_DIR" || return
  cmd "go mod tidy && go build ./api/ ./plugin/"

  if [ "$APPLY_PATCHES" -eq 1 ]; then
    go mod edit -replace "github.com/openconfig/ygot=/tmp/ygot-patched" 2>/dev/null
    go mod edit -replace "github.com/openconfig/goyang=/tmp/goyang-patched" 2>/dev/null
  fi
  export CGO_ENABLED=0
  timeout 900 go mod tidy 2>&1 | grep -viE "download|finding|extract" | head -3 | out

  if timeout 900 go build ./api/ 2>/tmp/cm-api.log; then
    echo "    api package compiles" | out
  else
    head -6 /tmp/cm-api.log | cut -c1-155 | out
    cd "$REPO"; bad "api package does not compile"; return
  fi

  if timeout 900 go build -ldflags="-s -w" -o /tmp/cm-plugin ./plugin/ 2>/tmp/cm-plugin.log; then
    printf "    plugin binary  %s  %s\n" \
      "$(stat -c %s /tmp/cm-plugin | numfmt --to=iec 2>/dev/null)" \
      "$(file /tmp/cm-plugin | grep -oE 'statically linked|dynamically linked')"
  else
    head -6 /tmp/cm-plugin.log | cut -c1-155 | out
    cd "$REPO"; bad "plugin does not compile"; return
  fi

  cd "$REPO"
  ok "Generated code compiles"
}

s6(){
  step 6 "Summarise the artifacts"

  if [ ! -f "$MODEL_DIR/api/generated.go" ]; then
    bad "No artifacts found; an earlier step did not succeed"
    return
  fi

  local tree
  tree=$(find "$MODEL_DIR" -maxdepth 1 -name "*.tree" | head -1)

  cmd "# Artifacts in $MODEL_DIR"
  printf "    api/generated.go  %s lines\n" "$(wc -l < "$MODEL_DIR/api/generated.go")"
  printf "    yang/             %s files\n" "$(find "$MODEL_DIR/yang" -name '*.yang' | wc -l)"
  printf "    metadata.yaml     %s entry modules\n" "$(grep -c '\- name:' "$MODEL_DIR/metadata.yaml")"
  [ -n "$tree" ] && printf "    %-17s %s rw/ro nodes\n" "$(basename "$tree")" \
    "$(grep -cE '\+--(rw|ro)' "$tree")"
  printf "    plugin/main.go    chunked methods: %s\n" \
    "$(grep -c ValidateConfigChunked "$MODEL_DIR/plugin/main.go")"

  cmd "# go.mod must not carry machine-specific paths"
  local tmpn; tmpn=$(grep -c "/tmp/" "$MODEL_DIR/go.mod" 2>/dev/null; true)
  if [ "$tmpn" -gt 0 ]; then
    printf "    found %s /tmp replace directives, removing\n" "$tmpn"
    python3 - <<PYEOF
import re
p = "$MODEL_DIR/go.mod"
s = open(p).read()
s = re.sub(r'^replace github.com/openconfig/(ygot|goyang) => /tmp/.*\n', '', s, flags=re.M)
open(p, "w").write(s)
PYEOF
    echo "    removed" | out
  else
    echo "    clean" | out
  fi

  cmd "# Next steps"
  echo "    Build the plugin image:" | out
  printf "      cd %s && make image\n" "${MODEL_DIR#"$REPO"/}" | out
  echo "    Then add it as a sidecar to the onos-config deployment." | out
  echo "    See README for the deployment snippet." | out

  ok "Artifacts ready"
}

# ====================================================================
[ "${1:-}" = "clean" ] && { do_clean; exit 0; }

if [ $# -eq 0 ]; then
  echo "Usage: $0 <model-dir> [step...] [--no-patches]" >&2
  echo "       $0 clean" >&2
  echo >&2
  echo "Available models:" >&2
  for d in "$REPO"/models/*/; do
    [ -f "$d/metadata.yaml" ] && echo "  models/$(basename "$d")" >&2
  done
  exit 1
fi

MODEL_ARG=$1; shift
MODEL_DIR=$(cd "$MODEL_ARG" 2>/dev/null && pwd)
if [ -z "${MODEL_DIR:-}" ]; then
  echo "Model directory not found: $MODEL_ARG" >&2
  exit 1
fi

sel=()
for a in "$@"; do
  case $a in
    --no-patches) APPLY_PATCHES=0 ;;
    [1-6])        sel+=("$a") ;;
    *)            echo "Unknown argument: $a" >&2; exit 1 ;;
  esac
done
[ ${#sel[@]} -eq 0 ] && sel=(1 2 3 4 5 6)

printf '\n  Model:    %s\n' "${MODEL_DIR#"$REPO"/}"
printf '  Patches:  %s\n' "$([ "$APPLY_PATCHES" -eq 1 ] && echo "ygot + goyang" || echo "none")"

for i in "${sel[@]}"; do
  case $i in
    1) s1 ;; 2) s2 ;; 3) s3 ;; 4) s4 ;; 5) s5 ;; 6) s6 ;;
  esac
done

echo
hr
printf '  Total: \033[32mOK %d\033[0m  \033[31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
hr
[ "$FAIL" -eq 0 ]
