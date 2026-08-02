# container-compose

A `compose` **CLI plugin** for Apple's [`container`](https://github.com/apple/container) tool —
run multi-container apps from a Docker Compose file as a first-class subcommand:

```sh
container compose up      # start the stack and follow its logs (Ctrl-C stops it)
container compose up -d   # start it and return
container compose ps      # list the stack's containers
container compose logs    # show logs
container compose exec web sh   # run a command in a service's container
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

COMMANDS:
  up [-d]                  Create and start the stack, then follow its logs
                           (--force-recreate, --no-cache)
  down                     Stop and remove the stack (reverse order)
  start                    Start the stack's stopped containers
  stop                     Stop the containers without removing them
  restart                  Stop then start the containers
  build [service...]       Build images for services with a build: section
  pull [service...]        Pull the images services declare
  ps                       List the stack's containers
  logs [service]           Show logs (every service, multiplexed, when none is named)
  exec <service> <cmd>...  Run a command in a service's container
  config                   Print the compose file with variables substituted

OPTIONS:
  -f, --file <file>   Compose file (default: ./compose.yaml, compose.yml,
                      docker-compose.yaml, docker-compose.yml)
  --profile <name>    Activate a compose profile (repeatable)
  --verbose           Also show info-level diagnostics
  -h, --help          Show this help
```

Each command has its own options and its own help — `container compose build --help`
lists `--no-cache`, `container compose logs --help` lists `--follow` and `--tail <n>`.
An option a command does not accept is an error, never a silent no-op.

`up` runs in the foreground, like `docker compose up`: it follows every service's
log under a `service |` prefix, one colour per service when stdout is a terminal.
Ctrl-C stops the stack without removing it — `down` is what removes it. `-d` starts
the stack and returns instead. `logs` with no service name uses the same multiplexer.

Everything after `exec <service>` is passed through untouched, so
`container compose exec web ls --all` reaches `ls`, not this parser. A TTY is
requested only when stdin is one, so `exec` works from a script as well as from a
terminal.

`stop` stops every container the project owns, profiles included — leaving one
running that no later `stop` would reach is worse than stopping one extra. `start`
only starts what `up` would have started, and `restart` puts back exactly what it
took down.

`container compose config` prints the file as the other commands read it — after
`${…}` substitution — followed by **every** diagnostic, including the info-level
notes the other commands keep out of the way. It is the place to look when a key
seems to have been ignored. `--verbose` shows those notes on any command.

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

## What the plugin handles for you

Apple `container` has rough edges that this plugin smooths over at `up` time:

- **Builder auto-start** — if any service has a `build:`, the BuildKit builder is
  started on demand (otherwise `container build` hangs and times out).
- **Compose-relative paths** — `build.context`, bind `source`, and `env_file`
  resolve against the **compose file's directory**, so `-f path/to/compose.yaml`
  works from any working directory (matching Docker Compose).
- **Service-name DNS, when the host supports it** — register a local domain once
  (`sudo container system dns create test`) and `up` names each container
  `<service>.<project>.<domain>` and gives it `--dns-search <project>.<domain>`, so
  `fastcgi_pass php:9000` reaches the `php` service. Two labels deep, so two projects
  can each have a `web`. The registered domain is checked at every `up`, and after
  the stack starts one service is asked to resolve another — because a *registered*
  domain is not the same as a *working* one (see Limitations).
- **`HOST_GATEWAY` injection** — every container gets `HOST_GATEWAY=<host gateway IP>`
  (a `host.docker.internal` stand-in), so apps can reach host-published ports of
  sibling services. Injected whether or not DNS is working, so there is always a path
  that works.
- **`depends_on: service_healthy` / `service_completed_successfully`** — emulated by
  polling the dependency's `healthcheck` (via `container exec`) or its run state
  before starting dependents. Bounded by the healthcheck's retries/interval.
- **`up` recreates only what changed** — every container is stamped with a
  fingerprint of the arguments it was created from plus the id of the image it runs.
  A re-run leaves a service whose configuration and image are unchanged exactly as it
  is, so long-running services are not restarted for nothing and anything written
  outside a volume survives:
  ```
  Started 2 service(s). 2 unchanged (web,worker).
  ```
  Edit the compose file, pull a newer image behind the same tag, or change a
  Dockerfile, and that service alone is recreated. `--force-recreate` recreates
  everything; a service that is unchanged but stopped is started rather than
  recreated. Named volumes persist either way.
- **Labels identify the stack, not names** — every container carries
  `com.composeforcontainer.project` / `.service`, and `ps` / `down` / `logs` look it
  up by label. So `ps` shows your stack alone (no `buildkit`, no other projects), and
  renaming a service in the compose file does not strand the container it started
  under the old name — `down` still removes it.
- **`up` will not take over a container it does not own** — recreating a service
  force-removes whatever holds its name, so `up` checks the label first. A container
  belonging to another project, or created outside compose, stops `up` with the
  conflicting names listed. Nothing is started.
- **`up` tells you what actually survived** — after the last wave it asks the engine
  which containers are running, so a service that dies on startup is named along with
  the command that shows why, instead of being counted as started:
  ```
  Started 1/2 service(s).
  'broken' is not running. Check its log: container compose logs broken
  ```
  If nothing is left running, `up` exits non-zero.
- **Variable interpolation and `.env`** — `${VAR}`, `${VAR:-default}`,
  `${VAR-default}`, `${VAR:?error}`, `${VAR?error}`, `$VAR` and `$$` are substituted
  throughout the file, taking values from the process environment first and then from
  a `.env` beside the compose file. A variable with no value substitutes an empty
  string and says so; a `:?` variable with no value stops the command and names the
  key it came from (`services.db.environment.MYSQL_ROOT_PASSWORD`). A variable inside
  a default (`${A:-${B}}`, `${A:-$B}`) and the `:+` modifier are not supported — both
  are errors, never a silent substitution. The contents of an `env_file` are passed to
  the engine as written and are not interpolated.
- **Bind-mount preflight** — a bind `source` that points at a file (Apple `container`
  mounts directories only) is flagged before it fails cryptically.

## Limitations (Apple `container` gaps)

These are surfaced as warnings at `up` time:

| Compose feature | Behavior here |
|---|---|
| `restart` | No restart policy in `container`; warned (not enforced) |
| `healthcheck` | No native healthchecks; the plugin **emulates** `depends_on: service_healthy` by polling the check at `up` (exit status of a completed container is unverifiable, though) |
| service-name DNS | Works only when a local domain is registered **and** the host resolves it — see the note below |
| multiple `networks` per service | Only the first network is attached; the rest are warned |
| port ranges | Single ports only |
| bind mounts | Directories only (files are flagged); may be read-only for non-root container users |
| bind mounts at a database data directory | Writes go through but `chown` does not, so the official mysql / mariadb / postgres entrypoints die on `Operation not permitted`. Flagged before `up`, with both ways out: a named volume (keeps first-run initialization) or an overridden entrypoint (skips it) |
| privileged host ports (<1024) | May require elevated permissions on macOS |

### Service-name DNS and the macOS 27 developer beta

`container system dns create <domain>` registers a domain with the engine, and a
container named `<label>.<domain>` lands in the engine's resolver. Containers reach
that resolver through the host's system resolver, and **that link is broken on the
macOS 27 developer beta** (measured on 26A5388g with container CLI 1.1.0):

```
$ dig @127.0.0.1 -p 2053 web.demo.test +short    # the engine's own resolver
192.168.64.15                                     # knows the name
$ dns-sd -G v4v6 web.demo.test                    # what the host, and therefore
... No Such Record                                # every container, actually sees
```

`scutil --dns` shows the resolver registered and reachable, yet mDNSResponder does
not query it; `container system dns create test` writes
`/etc/resolver/containerization.test` whose filename does not match the `domain test`
inside it. This is a beta, so a later build may well fix it.

The plugin does not guess. It probes at `up` time and tells you which mechanism is
actually available:

```
warning: Containers are named under 'demo.test', but 'db' cannot resolve
'web.demo.test'. ... Until then, reach siblings through HOST_GATEWAY and their
published ports; nothing else in the stack is affected.
```

Nothing breaks either way — `HOST_GATEWAY` is always injected, `ps` / `down` / `logs`
identify containers by label rather than by name, and the stack starts normally.

`down` removes containers only — networks and named volumes are left in place, so
data survives a `down`/`up` cycle. Remove them with `container network delete` /
`container volume delete` when you actually want them gone.

Reach a published service on the host via its mapped port (e.g. `http://localhost:8080`).
`ps` reads the compose file to know which project to list, so run it where the file is
(or pass `-f`); `logs` passes through to `container logs`.

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
`ComposeGraph`, `ComposeTranslate`, `ContainerEngine`, `ComposeCLICore`, and the
`compose` executable (a thin `@main` shim over `ComposeCLICore`).

CI runs `swift build && swift test` on every push and pull request. It stops there
on purpose: Apple `container` needs Virtualization.framework, which GitHub's macOS
runners do not provide, so **anything that drives the real engine is verified
locally, not in CI**.

## License

MIT — see [LICENSE](LICENSE).
