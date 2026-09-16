# patches

Patches required to build some models in this branch. Applied by
`ows-adapter/scripts/build-openroadm-full.sh`.

| patch | target | why |
|---|---|---|
| `config-models-generator-flags.patch` | this repo | Adds the `generatorFlags` metadata field so a model can request extra ygot generator options. Already committed on the APN-C branch — kept here for reference and for re-applying after an upstream merge conflict. |
| `ygot-v0.28.3-anydata.patch` | `github.com/openconfig/ygot@v0.28.3` | `gogen/gogen.go` aborts on `anydata` even though `ygen/codegen.go` already skips `AnyDataEntry`. Needed by `org-openroadm-ltp-template`. |
| `goyang-v1.4.0-uses-augment.patch` | `github.com/openconfig/goyang@v1.4.0` | `Uses.Augment` is a single value but RFC 7950 §7.13 allows several, and goyang never applies uses-augments at all. Also adds lenient merging for conditional augments (opt-in via `GOYANG_LENIENT_DUPLICATE=1`). |

## Applying the external ones

The repo pins `ygot v0.28.3` and `goyang v1.4.0`, which is exactly what these
patches target.

```bash
cp -r $(go env GOMODCACHE)/github.com/openconfig/ygot@v0.28.3   /tmp/ygot-patched
cp -r $(go env GOMODCACHE)/github.com/openconfig/goyang@v1.4.0  /tmp/goyang-patched
chmod -R u+w /tmp/ygot-patched /tmp/goyang-patched

(cd /tmp/ygot-patched   && patch -p1 < patches/ygot-v0.28.3-anydata.patch)
(cd /tmp/goyang-patched && patch -p1 < patches/goyang-v1.4.0-uses-augment.patch)

go mod edit -replace github.com/openconfig/ygot=/tmp/ygot-patched
go mod edit -replace github.com/openconfig/goyang=/tmp/goyang-patched
```

Revert `go.mod` and `go.sum` once the binaries are built — `/tmp` paths must
not be committed. The build script does this automatically.

See `README-APN-C.md` for the full build flow.
