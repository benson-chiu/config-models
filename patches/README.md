# patches

Fixes applied during the build. `scripts/build-model.sh` applies them
automatically; this file documents what they do and how to re-apply them by
hand.

| patch | target | why |
|---|---|---|
| `ygot-v0.28.3-anydata.patch` | `github.com/openconfig/ygot@v0.28.3` | `gogen/gogen.go` aborts on `anydata` and `anyxml` even when `-ignore_unsupported` is set, while `ygen/codegen.go` already skips `AnyDataEntry` unconditionally. Any model declaring `anydata` fails to generate without this. |
| `goyang-v1.4.0-uses-augment.patch` | `github.com/openconfig/goyang@v1.4.0` | `Uses.Augment` holds a single value although RFC 7950 §7.13 allows several, and goyang parses uses-augments into the AST without ever applying them. Also adds lenient merging for conditional augments, enabled by `GOYANG_LENIENT_DUPLICATE=1`. |
| `config-models-generator-flags.patch` | this repository | Adds the `generatorFlags` metadata field so a model can request extra ygot generator options. Already applied in the committed source; kept for re-applying after an upstream merge conflict. |

Both external patches fix upstream gaps that affect any model using the
construct. They are applied by default and change nothing for models that do
not use these features.

## Applying the external patches by hand

The repository pins `ygot v0.28.3` and `goyang v1.4.0`, which is what these
patches target. Copy out of the module cache first: it is read-only.

```bash
cp -r $(go env GOMODCACHE)/github.com/openconfig/ygot@v0.28.3   /tmp/ygot-patched
cp -r $(go env GOMODCACHE)/github.com/openconfig/goyang@v1.4.0  /tmp/goyang-patched
chmod -R u+w /tmp/ygot-patched /tmp/goyang-patched

(cd /tmp/ygot-patched   && patch -p1 < patches/ygot-v0.28.3-anydata.patch)
(cd /tmp/goyang-patched && patch -p1 < patches/goyang-v1.4.0-uses-augment.patch)

go mod edit -replace github.com/openconfig/ygot=/tmp/ygot-patched
go mod edit -replace github.com/openconfig/goyang=/tmp/goyang-patched
```

Revert `go.mod` and `go.sum` once the binaries are built; `/tmp` paths must
not be committed. The build script does this for you.

If a patch no longer applies, the pinned version has changed. Re-create it
against the new version rather than forcing it: both patches touch code paths
where a silent partial application produces a schema that is missing nodes.

See `../README.md` for the full build flow.
