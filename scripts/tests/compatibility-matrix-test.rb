#!/usr/bin/env ruby

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

puts "compatibility script checks: ok"
