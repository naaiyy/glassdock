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

The live harness currently probes explicit unsupported rows and seven core smoke routes. It uses concrete placeholders for path parameters and does not provide full valid-request, error-case, schema, header, or side-effect coverage for every operation. Route tests and guest backend tests provide additional mocked and component-level evidence.
