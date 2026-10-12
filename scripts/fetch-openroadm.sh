#!/usr/bin/env bash
#
# fetch-openroadm.sh — populate a model directory from the OpenROADM MSA
# repository and generate its metadata.yaml.
#
# Usage:
#   ./scripts/fetch-openroadm.sh              fetch the default version
#   ./scripts/fetch-openroadm.sh 13.1.0       fetch a specific version
#
# After this finishes, build the plugin with:
#   ./scripts/build-model.sh models/openroadm-<version>
#
# This script is specific to OpenROADM. For your own model, create the
# directory by hand as described in the README and go straight to
# build-model.sh.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

VER=${1:-13.1.0}
SRC=/tmp/openroadm-$VER
DEST=$REPO/models/openroadm-$VER

hr(){ printf '%.0s-' $(seq 1 78); echo; }
step(){ echo; hr; printf '  %s\n' "$1"; hr; }
cmd(){ printf '\n  \033[36m$ %s\033[0m\n' "$*"; }
out(){ sed 's/^/    /'; }

# ====================================================================
step "1. Clone OpenROADM $VER"

cmd "git clone --depth 1 -b $VER https://github.com/OpenROADM/OpenROADM_MSA_Public.git"
if [ -d "$SRC/model" ]; then
  echo "    Already present, skipping" | out
else
  rm -rf "$SRC"
  if ! timeout 400 git clone --depth 1 -b "$VER" -q \
      https://github.com/OpenROADM/OpenROADM_MSA_Public.git "$SRC" 2>&1 | tail -2 | out; then
    echo "    Clone failed. Check the version tag and network access." | out
    exit 1
  fi
fi

total=$(find "$SRC" -name "*.yang" 2>/dev/null | wc -l)
if [ "$total" -eq 0 ]; then
  echo "    No YANG files found under $SRC" | out
  exit 1
fi
cmd "# Source tree"
for d in "$SRC"/model/*/; do
  n=$(find "$d" -name "*.yang" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && printf "    %-14s %3s files\n" "$(basename "$d")" "$n"
done
printf "    %-14s %3s files\n" "total" "$total"

# ====================================================================
step "2. Copy YANG into models/openroadm-$VER/yang"

rm -rf "$DEST"; mkdir -p "$DEST/yang"
cmd "cp \$SRC/model/**/*.yang -> yang/    # verbatim, no edits"
find "$SRC" -name "*.yang" -exec cp {} "$DEST/yang/" \;
printf "    OpenROADM modules: %s\n" "$(find "$DEST/yang" -name '*.yang' | wc -l)"

cmd "# External dependencies"
echo "    The revision must match what OpenROADM imports exactly, so each" | out
echo "    file is fetched with its revision suffix. Fetching the unsuffixed" | out
echo "    name yields a 30-byte symlink: the download succeeds but the" | out
echo "    compiler then reports 'no such module'." | out
echo
B="https://raw.githubusercontent.com/YangModels/yang/main"
fetch_fail=0
for spec in \
  "standard/ietf/RFC:ietf-inet-types@2013-07-15" \
  "standard/ietf/RFC:ietf-yang-types@2013-07-15" \
  "standard/ietf/RFC:ietf-netconf@2011-06-01" \
  "standard/ietf/RFC:ietf-network@2018-02-26" \
  "standard/ietf/RFC:ietf-network-topology@2018-02-26" \
  "experimental/ietf-extracted-YANG-modules:iana-afn-safi@2013-07-04"; do
  dir="${spec%%:*}"; mod="${spec#*:}"; base="${mod%@*}"
  curl -sSfL "$B/$dir/${mod//@/%40}.yang" -o "$DEST/yang/$base.yang" 2>/dev/null
  sz=$(stat -c %s "$DEST/yang/$base.yang" 2>/dev/null || echo 0)
  if [ "$sz" -gt 2000 ]; then
    printf "    %-26s %7s bytes  ok\n" "$base" "$sz"
  else
    printf "    %-26s %7s bytes  TOO SMALL (symlink?)\n" "$base" "$sz"
    fetch_fail=1
  fi
done
[ "$fetch_fail" -eq 1 ] && { echo; echo "  External dependency fetch failed." | out; exit 1; }

# ietf-interfaces is already vendored by the devicesim model.
cp "$REPO/models/devicesim-1.0.x/yang/ietf-interfaces@2014-05-08.yang" \
   "$DEST/yang/" 2>/dev/null
cp "$REPO/VERSION" "$DEST/" 2>/dev/null

# ====================================================================
step "3. Generate metadata.yaml"

cmd "# Key settings"
echo "    lintModel: false   skip the pyang RFC 8407 style checks; the" | out
echo "                       OpenROADM modules report 118 style issues" | out
echo "                       that are not syntax errors" | out
echo "    generatorFlags     -ignore_unsupported keeps notification and rpc" | out
echo "                       in the YANG while excluding them from the Go" | out
echo "                       bindings, which ygot cannot map" | out
echo "                       -generate_simple_unions is needed by the union" | out
echo "                       default value in org-openroadm-tca" | out
echo
echo "    The modules list must name every module that augments another," | out
echo "    not just the ones with their own top-level nodes. An augment" | out
echo "    points into someone else's tree, so it never appears in the" | out
echo "    dependency closure of the module it extends." | out

DEST="$DEST" VER="$VER" python3 - <<'PY' | out
import re, glob, os

dest = os.environ["DEST"]
ver = os.environ["VER"]

header = f"""name: openroadm
version: {ver}
artifactName: openroadm
goPackage: github.com/onosproject/config-models/models/openroadm-{ver}
openAPITargetAlias: device-id
contactName: config-models
contactUrl: https://github.com/onosproject/config-models
contactEmail: config-models@example.org
licenseName: Apache-2.0
licenseUrl: https://www.apache.org/licenses/LICENSE-2.0
lintModel: false
requireHyphenated: false
formatYang: false
generatorFlags:
  - -ignore_unsupported
  - -generate_simple_unions
modules:
"""


def has_toplevel_data(text):
    """Report whether the module declares a container or list directly.

    Brace depth is used rather than indentation because the OpenROADM files
    are not consistently indented: org-openroadm-alarm indents its top-level
    container by two spaces while org-openroadm-device uses four. Matching on
    indentation drops org-openroadm-device, which is the most important
    module, and the failure is near-invisible: the build succeeds, the Go
    bindings still contain the device types because other modules augment it,
    and end-to-end configuration works. The only symptom is a tree file with
    no device section.
    """
    depth = 0
    for m in re.finditer(r'(\{|\}|^[ \t]*(?:container|list)\s+[\w.-]+)', text, re.M):
        token = m.group(1)
        if token == '{':
            depth += 1
        elif token == '}':
            depth -= 1
        elif depth == 1:
            return True
    return False


entries = []
for path in sorted(glob.glob(f"{dest}/yang/*.yang")):
    text = open(path, encoding='utf-8', errors='ignore').read()
    m = re.search(r'^\s*module\s+([\w-]+)', text, re.M)
    if not m or not m.group(1).startswith("org-openroadm"):
        continue
    # An entry module either augments another tree or owns top-level data.
    if re.search(r'^\s*augment\s', text, re.M) or has_toplevel_data(text):
        rev = re.search(r'revision\s+"?([0-9]{4}-[0-9]{2}-[0-9]{2})', text)
        entries.append((m.group(1),
                        rev.group(1) if rev else "2020-01-01",
                        os.path.basename(path)))

with open(f"{dest}/metadata.yaml", "w") as fh:
    fh.write(header)
    for name, rev, filename in entries:
        fh.write(f"  - name: {name}\n    organization: Open ROADM MSA\n"
                 f"    revision: {rev}\n    file: {filename}\n")

print(f"Entry modules: {len(entries)}")
names = [n for n, _, _ in entries]
assert "org-openroadm-device" in names, "org-openroadm-device was not listed"
print("org-openroadm-device is listed")
PY

if ! grep -q "generatorFlags" "$DEST/metadata.yaml" 2>/dev/null; then
  echo "  metadata.yaml generation failed" | out
  exit 1
fi

# ====================================================================
step "4. Verify the YANG is unmodified"

diffcount=0
for f in "$SRC"/model/*/*.yang; do
  b=$(basename "$f")
  [ -f "$DEST/yang/$b" ] && { cmp -s "$f" "$DEST/yang/$b" || diffcount=$((diffcount+1)); }
done
printf "    OpenROADM files differing from upstream: %s\n" "$diffcount"

echo
hr
printf '  Model directory ready: models/openroadm-%s\n' "$VER"
printf '    yang/          %s files\n' "$(find "$DEST/yang" -name '*.yang' | wc -l)"
printf '    metadata.yaml  %s entry modules\n' "$(grep -c '\- name:' "$DEST/metadata.yaml")"
echo
printf '  Next: ./scripts/build-model.sh models/openroadm-%s\n' "$VER"
hr
[ "$diffcount" -eq 0 ]
