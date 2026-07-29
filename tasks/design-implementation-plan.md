# container-compose 最終設計(精査済み改訂版)

`tasks/container-compose-plugin-要望.md` の10項目と `tasks/todo.md` の残課題を統合した、目指す最終形の設計と実装計画。初版に対しコードベースの徹底検証と設計レビューを行い、欠けていた工程(CLI テスト可能化・CI)、順序問題(パーサ再構築の位置)、隠れた技術リスク(actor 直列化、ハッシュ汚染、二重パース)を織り込んだ。

## ゴール

1. **Compose 互換** — Docker Compose 用の compose ファイルが無修正で `container compose up` で動く。engine の機能欠落で避けられない差は、原因と回避策を warning で即座に示す。
2. **状態の同定はラベルが唯一の真実** — コンテナ名は表示と DNS のための属性。`ps` / `down` / `logs` / 再作成判定はすべて `com.composeforcontainer.*` ラベルで引く。
3. **silent failure ゼロ** — 起動直後に死んだサービス、chown で落ちる bind mount、黙って無視される引数やキー、いずれも `up` の出力だけで原因に到達できる。

## 非ゴール(明示的スコープ外)

「やらない」と決めたものを列挙する。silent に落とすのではなく、該当箇所で warning / エラー / README 記載のいずれかで可視化する。

| 項目 | 扱い |
|---|---|
| `restart` policy の実装(D9) | 警告のみ。engine 側に機能がなく、launchd で埋めるのはプラグインの責務外 |
| `down --volumes` / network の撤去 | down は containers のみ削除。README に「networks / named volumes は残る」を明記 |
| `up <service>` のフル実装(選択サービス + 推移的依存の解決) | 将来候補(P8)。当面 `up` / `down` への余分な positional は**エラー**にする(現状は黙って無視 — goal 3 違反) |
| network `aliases` の DNS 実現 | `container run --name` は1つのため実現不能。warning で可視化(D3) |
| `exec` の非 TTY モード(docker compose の `-T` 相当) | 既知の制限として README に記載 |
| compose ファイルの複数 `-f` マージ / `extends` / `include` | 対象外(モデルが `Decodable` 専用。`config` 実装時に再評価) |

## 検証済み前提

### 実機検証(container 1.1.0)

- `container list --all --format json` の `configuration.labels` にプラグインのラベルが載る(D2 の成立条件)。
- コンテナ名を FQDN にすると内部 DNS に登録され、参照側に `--dns-search` を渡せば短い名前で解決できる。**2条件の同時成立が必要**で、片方だけでは引けない(`--dns-domain` は不可)。解決されるのは**コンテナ名であって service 名ではない**(D3 の設計根拠)。
- `container inspect` の `status` に exitCode が無い(`service_completed_successfully` の exit==0 検証は不能のまま)。

### コードベース検証(本改訂で確定)

- 命名規則は `ComposeTranslate.swift:84` と `ComposeOrchestrator.swift:171-173` に複製(D1 の根拠)。image tag は `derivedTag`(`ComposeTranslate.swift:251`)が既に単一箇所。
- ラベル `com.composeforcontainer.project` / `.service` は全コンテナに付与済み(`ComposeTranslate.swift:87-88`)だが**読み手が存在しない**。`ps` は無フィルタの `container list --all` passthrough、`down` は名前引き。
- `up` の recreate は**名前一致だけで force-remove** する(`ComposeOrchestrator.swift:102`)— 他プロジェクトの同名コンテナ(特に `container_name` 指定時)を今日すでに黙って破壊しうる。
- `Sources/compose` は `@main` の executableTarget で、SwiftPM はテストターゲットにリンクできない — **CLI 層は現状テスト数ゼロかつテスト不能**。
- `engine.exec` はキャプチャ専用(`CLIContainerEngine.swift:74-76`)。対話用途には `forward`(stdio 継承)が既製の逃げ道。
- `ProcessRunner` は `run`(キャプチャ)と `runInheritingIO`(stdio 継承)のみ — 行単位ストリーミング API が無い。`CLIContainerEngine` は **spawn を直列化する actor**。
- `ComposeParser.parse` は同一 YAML 文字列を**2回**独立にパースする(`YAMLDecoder().decode` + 生 `Yams.load` によるキー差分)。
- `printWarnings` は `.info` を無条件に捨てる(`Compose.swift:169`)— 特権ポート・non-root bind 書込・未知トップレベルキーが不可視。
- `up` のインライン build は `noCache` を渡せない(`ComposeOrchestrator.swift:96-99`)。
- service networks の `aliases` はパース済みで破棄(`Forms.swift:253`)。
- CI・lint・format 設定は皆無(`.github/` 自体が無い)。
- テストベースライン: 59 件(Model 11 / Graph 6 / Translate 15 / CLIEngine 9 / Orchestrator 18)。

## アーキテクチャ原則(現行を維持)

- pure core(`ComposeModel` / `ComposeGraph` / `ComposeTranslate`)は FS・時間・プロセス非依存。副作用は `ContainerEngine` / CLI 層。
- FS や環境が要る判定はクロージャ注入(`preflightWarnings(kind:)` 方式)で pure 側に置く。
- `ContainerEngine` protocol にメソッドを足すときは `MockEngine` を同時に拡張。`ProcessRunner` に足すときは `FakeRunner` を同時に拡張。

## 横断基盤(新設 — 全フェーズの前提)

### B1 — `ComposeCLICore` 抽出

`Sources/compose/Compose.swift` の実質(パーサ・ディスパッチ・warning 表示・エラー整形)をライブラリ target `ComposeCLICore` に移し、executable は `@main` 数行の shim に縮小する。抽出直後に現挙動のキャラクタリゼーションテストを張る。これが無い限り D8a のパーサテストも D6a の出力テストも書けない。

### B2 — CI

`.github/workflows/ci.yml` を追加: `runs-on: macos-15`、Xcode 16.x を明示選択して Swift 6 を確保、`swift build && swift test`。

**明記すべき制約**: GitHub の macOS runner では Apple `container`(Virtualization.framework 必須)は動かない。CI は build + unit test のみで、各フェーズの実機 acceptance はローカル手動のまま — この線引きを README / CONTRIBUTING に書き、暗黙の期待を作らない。

### B3 — テスト戦略

- engine 追加メソッド(`listContainers` / `dnsDomains` / `imageDigest` / `stream`)は protocol 追加と同時に `MockEngine` / `FakeRunner` に対応実装。
- 各フェーズ末に `swift build` + `swift test`(ベースライン 59 件から単調増加)。ロジック追加フェーズは `/simplify` → `/code-review`。

## 設計決定

### D1 — 命名の単一 authority(要望4)

命名規則の複製(`ComposeTranslate.swift:84` / `ComposeOrchestrator.swift:172`)を `ComposeTranslate` の公開ヘルパーに集約する。

```swift
public enum ComposeNaming {
    /// DNS ドメインが有効なら FQDN(D3)。domain == nil なら従来の
    /// `containerName ?? "<project>-<service>"`。
    public static func containerName(
        project: ComposeProject, service: String, domain: String?
    ) -> String

    public static func imageTag(projectName: String, serviceName: String) -> String
}
```

orchestrator・translate の全参照をここに通す。DNS という「命名に影響する状態」が1点を通るため、「起動はするが down で消えない」系の不整合が構造的に起きない。

### D2 — ラベルによる同定(要望3)

engine に構造化一覧を追加する。

```swift
public struct ContainerSummary: Sendable {
    public var id: String            // = コンテナ名
    public var image: String
    public var state: String
    public var labels: [String: String]
}
// ContainerEngine に追加
func listContainers() async throws -> [ContainerSummary]
```

- **`ps`** — project ラベルでフィルタし、自前でテーブル描画(SERVICE / NAME / IMAGE / STATE / PORTS)。`buildkit` や他プロジェクトのコンテナは出ない。PORTS 列のソース(list JSON にポート情報があるか)は S4 で実測してから確定。
- **`down`** — 「project ラベル一致の全コンテナ」が対象。compose ファイル上の名前変更で旧コンテナが取り残される問題が消える。順序は shutdownOrder を「ラベル一致 ∩ 現在の定義」に適用し、定義に無いコンテナ(rename の旧名など)は最後にまとめて削除。`down` 冒頭に `systemRunning` チェックも追加(現状無し)。
- **recreate の label ガード(新規 — 既存事故の解消)** — `up` の force-remove 前に対象コンテナの project ラベルを確認する。**別プロジェクト所有、またはラベル無し(非 compose 管理)なら blocking error**。黙って乗っ取らない。D3 の衝突検出はこのヘルパーを再利用する。
- **service 名 → 実コンテナ解決** — `logs` / `exec` / `stop` / `start` / `restart` が共用するヘルパー(service ラベルで引き、無ければ D1 の命名にフォールバック)。

### D3 — service 名 DNS(要望1)

**前提の訂正が起点。** README の Limitations と `todo.md` は「コンテナ間 DNS は存在しない → ゲートウェイ方式が唯一解」を確定事項としているが、これは検証の組み合わせ漏れによる false negative(検証済み前提を参照)。設計は「FQDN 化」ではなく「**命名の service 名ベース化**」。

`up` の動作:

1. `container system dns list` を照会(engine に `dnsDomains() -> [String]` を追加)。
2. ドメイン選定 — project 名と一致する登録ドメインを優先、なければ先頭の1件。0件なら「`sudo container system dns create <project>` でサービス名解決が有効になる」と案内して従来動作(HOST_GATEWAY フォールバック)。
3. ドメインが得られたら各サービスに付与:
   - `--name <base>.<domain>` — `<base>` は `container_name` があればそれ、なければ **service 名そのもの**。
   - `--dns-search <domain>` — サービスが `dns_search` を明示していない場合のみ。
4. **衝突検出** — 命名が `<service>.<domain>` になるため、共有ドメインでは別プロジェクトの同名サービスと衝突しうる。`up` 冒頭で `listContainers()` を引き、同名かつ project ラベル不一致のコンテナが居たら blocking error(D2 の label ガードを再利用)。
5. **`aliases` の warning(新規)** — service networks の `aliases` はパース済みだが `--name` は1つしか持てず実現不能。alias が service 名 / container_name と異なる場合、「alias '<x>' は DNS 登録されません。参照側は '<service>' を使ってください」と warning(goal 1・3 準拠 — 黙って落とさない)。

**Spike S1(P2 着手前・実測5分)** — 2階層サブドメイン(`--name php.myproj.test`)が `dns create test` だけで解決されるか。可なら `<service>.<project>.<domain>` を既定にして衝突が原理的に消える。不可なら上記の衝突検出方式で確定。あわせて container 1.0 系での挙動も確認し、README の動作要件に反映する。

**HOST_GATEWAY 注入は残す** — ドメイン未登録環境のフォールバックとして意味が残る。位置づけを README で「stand-in」から「fallback」に改める。

**波及(P2 のスコープに含む)** — `examples/php-nginx-mysql` はゲートウェイ経由を前提に設計されているため、service 名直結に書き換える: `nginx/default.conf` の IP 直書き → `fastcgi_pass php:9000`、`src/index.php` の `$HOST_GATEWAY:13306` → `mysqli('db', …)`、中継のためだけの published port(php-fpm 19000 / MySQL 13306)とホスト露出の注意書きを削除。README の Limitations 表も更新。

### D4 — 変数展開と `.env`(要望5)

Compose 仕様の interpolation を、YAML パース後・モデルデコード前の Node 走査で行う。

- 対応構文: `$VAR` / `${VAR}` / `${VAR:-def}` / `${VAR-def}` / `${VAR:?err}` / `${VAR?err}` / `$$`。ネスト(`${A:-${B}}`)は非対応と明記。
- 変数ソースの優先順: プロセス環境 > compose ファイルと同じディレクトリの `.env`。`?` 系の失敗は blocking。
- 純関数 `Interpolator.expand(_ template: String, env: (String) -> String?) -> Result<String, InterpolationError>` を `ComposeModel` に置く。`.env` の読み込みとプロセス環境の合成は CLI 層で行い、クロージャで注入(pure core の FS 非依存を維持)。
- Node 層で走査する理由: モデル側の String プロパティを個別に展開する方式はプロパティ追加のたびに漏れる。走査なら構造的に漏れない。
- **parse の再構成を本タスクに含める(新規)** — 現行 `ComposeParser.parse` は同一文字列を2回パースする(decode + キー差分)。素朴に片方へ補間を挿すと decode とキー差分で見える YAML が食い違う。`Yams.compose(yaml:)` で Node を**1回**取得 → scalar を補間 → その Node から `YAMLDecoder().decode(_:from:)` と key-diff walk の**両方**を行う構成に改める(1パース化で整合が構造的に保証される)。補間済み Node を re-serialize して従来の2パスへ食わせる案は、シリアライズでスカラースタイルが変わるリスクがあるため採らない。

```
生 YAML → Yams.compose → Node → [scalar を interpolate] → decode + key-diff(同一 Node から)→ ComposeProject
```

### D5 — chown preflight(要望2)

Apple container の bind mount(virtiofs)は書き込みは通るが所有権変更を拒否するため、root で datadir を chown する公式 DB イメージの entrypoint が `Operation not permitted` の1行で落ちる。`preflightWarnings` に検出を追加する。

- 条件: bind mount の target が既知 datadir テーブルに一致 **かつ** `user:` 未指定。
- テーブル(定数、テストで網羅): `/var/lib/mysql`, `/var/lib/postgresql/data`, `/var/lib/mongodb`, `/data`。`/bitnami` 前置も許容。
- 文面は断定しない(chown しない image では誤検出のため): 「Apple container の bind mount は chown を受け付けないため、root で datadir を chown する entrypoint(公式 mysql / mariadb / postgres 等)は**起動に失敗する可能性が高い**」+ 回避策2つ — named volume 化(entrypoint がそのまま動き初回初期化も効く)/ entrypoint 上書き(初回初期化が走らない旨も併記)。
- warning kind: `.engineGap(.bindChownRestricted)`。
- この検出は target パスと `user:` だけで決まる純粋判定 — FS probe は不要で、既存の `preflightWarnings` に素直に足せる。

### D6 — `up` の UX(要望6)

**6a — 起動後ステータス検証(小)**: 最終 wave 完了後に `listContainers()` を1回引き、stopped のサービスを報告する。

```
Started 2/3 service(s). 'nginx' exited — check: container compose logs nginx
```

`Started 3 service(s).` という嘘(現行 `Compose.swift:78` は included.count を無条件出力)をなくす。全サービス停止なら exit 1。stopped 判定に使う state 文字列の実際の語彙は S4 で実測してから実装する。

**6b — 前景モード(大)**: 既定を Docker 互換の前景に切り替える。

- `up` 既定 = 前景: 全サービスの `container logs -f` を束ね、`[service] ` プレフィックス + サービス別の色でマルチプレクス。Ctrl-C(SIGINT)で stop(remove はしない — Docker と同じ)。
- `-d` / `--detach` で detach 起動。
- **実装構造(精査で確定)**: `ProcessRunner` に行コールバック型の新プリミティブを追加する(`func stream(_ executable: String, _ arguments: [String], onLine: @Sendable (String) -> Void) async throws -> Int32`。`FakeRunner` にも対応実装)。**長寿命ストリームを `CLIContainerEngine` actor の中で await してはならない** — この actor は spawn を直列化するため、1本目の `logs -f` が actor を占有して全 engine 呼び出しが詰まる。各ストリームは per-service の `Task`(`TaskGroup`)に載せ、マルチプレクサ actor の責務は**出力の interleave(行単位の直列化 + prefィックス/色付け)のみ**とする。
- SIGINT 処理の順序: ハンドラ → 全 log プロセス terminate → 通常の actor 経由で各サービス `stop`(この時点でストリームは終了済みなので直列化と衝突しない)。
- ログマルチプレクサは**要望7の `logs`(引数なし = 全サービス)と共用**。

### D7 — 構成ハッシュによる再作成スキップ(要望8)

`todo.md` が「代替検討余地」として残した宿題の決着。再作成コストより「volume 外のデータが `up` のたびに消える」正しさの問題として扱う。

- 追加ラベル `com.composeforcontainer.config-hash` = 正規化済み argv + image digest の SHA-256。
- **ハッシュ正規化規則(精査で確定)** — hash 入力 = 翻訳後 argv から以下を除外したもの + image digest:
  - `--cidfile <path>`
  - 注入分の `-e HOST_GATEWAY=…`(gateway IP は up のたびに変わりうるため。ユーザーが `environment:` で明示した HOST_GATEWAY は含む)
  - `--label com.composeforcontainer.config-hash=…` 自身(自己参照の排除)
- image digest は engine 追加メソッド `imageDigest(ref:) -> String?`(`container image inspect`)で取得。取得コストは S3 で実測。
- `up` の判定(ラベルで引く):
  - ハッシュ一致 + running → 何もしない(`svc Up (unchanged)`)
  - ハッシュ一致 + stopped → `start`
  - 不一致 or 不在 → recreate
- `build:` サービスは build 後の image digest がハッシュに入るため、Dockerfile 変更でも正しく recreate(内容不変の再 build なら digest 不変 → skip が効く)。
- `--force-recreate` で全再作成を明示的に選べる。対になる `up --no-cache`(現行はインライン build に noCache が配線されていない)もここで配線する。

### D8 — CLI パーサとサブコマンド(要望9)

2つに分割する(精査による再編成 — 旧 D8 の一括実装は `up -d`(P5)がフラットパーサに先に載る手戻りを生む)。

**D8a — パーサのサブコマンド単位化(前倒し: P0b)**。現行 `Compose.swift:47-57` はサブコマンドを区別せず全 argv を舐める単純ループで、`exec <svc> <cmd…>` を足すと `compose exec php ls --tail` の `--tail` を親が食う。グローバルオプション(`-f` / `--profile`)→ サブコマンド → サブコマンド固有オプション、`--` 以降は透過、の構造に改める。あわせて既存パーサの実バグも修正対象として列挙する:

- `-f` / `--profile` / `--tail` が argv 末尾に来ると値なしを黙殺(missing-value 診断を追加)
- どのコマンドにどのフラグでも受理される(コマンド別に受理フラグを限定)
- `up` / `down` への余分な positional が黙って無視される(エラーに変更 — 非ゴール表を参照)
- per-command help が無い(`compose <cmd> --help`)
- 既知の `var args` 警告の解消

**D8b — サブコマンド追加(後段: P7)**。すべて薄い委譲(D2 の解決ヘルパーに乗る):

| コマンド | 実装 |
|---|---|
| `config` | interpolation 済み・正規化済みモデルを YAML で出力 + **全 severity の warning**(info 含む)。warning の原因追跡用 |
| `exec <svc> <cmd…>` | 解決して forward。**`engine.exec` は使わない**(キャプチャ専用で対話不能)— `forward(["exec", "-it", name] + cmd)` を使う。非 TTY(`-T` 相当)は既知の制限として記載 |
| `stop` / `start` / `restart` | ラベル一致コンテナへ順序適用(stop は shutdownOrder、start は起動 wave 順) |
| `pull` | `image:` を持つ全サービスの `container image pull` |

**info warning の可視化方針(goal 3 との矛盾解消)** — 現行 CLI は `.info` を無条件に捨てる。`config` は全 severity を表示し、グローバル `--verbose` で `up` 等でも info を表示する。README に「info 級の注意は `compose config` で確認できる」と記載。

doctor コマンドは作らない(`todo.md` の方針どおり、up 前プリフライトに内包)。

### D9 — `restart` policy(要望10)

警告のみ(現状維持)。engine 側に機能がなく、launchd で埋めるのはプラグインの責務外。

## 実装フェーズ

依存の背骨は **P0 → P1 → P2**(基盤 → ラベル同定 → DNS)。DNS で命名が変わる変更を、名前引きの `down` が残ったまま入れないための順序。各フェーズが独立 PR(膨らむ場合の分割余地は表に記載)。

| フェーズ | 内容 | 規模 | 依存 | 分割余地 |
|---|---|---|---|---|
| **P0a** | B2 CI 導入 + B1 `ComposeCLICore` 抽出(+キャラクタリゼーションテスト) | 小〜中 | — | CI 単独を先行 PR に |
| **P0b** | D1 命名一元化 + D8a パーサ構造化(missing-value 診断、余分 positional エラー化、per-command help) | 中 | P0a | D1 / D8a で分割可 |
| **P1** | D2 ラベル同定(`listContainers`、`ps` テーブル、`down` ラベル引き + systemRunning チェック、解決ヘルパー、**recreate label ガード**)+ D6a 起動後検証 | 中〜大 | P0b, S4 | 「D2 primitives + ps」/「down 移行 + ガード」/「D6a」の 2〜3 PR |
| **P2** | D3 DNS(S1 → ドメイン照会、service 名ベース FQDN、`--dns-search`、衝突検出、aliases warning)+ example 書き換え + README 更新 | 中 | P1, S1 | — |
| **P3** | D5 chown preflight | 小 | — | — |
| **P4** | D4 interpolation + `.env` + parse 一回化 | 中 | — | — |
| **P5** | D6b 前景 `up` + `logs` 全サービス化(`stream` primitive、マルチプレクサ共用、`-d`) | 大 | P1, S2 | primitive 先行 PR 可 |
| **P6** | D7 構成ハッシュ(正規化規則、`imageDigest`、`--force-recreate` / `up --no-cache` 配線) | 中 | P1, S3。**P2 の後に実施**(naming 変更による全 recreate を P2 の1回に集約し、D7 導入後の初回 up と混ぜない) | — |
| **P7** | D8b サブコマンド群(`config` は P4 後、他は P1 後で可) | 中 | P1, P4 | config / 他コマンドで分割可 |

P3・P4 は backbone と独立 — Compose 互換(goal 1)を早く上げたければ P1 と並行して先行させてよい。

### 各フェーズの verify

プロセス規約: 各フェーズ末に `swift build` + `swift test`(ベースライン 59 件から単調増加、CI でも同一コマンド)、ロジック追加フェーズは `/simplify` → `/code-review`。実機 acceptance はローカル(CI では不能 — B2 参照)。

- **P0a** — CI が main と PR で緑になること。抽出後に既存59件 + CLI キャラクタリゼーションテストが緑。
- **P0b** — `ComposeNaming` 経由で同一 argv が出ることの差分テスト。パーサ構造化のテーブル駆動テスト(missing-value、コマンド別フラグ受理、`up web` エラー、`--` 透過)。
- **P1** — fake engine の labels 入り `listContainers` で、(a) 他プロジェクト・buildkit が `ps` に出ない、(b) 名前変更後の旧コンテナを `down` が消す、(c) stopped サービスの報告、(d) **他プロジェクト同名コンテナへの force-remove が blocking になる**、をテスト。実機で `buildkit` 混入が消えることを確認。
- **P2** — S1 の実測結果を記録。argv テスト(FQDN + `--dns-search` 付与、`dns_search` 明示時はスキップ、ドメイン0件で従来動作、衝突時 blocking、aliases warning)。受け入れ条件は実機2本: ①要望の PHP+nginx+MariaDB 構成が**素の compose ファイルのまま**通る(`fastcgi_pass php:9000` 疎通)、②書き換え後の example が `up` → `curl` 一発で通る。
- **P3** — テーブル駆動テスト(各 datadir × user 有無 × named/bind)。実機 mariadb bind mount で警告文言を確認。
- **P4** — interpolation 仕様のテーブル駆動テスト(`$$` エスケープ、`?` 系 blocking、`.env` とプロセス環境の優先順を含む)+ **一回パース化後もキー差分 warning が同一に出ることの回帰テスト**。
- **P5** — マルチプレクサの直列化テスト(交錯入力 → 行単位出力)。`FakeRunner.stream` でプレフィックス付与を検証。実機で Ctrl-C 停止と `-d`、および**ログ流中に別 engine 呼び出しが詰まらないこと**を確認。
- **P6** — ハッシュ判定3分岐のテスト + 正規化除外(HOST_GATEWAY 変化・cidfile・自ラベル)で hash が安定するテスト + 「unchanged で volume 外ファイルが残る」実機確認。
- **P7** — パーサの透過テスト(`exec php ls --tail` が子に届く)、`config` のゴールデンテスト(info warning 含む)、各コマンドの argv テスト。

## スパイク一覧(実装前に潰す不確定要素)

| # | 内容 | タイミング | 分岐 |
|---|---|---|---|
| **S1** | 2階層サブドメイン(`php.myproj.test`)が `dns create test` だけで解決されるか(実測5分)。container 1.0 系の挙動も確認 | P2 前 | 可 → `<service>.<project>.<domain>` 既定で衝突が原理的に消える / 不可 → 衝突検出方式で確定 |
| **S2** | `container logs -f` の複数同時実行(service 数ぶんの子プロセス)+ **actor を経由しない spawn 経路**の検証 | P5 前 | 不可なら logs ポーリング方式へ後退 |
| **S3** | `container image inspect` の digest 取得コスト(全サービス分でも体感ゼロか) | P6 前 | 遅ければ並列取得 or キャッシュ |
| **S4** | `container list --format json` の state 文字列の実語彙・ports/publishedPorts フィールドの有無 + `inspect` の exitCode 再確認 | P1 前 | ports 無ければ `ps` の PORTS 列は翻訳時情報から補完 |

## リスクと既知の制限

- **cross-project 同名衝突** — 現行は force-remove で黙って破壊。P1 の label ガードで blocking error 化(解消)。
- **`service_completed_successfully` の exit==0 検証** — container 1.1.0 でも `list` / `inspect` に exitCode が無い(実機確認済み)。S4 で再確認し、結論を doc コメントへ。engine 追加待ち。
- **info warning** — 通常フローでは非表示のまま(D8b の `--verbose` / `config` で可視化)。
- **HOST_GATEWAY とハッシュ** — 正規化で除外(D7)。ユーザー明示分は含まれるため、明示値を変えれば意図どおり recreate される。
- **aliases / 非 TTY exec / restart policy** — 非ゴール表のとおり warning・README 記載で可視化。

## 受け入れ基準(最終形)

1. `swift test` 全緑(CI)+ 各フェーズの verify 項目。
2. 実機 end-to-end(examples/php-nginx-mysql): `container compose up` → `curl` 一発で PHP → nginx → MySQL が service 名で疎通。`ps` に自 stack のみ表示。`compose.yaml` のサービス名を rename して再 `up` → `down` で旧コンテナも残らない。
3. サービスが起動直後に死ぬ compose ファイルで、`up` の出力だけから原因(logs コマンド)に到達できる。
4. Docker Compose 用の代表的 compose ファイル(interpolation・`.env`・healthcheck・depends_on 条件付き)が無修正で動くか、動かない理由が warning で即座に分かる。
