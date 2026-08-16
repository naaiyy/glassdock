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
METHODS = %w[get post put delete head options patch].freeze

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

def unsupported_reason(path)
  case path
  when "/build", "/build/prune", "/commit"
    "BuildKit and image commit are not owned by the persistent guest runtime."
  when %r{\A/(swarm|nodes|services|tasks|secrets|configs)(/|\z)}
    "Docker Swarm is not supported by the single-host Apple container runtime."
  when %r{\A/plugins(/|\z)}
    "Docker plugins require a host plugin manager that Glass Dock does not provide."
  when %r{\A/networks(/|\z)}
    "Network objects are owned by the guest runtime and do not yet have a Docker API adapter."
  when "/system/df"
    "The guest runtime does not expose complete Docker system disk accounting."
  when "/session"
    "Interactive sessions require a guest terminal handoff that is not implemented."
  when %r{/archive\z}, %r{/attach/ws\z}, %r{/export\z}, %r{/stats\z}, %r{/top\z}, %r{/changes\z}
    "The persistent guest protocol does not expose this container operation yet."
  when %r{/images/(get|search)\z}, %r{/history\z}, "/images/load"
    "The persistent guest protocol does not expose this image operation yet."
  else
    "No persistent guest runtime implementation is registered for this Docker API operation."
  end
end

def parse_options
  options = { output: DEFAULT_OUTPUT, spec: nil, check: false, check_routes: false }
  OptionParser.new do |parser|
    parser.banner = "Usage: generate-moby-v1.51-matrix.rb [options]"
    parser.on("--spec PATH", "Read the pinned Swagger file from PATH") { |value| options[:spec] = value }
    parser.on("--output PATH", "Write the generated JSON matrix to PATH") { |value| options[:output] = value }
    parser.on("--check", "Fail if the checked-in matrix is not current") { options[:check] = true }
    parser.on("--check-routes", "Verify every generated unsupported row has a 501 route") { options[:check_routes] = true }
  end.parse!
  options
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
      success = success_status(operation)
      raise MatrixError, "#{normalized_key} has no success response in the Moby spec" unless success
      rows << {
        "method" => method.upcase,
        "path" => normalize_path(path),
        "operationId" => operation.fetch("operationId", ""),
        "support" => config&.fetch("support", "unsupported") || "unsupported",
        "expectedStatus" => config&.fetch("expectedStatus", nil) || (config ? success.to_i : 501),
        "responseStatuses" => response_statuses(operation).map(&:to_i),
        "responseSchema" => response_schema(operation, success),
        "owner" => config&.fetch("owner", "ExplicitUnsupportedDockerRoutes") || "ExplicitUnsupportedDockerRoutes",
        "note" => config&.fetch("note", nil) || unsupported_reason(path)
      }
    end
  end
  rows.sort_by! { |row| [row["path"], row["method"]] }
  {
    "schema" => 1,
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
  routes = text.scan(/Endpoint\(method:\s*\.([A-Z]+),\s*pattern:\s*"([^"]+)"\)/).map { |method, path| key(method, path) }.to_set
  expected = matrix.fetch("operations").select { |row| row["support"] == "unsupported" }.map { |row| key(row["method"], row["path"]) }.to_set
  missing = expected - routes
  extra = routes - expected
  problems = []
  problems << "missing explicit 501 routes: #{missing.to_a.sort.join(", ")}" unless missing.empty?
  problems << "extra explicit 501 routes: #{extra.to_a.sort.join(", ")}" unless extra.empty?
  raise MatrixError, problems.join("\n") unless problems.empty?
end

begin
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
