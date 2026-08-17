#!/usr/bin/env ruby

require "json"
require "tmpdir"

require_relative "../compatibility/generate-moby-v1.51-matrix"
require_relative "../compatibility/run-moby-v1.51-conformance"

def assert(condition, message)
  return if condition

  warn message
  exit 1
end

matrix = {
  "operations" => [
    {"method" => "GET", "path" => "/_ping"},
    {"method" => "POST", "path" => "/containers/create"}
  ]
}

Dir.mktmpdir("glassdock-compatibility-test") do |directory|
  File.write(
    File.join(directory, "RegisteredRoutes.swift"),
    'registerVersionedRoute(.GET, pattern: "/_ping", use: handler)'
  )

  begin
    check_registered_routes(matrix, roots: [directory])
    abort "a missing registered route was accepted"
  rescue MatrixError => error
    assert(error.message.include?("POST /containers/create"), "missing route was not reported precisely")
  end

  File.open(File.join(directory, "RegisteredRoutes.swift"), "a") do |file|
    file.puts 'registerVersionedRoute(.POST, pattern: "/containers/create", use: handler)'
  end
  check_registered_routes(matrix, roots: [directory])
end

assert(body_is_valid?("HEAD", ""), "HEAD error bodies should not require a message")
assert(body_is_valid?("GET", "operation not implemented"), "Docker not-implemented errors should be accepted")
assert(!body_is_valid?("GET", ""), "empty GET error bodies should be rejected")
assert(json_body("{\"status\":\"ok\"}\n{\"status\":\"done\"}"), "newline-delimited JSON should be accepted")
assert(
  validate_contract_response({"method" => "GET", "path" => "/_ping"}, 200, "OK", "" ).nil?,
  "the Docker ping body should be accepted as plain text"
)
assert(
  validate_contract_response(
    {"method" => "POST", "path" => "/containers/create"},
    201,
    '{"Id":"container-id","Warnings":[]}',
    "application/json"
  ).nil?,
  "container create responses must accept the Docker identity shape"
)
assert(
  validate_contract_response(
    {"method" => "POST", "path" => "/configs/create"},
    201,
    '{"ID":"config-id"}',
    "application/json"
  ).nil?,
  "config create responses must accept the Docker identity shape"
)
assert(
  validate_contract_response(
    {"method" => "POST", "path" => "/configs/create"},
    201,
    '{"Id":"config-id"}',
    "application/json"
  ).include?("ID"),
  "config create responses must require ID"
)
assert(
  validate_contract_response(
    {"method" => "GET", "path" => "/version"},
    200,
    '{"ApiVersion":"1.51","Version":"test"}',
    "application/json"
  ).nil?,
  "version responses must accept the Docker version shape"
)
assert(
  validate_contract_response(
    {"method" => "GET", "path" => "/version", "support" => "implemented", "responseStatuses" => [200, 500]},
    200,
    '{"ApiVersion":"1.51","Version":"test"}',
    "application/json"
  ).nil?,
  "declared success statuses must be accepted"
)
assert(
  validate_contract_response(
    {"method" => "GET", "path" => "/version", "support" => "implemented", "responseStatuses" => [200]},
    404,
    '{"message":"missing"}',
    "application/json"
  ).include?("not declared"),
  "undeclared statuses must fail the contract probe"
)
generated_matrix = JSON.parse(File.read(DEFAULT_MATRIX))
operations = generated_matrix.fetch("operations")
assert(operations.size == 107, "the generated matrix must contain 107 operations")
assert(
  operations.all? { |row| row.fetch("support") == "implemented" },
  "every Moby v1.51 operation must be marked implemented"
)
assert(
  operations.all? { |row| !contract_path(row.fetch("path")).empty? && !contract_body(row).nil? },
  "every matrix operation must have an executable contract request"
)
build_row = operations.find { |row| row.fetch("path") == "/build" }
assert(build_row, "the matrix must include the build operation")
assert(contract_body(build_row).start_with?("Dockerfile"), "the build contract must use a tar context")
assert(contract_path("/build").include?("t=glassdock-compat:latest"), "the build contract must include a tag")
assert(
  contract_body(operations.find { |row| row.fetch("path") == "/containers/{id}/archive" }).start_with?("Dockerfile"),
  "archive PUT must use a tar request body"
)
assert(
  contract_path("/images/{name}/push").include?("tag=latest"),
  "image push contracts must include the tag query"
)
assert(
  contract_path("/images/{name}/tag").include?("repo=glassdock-compat-tag"),
  "image tag contracts must include the repository query"
)
assert(contract_path("/plugins/privileges").include?("remote="), "plugin privilege contracts must include remote")
assert(contract_path("/volumes/{name}").include?("version=1"), "volume update contracts must include version")
fixture_paths = %w[
  /containers/{id}/exec /exec/{id}/start /networks/{id}/connect
  /networks/{id}/disconnect /services/{id}/update /volumes/{name}
]
fixture_paths.each do |path|
  row = operations.find { |operation| operation.fetch("path") == path }
  assert(row, "the matrix must include fixture path #{path}")
  assert(contract_body(row) != "{}", "#{path} must not use an empty contract body")
end

puts "compatibility script checks: ok"
