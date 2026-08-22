#!/usr/bin/env ruby

require "digest"
require "json"
require "open-uri"
require "optparse"
require "set"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
SUPPORT_FILE = File.join(ROOT, "Compatibility", "moby-v28.5.2-support.yml")
DEFAULT_OUTPUT = File.join(ROOT, "Compatibility", "moby-v28.5.2-matrix.json")
ROUTE_SOURCE = File.join(ROOT, "Sources", "GlassDock", "Runtime", "ExplicitUnsupportedDockerRoutes.swift")
REGISTERED_ROUTE_ROOTS = [
  File.join(ROOT, "Sources", "GlassDock", "Runtime"),
  File.join(ROOT, "Sources", "GlassDock", "Routes", "Images", "ImageSearchRoute.swift"),
  File.join(ROOT, "Sources", "GlassDock", "Routes", "Registry"),
  File.join(ROOT, "Sources", "GlassDock", "Routes", "Server"),
  File.join(ROOT, "Sources", "GlassDock", "Routes", "Volumes"),
].freeze
METHODS = %w[get post put delete head options patch].freeze
SUPPORT_STATES = %w[full partial error-only].freeze

class MatrixError < StandardError; end

def normalize_path(path)
  path.gsub(/\{([^}:]+)(?::[^}]+)?\}/, '{\1}')
end

def key(method, path)
  "#{method.upcase} #{normalize_path(path)}"
end

def read_yaml(path)
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::Exception => error
  raise MatrixError, "could not parse #{path}: #{error.message}"
end

def read_spec(source, path)
  bytes = if path
    File.binread(path)
  else
    URI.open(source.fetch("url"), read_timeout: 30, &:read)
  end
  digest = Digest::SHA256.hexdigest(bytes)
  unless digest == source.fetch("sha256")
    raise MatrixError, "Moby spec digest mismatch: expected #{source.fetch("sha256")}, got #{digest}"
  end
  [YAML.safe_load(bytes, aliases: false), digest]
rescue Errno::ENOENT => error
  raise MatrixError, error.message
rescue OpenURI::HTTPError, SocketError, Timeout::Error => error
  raise MatrixError, "could not fetch pinned Moby spec: #{error.message}"
end

def response_statuses(operation)
  operation.fetch("responses", {}).keys.map(&:to_s).sort_by { |status| status.to_i }
end

def success_status(operation)
  response_statuses(operation).find { |status| status.match?(/\A2\d\d\z/) } ||
    response_statuses(operation).find { |status| status == "101" }
end

def response_schema(operation, status)
  response = operation.fetch("responses", {}).find { |key, _value| key.to_s == status.to_s }&.last || {}
  schema = response.fetch("schema", nil)
  return nil unless schema.is_a?(Hash)
  schema["$ref"] || schema["type"]
end

def parse_options
  options = {
    output: DEFAULT_OUTPUT, spec: nil, check: false, check_routes: false,
    check_registered_routes: false
  }
  OptionParser.new do |parser|
    parser.banner = "Usage: generate-moby-v1.51-matrix.rb [options]"
    parser.on("--spec PATH", "Read the pinned Swagger file from PATH") { |value| options[:spec] = value }
    parser.on("--output PATH", "Write the generated JSON matrix to PATH") { |value| options[:output] = value }
    parser.on("--check", "Fail if the checked-in matrix is not current") { options[:check] = true }
    parser.on("--check-routes", "Verify every generated unsupported row has a 501 route") { options[:check_routes] = true }
    parser.on(
      "--check-registered-routes",
      "Verify every matrix operation has a registered route in the configured collections"
    ) { options[:check_registered_routes] = true }
  end.parse!
  options
end

def registered_routes(roots = REGISTERED_ROUTE_ROOTS)
  files = roots.flat_map do |root|
    File.directory?(root) ? Dir[File.join(root, "**", "*.swift")] : [root]
  end
  files.flat_map do |path|
    text = File.read(path)
    (
      text.scan(/registerVersionedRoute\(\.([A-Z]+),\s*pattern:\s*"([^"]+)"/) +
      text.scan(/Endpoint\(method:\s*\.([A-Z]+),\s*pattern:\s*"([^"]+)"\)/)
    ).map { |method, route| key(method, route) }
  end.to_set
end

def check_registered_routes(matrix, roots: REGISTERED_ROUTE_ROOTS)
  expected = matrix.fetch("operations").map { |row| key(row["method"], row["path"]) }.to_set
  missing = expected - registered_routes(roots)
  raise MatrixError, "missing registered routes: #{missing.to_a.sort.join(", ")}" unless missing.empty?
end

def build_matrix(spec, source, configured_routes, digest)
  unless spec.dig("info", "version").to_s == source.dig("apiVersion").to_s
    raise MatrixError, "Moby spec API version does not match support manifest"
  end
  unless spec["basePath"].to_s == "/v#{source.dig("apiVersion")}"
    raise MatrixError, "Moby spec basePath is not pinned to v#{source.dig("apiVersion")}"
  end

  rows = []
  spec.fetch("paths").each do |path, operations|
    operations.each do |method, operation|
      next unless METHODS.include?(method.to_s.downcase)
      normalized_key = key(method, path)
      config = configured_routes[normalized_key]
      unless config
        raise MatrixError,
          "#{normalized_key} is missing from the support manifest; classify it as full, partial, or error-only"
      end
      support = config.fetch("support")
      unless SUPPORT_STATES.include?(support)
        raise MatrixError, "#{normalized_key} has invalid support state #{support.inspect} (expected one of #{SUPPORT_STATES.join(", ")})"
      end
      success = success_status(operation)
      raise MatrixError, "#{normalized_key} has no success response in the Moby spec" unless success
      expected_status =
        if config.key?("expectedStatus")
          config.fetch("expectedStatus")
        elsif support == "error-only"
          raise MatrixError, "#{normalized_key} is error-only and must declare expectedStatus"
        else
          success.to_i
        end
      rows << {
        "method" => method.upcase,
        "path" => normalize_path(path),
        "operationId" => operation.fetch("operationId", ""),
        "support" => support,
        "expectedStatus" => expected_status,
        "responseStatuses" => response_statuses(operation).map(&:to_i),
        "responseSchema" => response_schema(operation, success),
        "owner" => config.fetch("owner"),
        "note" => config.fetch("note", "")
      }
    end
  end
  stale = configured_routes.keys.to_set - rows.map { |row| key(row["method"], row["path"]) }.to_set
  raise MatrixError, "support manifest lists unknown operations: #{stale.to_a.sort.join(", ")}" unless stale.empty?
  rows.sort_by! { |row| [row["path"], row["method"]] }
  {
    "schema" => 2,
    "source" => {
      "repository" => source.dig("repository"),
      "ref" => source.dig("ref"),
      "url" => source.dig("url"),
      "sha256" => digest,
      "apiVersion" => source.dig("apiVersion")
    },
    "operations" => rows
  }
end

def check_routes(matrix)
  text = File.read(ROUTE_SOURCE)
  routes = (
    text.scan(/Endpoint\(method:\s*\.([A-Z]+),\s*pattern:\s*"([^"]+)"\)/) +
    text.scan(/registerVersionedRoute\(\.([A-Z]+),\s*pattern:\s*"([^"]+)"/)
  ).map { |method, path| key(method, path) }.to_set
  expected = matrix.fetch("operations")
    .select { |row| row["owner"] == "ExplicitUnsupportedDockerRoutes" && row["support"] == "error-only" }
    .map { |row| key(row["method"], row["path"]) }.to_set
  served_elsewhere =
    matrix.fetch("operations")
      .select { |row| row["owner"] == "ExplicitUnsupportedDockerRoutes" && row["support"] != "error-only" }
      .map { |row| key(row["method"], row["path"]) }.to_set
  routes -= served_elsewhere
  missing = expected - routes
  extra = routes - expected
  problems = []
  problems << "missing explicit unsupported routes: #{missing.to_a.sort.join(", ")}" unless missing.empty?
  problems << "extra explicit unsupported routes: #{extra.to_a.sort.join(", ")}" unless extra.empty?
  raise MatrixError, problems.join("\n") unless problems.empty?
end

def main
  options = parse_options
  support = read_yaml(SUPPORT_FILE)
  spec, digest = read_spec(support.fetch("source"), options[:spec])
  configured_routes = support.fetch("routes").to_h do |route|
    route = route.transform_keys(&:to_s)
    [key(route.fetch("method"), route.fetch("path")), route]
  end
  if configured_routes.size != support.fetch("routes").size
    raise MatrixError, "duplicate route entries in #{SUPPORT_FILE}"
  end
  matrix = build_matrix(spec, support.fetch("source"), configured_routes, digest)
  check_routes(matrix) if options[:check_routes]
  check_registered_routes(matrix) if options[:check_registered_routes]
  generated = JSON.pretty_generate(matrix) + "\n"
  if options[:check]
    actual = File.read(options[:output])
    raise MatrixError, "#{options[:output]} is stale; regenerate the pinned matrix" unless actual == generated
  else
    File.write(options[:output], generated)
  end
  puts "Moby #{matrix.dig("source", "ref")} API v#{matrix.dig("source", "apiVersion")}: #{matrix.fetch("operations").size} operations"
  puts "support: #{matrix.fetch("operations").group_by { |row| row["support"] }.transform_values(&:count).sort.to_h}"
rescue KeyError, TypeError => error
  warn "compatibility matrix error: #{error.message}"
  exit 1
rescue MatrixError => error
  warn "compatibility matrix error: #{error.message}"
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
