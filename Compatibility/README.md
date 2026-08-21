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

Current distribution: 57 full, 9 partial, 41 error-only.

## Live conformance

Probe a running daemon with:

```sh
GLASSDOCK_SOCKET=/path/to/glassdock.sock make api-compatibility-conformance
```

The compatibility target runs the live harness with `--all`. That mode sends one executable contract request for each of the 107 matrix operations, validates each error-only operation against its declared `expectedStatus` plus Docker's `{"message": ...}` body shape, validates JSON response and error content types where applicable, and checks create/inspect/delete side effects for volumes and networks. It also probes seven core smoke routes.

Route tests and guest backend tests remain important for complete valid-request coverage, every error variant, and backend-effect details.
