# Docker API compatibility

Glass Dock tracks the pinned [Moby v28.5.2 Swagger specification](https://raw.githubusercontent.com/moby/moby/v28.5.2/api/swagger.yaml), which defines Docker Engine API v1.51.

The support manifest is the editable source. The JSON matrix is generated from the manifest and the pinned Swagger document. Do not edit the generated JSON by hand.

Run the drift check with:

```sh
make api-compatibility-check
```

The matrix contains 107 Moby operations. It currently classifies 18 as implemented, 36 as partial, and 53 as explicitly unsupported. Every unsupported operation must have a registered route that returns HTTP 501 with a Docker error body. This keeps unsupported runtime features visible to clients instead of presenting fake success responses.

Probe a running daemon with:

```sh
GLASSDOCK_SOCKET=/path/to/glassdock.sock make api-compatibility-conformance
```

The live harness verifies all explicit 501 operations and smoke-tests the core implemented routes. The harness uses a concrete placeholder for path parameters, so it does not mutate daemon state.
