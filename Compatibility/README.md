# Docker API compatibility

Glass Dock tracks the pinned [Moby v28.5.2 Swagger specification](https://raw.githubusercontent.com/moby/moby/v28.5.2/api/swagger.yaml), which defines Docker Engine API v1.51.

The support manifest is the editable source of truth. The JSON matrix is generated from the manifest and the pinned Swagger document. Do not edit the generated JSON by hand.

Run the drift check with:

```sh
make api-compatibility-check
```

## Support states

Every one of the 107 Moby operations is classified in `moby-v28.5.2-support.yml` with exactly one state:

| State | Meaning |
|---|---|
| `full` | Behaves like a real Moby v28.5.2 daemon for supported inputs. |
| `partial` | Real implementation with a documented gap versus Moby (the note names the gap). |
| `error-only` | Registered route that returns Moby's exact unavailable/not-found error for a daemon without Swarm and without plugins installed. |

Rules:

- Every operation in the pinned spec must be listed in the manifest. The generator fails on missing entries.
- A state may only change when a unit test or live conformance probe proves the new state.
- `partial` notes must name the concrete limitation, not vague language.

Current distribution: 65 full, 1 partial, 41 error-only.

## Product scope

Glass Dock is a local, single-node Docker-compatible runtime for macOS on
Apple Silicon. The compatibility target is ordinary application workflows:
containers, images, networks, volumes, logs, exec, published ports, and
Dockerfile or BuildKit builds. Clients and Dockerfiles in that scope should not
need a migration.

The 41 `error-only` operations are intentional. They cover Swarm management,
Swarm objects, Docker plugin lifecycle, and the Swarm-only volume update route.
Glass Dock does not run a Swarm scheduler or host Docker plugins, so these
routes return the same unavailable or not-found errors that Docker returns when
those capabilities are absent. This is API compatibility for an out-of-scope
feature, not an implementation of that feature.

`POST /build` remains `partial` because it is a real classic Dockerfile build
path with documented gaps. BuildKit clients use the full `/session` relay, but
that does not prove every Moby `/build` behavior. It must remain `partial` until
the missing classic-build semantics are implemented and covered by live
conformance. Marking it `error-only` would break ordinary `docker build`
workflows and would be less compatible.

The matrix therefore measures Docker API behavior within Glass Dock's product
scope. It does not claim that Glass Dock implements every Docker product,
including Swarm and plugins.

## Live conformance

Probe a running daemon with:

```sh
GLASSDOCK_SOCKET=/path/to/glassdock.sock make api-compatibility-conformance
```

The compatibility target runs the live harness with `--all`. That mode sends one executable contract request for each of the 107 matrix operations, validates each error-only operation against its declared `expectedStatus` plus Docker's `{"message": ...}` body shape, validates JSON response and error content types where applicable, and checks create/inspect/delete side effects for volumes and networks. It also probes seven core smoke routes.

Route tests and guest backend tests remain important for complete valid-request coverage, every error variant, and backend-effect details.
