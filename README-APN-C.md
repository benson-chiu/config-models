# APN-C branch

這個 branch 在 `onosproject/config-models` 的基礎上加入 APN-C 專案需要的
model plugin。**只在這個 branch 開發，不動 `master` 與其他 branch。**

```
upstream   https://github.com/onosproject/config-models
origin     git@github.com:benson-chiu/config-models.git
branch     APN-C
```

---

## 與 master 的差異（只有兩處）

### 一、新增 `models/openroadm-13.1.0`

OpenROADM MSA **13.1.0** 全部 95 個 YANG 模組，供採用 OpenROADM 的
OWS switch 使用。YANG 一字未改，與官方 repo 逐位元一致，
可作為 OpenROADM 定義的參考。

```
yang             102 檔（95 OpenROADM + 7 外部相依）
metadata         91 個進入點模組
generated.go     約 113,900 行
openroadm.tree   約 9,930 節點
主模組 revision  2023-05-26（org-openroadm-device）
notification 35 個、rpc 82 個完整保留在 YANG
```

### 二、`pkg/compiler` 加 `generatorFlags` 欄位

讓個別 model 指定額外的 ygot generator 參數：

```yaml
# models/<model>/metadata.yaml
generatorFlags:
  - -ignore_unsupported
  - -generate_simple_unions
```

原本 `generateGolangBindings()` 的參數完全硬編碼，無法從 metadata 補。

**刻意做成 per-model 而非無條件加上** —— `-generate_simple_unions` 會改變
union 的 Go 表示方式，無條件開啟會影響其他既有 model 的產出。
沒設定這個欄位時完全不影響原本行為（附加邏輯用 `len() > 0` 判斷）。

改動檔案：`pkg/compiler/metadata.go`、`pkg/compiler/compiler.go`、
`pkg/compiler/metadata_test.go`、`test/metadata/valid.yaml`。

---

## module path 刻意保持 `github.com/onosproject/config-models`

沒有改成 `github.com/benson-chiu/config-models`。理由是這樣
`git merge upstream/master` 不會在 `go.mod` 與各 model 的 `goPackage` 衝突。

代價是不能直接 `go get`，使用端要 replace：

```go
// ows-adapter/go.mod
require github.com/onosproject/config-models/models/openroadm-13.1.0 v0.0.0

replace github.com/onosproject/config-models/models/openroadm-13.1.0 => \
    /home/vagrant/config-models/models/openroadm-13.1.0
```

---

## 重新產生 openroadm model

```bash
cd ~/ows-adapter
. ~/apnc-topology-contract/env.sh
./scripts/build-openroadm-full.sh          # 8 步全跑
./scripts/build-openroadm-full.sh 6        # 只跑 compiler
./scripts/build-openroadm-full.sh clean    # 清中間產物（不動這個 repo）
```

腳本**不會執行 git commit** —— 產物驗證完只會提示指令。

用 `OPENROADM_REPO=<path>` 可指定不同的 repo 位置。

### 為什麼不能直接用官方 model-compiler image

`onosproject/model-compiler:latest` **建於 2022-12-13**，比上游 repo 最新
commit（2023-05-20）舊一年半。它內建的 `templates/main.go.tpl` 還沒有
chunked 方法，產生的 plugin 只有 `ValidateConfig`，部署到 onos-config
v1.1.4 會失敗：

```
code = Unimplemented desc = unknown method ValidateConfigChunked
       for service onos.config.admin.ModelPluginService
```

所以要**用這個 repo 的原始碼自建 compiler**（`CGO_ENABLED=0`，binary 要
掛進 alpine 容器）：

```bash
CGO_ENABLED=0 go build -ldflags="-s -w" -o /tmp/mc-repo ./cmd/model-compiler
CGO_ENABLED=0 go build -ldflags="-s -w" -o /tmp/generator-repo \
    github.com/openconfig/ygot/generator
```

### 需要兩個外部 patch

完整的 OpenROADM 會撞到 ygot 與 goyang 的限制。patch 檔在這個 repo 的 `patches/`。雖然 ygot / goyang 的 patch 是外部 module
的改動，但既然這個 fork 不打算 merge 回上游，放在一起比較不容易失聯 ——
clone 一份 repo 就有建置需要的全部東西。

| patch | 解決什麼 |
|---|---|
| `ygot-v0.28.3-anydata.patch` | `org-openroadm-ltp-template` 的 `anydata`。ygot 的 `ygen/codegen.go` 對 `AnyDataEntry` 已跳過，但 `gogen/gogen.go` 的 default 分支沒有對應處理 —— 上游疏漏 |
| `goyang-v1.4.0-uses-augment.patch` | `uses` 內的 augment（RFC 7950 §7.13 允許多個，goyang 的 `Uses.Augment` 是單值且**根本沒實作套用邏輯**，上游至今未修）＋ 條件式 augment 的同名節點寬容合併 |

這個 repo 的 `ygot v0.28.3` 與 `goyang v1.4.0` **與 patch 的版本完全一致**：

```bash
cp -r $(go env GOMODCACHE)/github.com/openconfig/ygot@v0.28.3 /tmp/ygot-patched
cp -r $(go env GOMODCACHE)/github.com/openconfig/goyang@v1.4.0 /tmp/goyang-patched
chmod -R u+w /tmp/ygot-patched /tmp/goyang-patched
(cd /tmp/ygot-patched   && patch -p1 < $REPO/patches/ygot-v0.28.3-anydata.patch)
(cd /tmp/goyang-patched && patch -p1 < $REPO/patches/goyang-v1.4.0-uses-augment.patch)

go mod edit -replace github.com/openconfig/ygot=/tmp/ygot-patched
go mod edit -replace github.com/openconfig/goyang=/tmp/goyang-patched
```

> **這兩個 replace 建完 binary 就要還原**（`git checkout -- go.mod go.sum`）。
> `/tmp` 是環境相依路徑，不可留在 repo 裡。各 model 的 `go.mod` 同樣不含它們。
> 建置腳本會自動處理。

### 執行 compiler

只借官方 image 的 `pyang`，其餘全用自建的：

```bash
sudo docker run --rm \
  -e GOYANG_LENIENT_DUPLICATE=1 \
  -v $PWD/models/openroadm-13.1.0:/config-model \
  -v $PWD/templates:/var/model-compiler/templates:ro \
  -v /tmp/mc-repo:/usr/local/bin/mc-repo:ro \
  -v /tmp/generator-repo:/usr/local/bin/generator:ro \
  --entrypoint /usr/local/bin/mc-repo \
  onosproject/model-compiler:latest
```

**`templates` 一定要掛。** compiler 用相對路徑 `templates/` 找模板
（`pkg/compiler/template.go`），容器工作目錄是 `/var/model-compiler`，
不掛就會用 image 內建的舊模板，自建 compiler 就白費了。

`GOYANG_LENIENT_DUPLICATE=1` 啟用 goyang patch 的條件式 augment 寬容合併
（`org-openroadm-network-topology` 與 `org-openroadm-otn-network-topology`
都 augment 到 `/nd:networks/nd:network/nd:node` 並各加一個
`container xpdr-attributes`，以 `when` 條件互斥）。

### 驗證產出

```bash
grep -c ValidateConfigChunked models/openroadm-13.1.0/plugin/main.go   # 應 ≥ 1
grep onos-api models/openroadm-13.1.0/go.mod                          # 應為 v0.10.31
grep -c '^module: org-openroadm-device$' models/openroadm-13.1.0/openroadm.tree  # 應為 1
grep -c '/tmp/' models/openroadm-13.1.0/go.mod                        # 應為 0
```

---

## 已知陷阱

### 一、metadata.yaml 的 modules 必須列出全部 augment 模組

`augment` 的方向是「**別的模組 import device**」，那些模組不在
`org-openroadm-device` 的相依樹裡。只列主模組時，即使 `yang/` 放了全部
檔案，產物也**完全不會變**（實測 `generated.go` 停在 11,799 行）。

openroadm 有 91 個進入點模組。

### 二、判斷「頂層 container」不能用縮排

OpenROADM 各檔案縮排不一致：

```
org-openroadm-alarm.yang     頂層 container 縮排 2 空格
org-openroadm-device.yang    頂層 container 縮排 4 空格
```

寫死 `^  container` 會漏掉 `org-openroadm-device` 這個最重要的模組。

**這個缺陷極隱蔽**：建置不失敗、Go 綁定仍有 device 型別（其他模組
augment 到它時會一併載入）、端到端配置也成功。唯一症狀是
`openroadm.tree` 少了 `module: org-openroadm-device` 段。

建置腳本改用大括號深度判斷，並加了斷言。

### 三、產物不完全可重現

同一份輸入連續產生兩次，`api/generated.go` 會有差異。

**差異範圍已確認且有限**：

```
型別集合（1,339 個）         完全相同
欄位 path 集合（4,809 個）    完全相同
差異                         只有 3 個欄位的 module 標註
                             （recolor、xpdr-attributes、xpdr-number）
```

那 3 個欄位就是條件式 augment 衝突的節點，`module` 標註在
`org-openroadm-network-topology`、`org-openroadm-otn-network-topology`、
`org-openroadm-network` 之間搖擺 —— 取決於 goyang 內部 map 的迭代順序
（Go 的 map 迭代是隨機的），這是上游的設計，goyang 從未保證產出可重現。

**功能上沒有影響**：那 3 個欄位都在 `/networks` 子樹，屬 controller 層，
會被 adapter 的 path 白名單擋掉，不會送到設備。

**實務上的影響**：重新產生後 `git diff` 會顯示 8 萬多行變動（因為型別的
產生順序也跟著變），但那不是實質變更。要確認是否有實質變更，比對集合：

```bash
git show HEAD:models/openroadm-13.1.0/api/generated.go > /tmp/old.go
for f in /tmp/old.go models/openroadm-13.1.0/api/generated.go; do
  grep -oE '^type [A-Za-z_0-9]+' "$f" | sort > "$f.types"
  grep -oE 'path:"[^"]+"'         "$f" | sort > "$f.paths"
done
cmp /tmp/old.go.types models/openroadm-13.1.0/api/generated.go.types  # 應相同
cmp /tmp/old.go.paths models/openroadm-13.1.0/api/generated.go.paths  # 應相同
```

兩個都相同就表示沒有實質變更，可以不必重新 commit。

### 四、openapi.yaml 無法產生

```
unhandled dirEntry create-tech-info-notification.Type <nil>
```

`openapi-gen` 走 schema 樹時撞到 notification 節點。我們用
`-ignore_unsupported` 讓 ygot 跳過 notification（YANG 完整保留、Go 綁定
只含 config），但 pyang 產生的 schema 仍含那些節點。

**不影響 plugin 功能** —— onos-config 不讀 `openapi.yaml`，它是 REST
文件用的附帶產物。要修需改 `templates/openapi-gen.go.tpl`。
`openapi/openapi-gen.go` 仍保留（compiler 產生的），只是不執行。
其他 model 不受影響。

---

## 哪些檔案要進版控

依官方慣例（`git ls-files models/devicesim-1.0.x`），**產出物也要 commit**：

```
yang/  metadata.yaml  VERSION  Makefile  Dockerfile
api/generated.go  api/model.go  plugin/main.go
openroadm.tree  go.mod  go.sum  openapi/openapi-gen.go
```

`.gitignore` 只排除 binary 與 vendor。

**各 model 的 `go.mod` 不可含 `/tmp/...` 的 replace** —— 環境相依路徑。

---

## 同步上游

```bash
git fetch upstream
git checkout master && git merge upstream/master && git push
git checkout APN-C && git merge master
```

因為 module path 保持一致、且我們只**新增** `models/openroadm-13.1.0/`
與**小幅擴充** `pkg/compiler/`，衝突面很小。

可能衝突的三個檔案：

| 檔案 | 衝突原因 | 處理 |
|---|---|---|
| `pkg/compiler/metadata.go` | 上游改 `MetaData` 結構 | 保留 `GeneratorFlags` 欄位 |
| `pkg/compiler/compiler.go` | 上游改 `generateGolangBindings()` | 保留附加 `GeneratorFlags` 的區塊 |
| `test/metadata/valid.yaml` | 上游改 fixture | 保留 `generatorFlags` |

如果上游採納了類似機制，就移除我們的版本改用上游的。

---

## 新增其他 model 時

1. `models/<name>-<version>/` 放 `yang/` 與 `metadata.yaml`
2. 需要額外的 generator 選項時用 `generatorFlags`
3. 撞到 ygot / goyang 的限制時，patch 放 `patches/` 並在
   `patches/README.md` 與本文件記錄
4. 產出物依官方慣例要 commit
5. `go.mod` 不可含環境相依路徑
