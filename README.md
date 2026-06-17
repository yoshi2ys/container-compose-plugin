# container-compose

A `compose` **CLI plugin** for Apple's [`container`](https://github.com/apple/container) tool —
run multi-container apps from a Docker Compose file as a first-class subcommand:

```sh
container compose up      # start the stack (dependency order)
container compose ps      # list the stack's containers
container compose logs    # show logs
container compose down    # stop and remove (reverse order)
```

Apple's `container` has no compose support and the maintainers have
[tabled a first-party solution](https://github.com/apple/container/discussions/194).
This plugin fills that gap by parsing a `compose.yaml` and driving the `container`
CLI. It installs through `container`'s official plugin mechanism, so `container compose`
behaves like a built-in subcommand.

> Third-party project. Not affiliated with or endorsed by Apple.

## Requirements

- macOS 26+ on Apple Silicon
- Apple `container` installed, with the system started (`container system start`)
- A Swift 6 toolchain (Xcode 26+/27) to build

## Install

```sh
git clone https://github.com/yoshi2ys/container-compose-plugin.git
cd container-compose-plugin
sudo ./install-plugin.sh          # builds release, installs into the plugin dir
```

This places the binary and manifest where `container` discovers plugins:

```
/usr/local/libexec/container-plugins/compose/
├── config.toml          # CLI-plugin manifest (no [servicesConfig] => CLI plugin)
└── bin/compose          # the plugin binary
```

Verify:

```sh
container system start
container --help            # 'compose' appears under PLUGINS
container compose --help
```

## Usage

```
container compose [-f <file>] [--profile <name>]... <command> [args]

COMMANDS
  up                 Create and start the stack (dependency order)
  down               Stop and remove the stack (reverse order)
  ps                 List the stack's containers
  logs [service]     Show logs (--follow, --tail <n>)

OPTIONS
  -f, --file <file>  Compose file (default: ./compose.yaml, compose.yml,
                     docker-compose.yaml, docker-compose.yml)
  --profile <name>   Activate a compose profile (repeatable)
```

Example (`examples/compose.yaml`):

```yaml
name: example
services:
  web:
    image: nginx:latest
    ports:
      - "8080:80"        # browse http://localhost:8080
  worker:
    image: alpine:latest
    command: ["sh", "-c", "echo worker started; sleep 3600"]
    depends_on: [web]
```

```sh
container compose -f examples/compose.yaml up
open http://localhost:8080
container compose -f examples/compose.yaml down
```

## Supported compose keys

`image`, `build` (`context`, `dockerfile`, `args`, `target`), `container_name`,
`command`, `entrypoint`, `environment`, `env_file`, `ports`, `volumes` (bind &
named), `depends_on`, `networks`, `deploy.resources.limits` (`cpus`, `memory`),
`labels`, `working_dir`, `user`, `cap_add`/`cap_drop`, `dns`/`dns_search`,
`read_only`, `tmpfs`, `init`, `platform`, `profiles`.

Unsupported keys are **reported as warnings**, never silently dropped.

## Limitations (Apple `container` gaps)

These are surfaced as warnings at `up` time:

| Compose feature | Behavior here |
|---|---|
| `restart` | No restart policy in `container`; warned (not enforced) |
| `healthcheck` / `depends_on: service_healthy` | No healthchecks; ordering falls back to **start-order only** |
| service-name DNS | Containers don't resolve each other by name; reach services via published ports |
| multiple `networks` per service | Only the first network is attached; the rest are warned |
| port ranges | Single ports only |
| bind mounts | May be read-only for non-root container users (runtime limitation) |
| privileged host ports (<1024) | May require elevated permissions on macOS |

`ps` and `logs` pass through to `container`. Reach a published service on the host
via its mapped port (e.g. `http://localhost:8080`).

## How it works

`compose.yaml` → parsed into a typed model (a Docker Compose subset) → a dependency
graph (`depends_on`, topological waves) → translated into `container run` argument
vectors → executed by shelling out to `container`. `build`, `ps`, and `logs` stream
straight to your terminal.

Because `config.toml` has no `[servicesConfig]` section, `container` treats this as a
**CLI plugin**: it `execvp`s `bin/compose` for `container compose …`. No XPC, no daemon.

## Build & test

```sh
swift build
swift test          # parser, dependency graph, argv translation, engine/orchestrator
swift run compose --help
```

The only external dependency is [Yams](https://github.com/jpsim/Yams) (YAML parsing);
everything else is Foundation. Code is organized into testable modules: `ComposeModel`,
`ComposeGraph`, `ComposeTranslate`, `ContainerEngine`, and the `compose` executable.

## License

MIT — see [LICENSE](LICENSE).
