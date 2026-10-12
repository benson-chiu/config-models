# config-models

YANG model plugins for [onos-config](https://github.com/onosproject/onos-config).

This repository is self-contained: the scripts under `scripts/` build a
plugin from a model directory without any external tooling beyond Go and
Docker.

## What a model plugin is

onos-config ships with no YANG models. It loads them as plugins and uses
them to validate northbound gNMI requests, resolve paths, and decide value
types.

```
onos-config  --gRPC-->  model plugin   (sidecar, one process per model)
                        ValidateConfig / GetPathValues / Capabilities
```

A plugin runs as a sidecar in the onos-config pod and listens on its own
port, so onos-config reaches it over `localhost`. Without a plugin for a
given target type, onos-config rejects every request for that target.

## Layout

```
models/           one directory per model; the plugin source and artifacts
scripts/          build-model.sh and fetch-openroadm.sh
patches/          fixes for ygot and goyang, applied during the build
templates/        Go templates the compiler renders into each plugin
cmd/              model-compiler, the tool that drives generation
pkg/compiler/     compiler internals: metadata parsing, pyang, ygot
pkg/xpath/        XPath parser used for when and must expressions
pkg/gnmi-client-gen/   generates typed gNMI clients from a model
yang-base/        YANG files shared by several models
test/             compiler unit tests
build/            CI helper scripts
```

Inside a model directory, only two paths are inputs:

```
metadata.yaml     the model description (hand-written)
yang/             the YANG files (copied in verbatim)

api/              generated Go bindings
plugin/           generated plugin main
openapi/          generated OpenAPI spec
go.mod go.sum     generated
Makefile          generated: image, test, openapi targets
Dockerfile        generated
*.tree            generated pyang tree, useful for finding paths
```

## Adding a model

Requirements: Go 1.19 or newer, Docker, network access.

### 1. Create the directory

```bash
mkdir -p models/mymodel-1.0.0/yang
cp /path/to/*.yang models/mymodel-1.0.0/yang/
cp VERSION models/mymodel-1.0.0/
```

Copy in every YANG file the model imports, including `ietf-*` and `iana-*`
dependencies. The compiler does not resolve them from anywhere else.

Fetch the revision that the model imports, not the latest one. Some YANG
mirrors serve unsuffixed filenames as symlinks; a 30-byte file downloads
successfully and then fails the build with `no such module`.

### 2. Write metadata.yaml

```yaml
name: mymodel
version: 1.0.0
artifactName: mymodel
goPackage: github.com/onosproject/config-models/models/mymodel-1.0.0
openAPITargetAlias: device-id
licenseName: Apache-2.0
licenseUrl: https://www.apache.org/licenses/LICENSE-2.0
lintModel: false
requireHyphenated: false
formatYang: false
generatorFlags:
  - -ignore_unsupported
modules:
  - name: my-device
    organization: Example Inc
    revision: 2024-01-15
    file: my-device.yang
```

`modules` lists the entry points. A module belongs here if it declares
top-level data nodes **or** augments another module. Augmenting modules are
easy to miss because they do not appear in the dependency closure of the
module they extend: an augment points into someone else's tree. Omitting
one means its nodes never reach the schema, and onos-config then rejects
those paths.

`generatorFlags` are passed to the ygot generator. Two are commonly needed:

```
-ignore_unsupported       skip constructs ygot cannot map to Go, such as
                          notification and rpc, rather than failing. The
                          YANG keeps them; only the Go bindings omit them.
-generate_simple_unions   required when a union type carries a default value
```

Set `lintModel: false` unless the YANG is clean against pyang's RFC 8407
style checks. The flag is a style gate, not a syntax gate.

To list the modules in a directory:

```bash
cd models/mymodel-1.0.0/yang
for f in *.yang; do
  mod=$(grep -m1 -oE "^(module|submodule) +[a-z0-9-]+" "$f" | awk '{print $2}')
  rev=$(grep -m1 -oE "revision +\"?[0-9-]+" "$f" | grep -oE "[0-9-]+$")
  [ -n "$mod" ] && printf -- "  - name: %s\n    revision: %s\n    file: %s\n" \
    "$mod" "$rev" "$f"
done
```

Read the module name from the `module` statement rather than the filename or
indentation; neither is reliable across vendors.

### 3. Build

```bash
./scripts/build-model.sh models/mymodel-1.0.0
```

The script applies the ygot and goyang patches, builds the compiler from
this repository's source, runs it, and compiles the result. Run
`./scripts/build-model.sh` with no arguments to list the available models.

```bash
./scripts/build-model.sh models/mymodel-1.0.0 4     # re-run one step
./scripts/build-model.sh models/mymodel-1.0.0 --no-patches
./scripts/build-model.sh clean                      # drop intermediate files
```

Do not use `make models` for a new model: it runs the published compiler
image, which predates the chunked plugin API and does not apply the patches.

### 4. Check the result

```bash
cd models/mymodel-1.0.0

grep -c ValidateConfigChunked plugin/main.go   # must be non-zero
grep -c "my-device" api/generated.go           # the main module is present
grep replace go.mod                            # must not reference /tmp
```

A plugin without the chunked methods is rejected at load time:

```
code = Unimplemented desc = unknown method ValidateConfigChunked
       for service onos.config.admin.ModelPluginService
```

The generated files belong in version control. Generation is not perfectly
reproducible: map iteration order shifts the order of declarations in
`api/generated.go` between runs. The output is functionally equivalent, so
the artifacts are committed rather than rebuilt.

## OpenROADM

`models/openroadm-13.1.0` is included. To regenerate it, or to fetch a
different release:

```bash
./scripts/fetch-openroadm.sh 13.1.0
./scripts/build-model.sh models/openroadm-13.1.0
```

`fetch-openroadm.sh` clones the OpenROADM MSA repository, copies the YANG
verbatim, fetches the external dependencies at the required revisions, and
generates `metadata.yaml`.

## Deploying to onos-config

### 1. Build the image

```bash
cd models/mymodel-1.0.0
make image
docker tag onosproject/mymodel:$(cat VERSION)-mymodel-1.0.0 mymodel:1.0.0
```

On a containerd-based cluster, import it so the kubelet can see it:

```bash
docker save mymodel:1.0.0 | sudo ctr -n k8s.io images import -
```

On kind, `make kind` builds and loads in one step.

### 2. Add it as a sidecar

Each plugin is a container in the onos-config pod. The port is passed as the
only argument:

```yaml
- name: mymodel-1
  image: mymodel:1.0.0
  imagePullPolicy: Never      # omit when pulling from a registry
  args:
    - '5156'
  ports:
    - name: grpc
      containerPort: 5156
      protocol: TCP
```

Give every plugin a distinct port. onos-config discovers them on
`localhost`, so they must not collide within the pod.

### 3. Verify

```bash
kubectl -n micro-onos exec deploy/onos-cli -- onos config get plugins
```

```
ID                  STATUS    ENDPOINT          INFO.NAME     INFO.VERSION
mymodel-1.0.0       Loaded    localhost:5156    mymodel       1.0.0
```

`STATUS` must be `Loaded`. Anything else is reported in the `ERROR` column;
`onos config get plugins` is the first place to look when onos-config
rejects paths it should accept.

## Using the generated API from Go

The generated `go.mod` declares the upstream module path regardless of where
the repository is checked out, so consumers point at it with a `replace`:

```
replace github.com/onosproject/config-models/models/mymodel-1.0.0/api => \
    /path/to/config-models/models/mymodel-1.0.0/api
```

## License

Apache-2.0. See `LICENSES/`.
