# Docker API compatibility

Glass Dock tracks the pinned [Moby v28.5.2 Swagger specification](https://raw.githubusercontent.com/moby/moby/v28.5.2/api/swagger.yaml), which defines Docker Engine API v1.51.

The support manifest is the editable source. The JSON matrix is generated from the manifest and the pinned Swagger document. Do not edit the generated JSON by hand.

Run the drift check with:

```sh
make api-compatibility-check
```

The matrix contains 107 Moby operations: 18 implemented and 89 partial. Partial rows have a registered route, but at least one request variant, response field, backend effect, or error case still needs work. The guest runtime owns container, image, network, and build execution; the host keeps Docker metadata and control-plane state.

Probe a running daemon with:

```sh
GLASSDOCK_SOCKET=/path/to/glassdock.sock make api-compatibility-conformance
```

The compatibility target runs the live harness with `--all`. That mode sends one executable contract request for each of the 107 matrix operations, validates JSON response and error content types where applicable, and checks create/inspect/delete side effects for volumes, networks, configs, and secrets. The harness also probes explicit unsupported rows and seven core smoke routes. The probes use safe fixtures and concrete path placeholders, so they are not a substitute for complete valid-request coverage, every error variant, or full response-schema and backend-effect parity. Those limitations remain reflected by the 89 partial rows. Route tests and guest backend tests provide additional mocked and component-level evidence.
