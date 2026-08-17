#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"

CONFORMANCE_ROOT = File.expand_path("../..", __dir__)
DEFAULT_MATRIX = File.join(CONFORMANCE_ROOT, "Compatibility", "moby-v28.5.2-matrix.json")

def parse_options
  options = {
    matrix: DEFAULT_MATRIX,
    socket: ENV["GLASSDOCK_SOCKET"],
    timeout: 10,
    smoke: false,
    all: false
  }

  OptionParser.new do |parser|
    parser.banner = "Usage: run-moby-v1.51-conformance.rb --socket PATH [options]"
    parser.on("--socket PATH", "Glass Dock's Unix socket") { |value| options[:socket] = value }
    parser.on("--matrix PATH", "Generated compatibility matrix") { |value| options[:matrix] = value }
    parser.on("--timeout SECONDS", Integer, "Per-request timeout (default: 10)") { |value| options[:timeout] = value }
    parser.on("--smoke", "Also probe the core implemented endpoints") { options[:smoke] = true }
    parser.on("--all", "Probe every matrix operation and run supported side-effect checks") { options[:all] = true }
  end.parse!
  options
end

def concrete_path(path)
  path.gsub(/\{[^}]+\}/, "glassdock-compat-missing")
end

def request(socket:, method:, path:, timeout:, body: nil, body_content_type: nil)
  url = "http://localhost/v1.51#{concrete_path(path)}"
  args = [
    "curl", "--silent", "--show-error", "--max-time", timeout.to_s,
    "--unix-socket", socket, "-X", method,
    "-H", "Accept: application/json",
    "-w", "\n%{http_code}\n%{content_type}\n", url
  ]
  stdin_data = nil
  unless method == "GET" || method == "HEAD"
    args.insert(-2, "--data-binary", "@-")
    args.insert(-2, "-H", "Content-Type: #{body_content_type || "application/json"}")
    stdin_data = body || "{}"
  end
  stdout, stderr, status = Open3.capture3(*args, stdin_data: stdin_data)
  unless status.success?
    warn "curl failed for #{method} #{path}: #{stderr.strip}"
    return [599, "", ""]
  end
  lines = stdout.lines
  content_type = lines.pop.to_s.strip
  code = Integer(lines.pop.to_s.strip)
  [code, lines.join, content_type]
end

def body_is_valid?(method, message)
  method == "HEAD" || message.downcase.include?("not implemented")
end

def tar_context
  entries = {"Dockerfile" => "FROM alpine\nCOPY app.txt /opt/app.txt\n", "app.txt" => "conformance\n"}
  output = +""
  entries.each do |name, contents|
    header = "\0" * 512
    header[0, name.bytesize] = name
    header[100, 8] = "0000644\0"
    header[108, 8] = "0000000\0"
    header[116, 8] = "0000000\0"
    header[124, 12] = format("%011o\0", contents.bytesize)
    header[136, 12] = "00000000000\0"
    header[156] = "0"
    header[257, 6] = "ustar\0"
    header[148, 8] = "        "
    checksum = header.bytes.sum
    header[148, 8] = format("%06o\0 ", checksum)
    output << header << contents
    output << "\0" * ((512 - (contents.bytesize % 512)) % 512)
  end
  output << "\0" * 1024
end

def contract_path(path)
  concrete = concrete_path(path)
  case path
  when "/build"
    "#{concrete}?t=glassdock-compat:latest"
  when "/images/create"
    "#{concrete}?fromImage=alpine&tag=latest"
  when "/containers/json"
    "#{concrete}?all=1"
  when "/containers/{id}/logs", "/services/{id}/logs", "/tasks/{id}/logs"
    "#{concrete}?follow=false&tail=0"
  when "/containers/{id}/stats"
    "#{concrete}?stream=false"
  when "/events"
    "#{concrete}?since=0&until=1"
  else
    concrete
  end
end

def contract_body(row)
  path = row.fetch("path")
  return tar_context if path == "/build"
  return '{"username":"probe","password":"probe"}' if path == "/auth"
  return '{"Image":"alpine"}' if path == "/containers/create"
  return '{"Name":"glassdock-compat-volume"}' if path == "/volumes/create"
  return '{"Name":"glassdock-compat-network"}' if path == "/networks/create"
  return '{"Name":"glassdock-compat-config","Data":"Y29uZmln"}' if path == "/configs/create"
  return '{"Name":"glassdock-compat-secret","Data":"c2VjcmV0"}' if path == "/secrets/create"
  return '{"Name":"glassdock-compat-service","TaskTemplate":{"ContainerSpec":{"Image":"alpine"}}}' if path == "/services/create"
  return '{"ListenAddr":"127.0.0.1:2377"}' if path == "/swarm/init"
  return '{"RemoteAddrs":["127.0.0.1:2377"],"JoinToken":"SWMTKN-1-invalid"}' if path == "/swarm/join"
  return '{"Force":true}' if path == "/swarm/leave"
  "{}"
end

def json_body(body)
  return nil if body.empty?

  JSON.parse(body)
rescue JSON::ParserError
  lines = body.lines.map(&:strip).reject(&:empty?)
  return nil if lines.empty?

  begin
    lines.map { |line| JSON.parse(line) }
  rescue JSON::ParserError
    nil
  end
end

def validate_contract_response(row, status, body, content_type)
  method = row.fetch("method")
  path = row.fetch("path")
  return nil if status == 101
  if status >= 500 && status != 501 && status != 503
    return "#{method} #{path}: unexpected server error #{status}"
  end
  return nil if path == "/_ping" && body == "OK"
  binary = content_type.include?("raw-stream") || content_type.include?("tar") || content_type.include?("octet-stream")
  if method != "HEAD" && !body.empty? && !binary
    return "#{method} #{path}: response body is not valid JSON" unless json_body(body)
  end
  if !body.empty? && status >= 400 && !content_type.include?("json")
    return "#{method} #{path}: error response lacks a JSON content type (#{content_type.inspect})"
  end
  return validate_success_schema(row, status, body, content_type)
end

def validate_success_schema(row, status, body, content_type)
  return nil unless status.between?(200, 299) && !body.empty?
  return nil if content_type.include?("raw-stream") || content_type.include?("tar") || content_type.include?("octet-stream")

  value = json_body(body)
  method = row.fetch("method")
  path = row.fetch("path")
  return "#{method} #{path}: successful response is not a JSON object or array" unless value.is_a?(Hash) || value.is_a?(Array)

  required = case path
             when "/version"
               %w[ApiVersion Version]
             when "/containers/create"
               %w[Id Warnings]
             when "/configs/create", "/secrets/create"
               %w[ID]
             when "/networks/create"
               %w[Id Warning]
             when "/volumes/create"
               %w[Name Driver Mountpoint]
             when "/images/create", "/images/{name}/tag", "/images/{name}/push"
               []
             else
               nil
             end
  return nil if required.nil? || value.is_a?(Array)

  missing = required.reject { |key| value.key?(key) }
  return "#{method} #{path}: successful response is missing required field(s) #{missing.join(", ")}" unless missing.empty?

  nil
end

def check_side_effect(socket:, row:, status:, body:, timeout:)
  return [] unless status.between?(200, 299)
  value = json_body(body)
  return [] unless value.is_a?(Hash)
  checks = []
  case row.fetch("path")
  when "/volumes/create"
    name = value["Name"]
    if name
      inspect_status, = request(socket: socket, method: "GET", path: "/volumes/#{name}", timeout: timeout)
      checks << "volume #{name} was not inspectable after create" unless inspect_status == 200
      delete_status, = request(socket: socket, method: "DELETE", path: "/volumes/#{name}", timeout: timeout)
      checks << "volume #{name} was not removable after create" unless delete_status == 204
    end
  when "/networks/create"
    id = response_identity(value)
    if id
      inspect_status, = request(socket: socket, method: "GET", path: "/networks/#{id}", timeout: timeout)
      checks << "network #{id} was not inspectable after create" unless inspect_status == 200
      delete_status, = request(socket: socket, method: "DELETE", path: "/networks/#{id}", timeout: timeout)
      checks << "network #{id} was not removable after create" unless delete_status == 204
    end
  when "/configs/create", "/secrets/create"
    id = response_identity(value)
    if id
      prefix = row.fetch("path").split("/").first(2).join("/")
      inspect_status, = request(socket: socket, method: "GET", path: "#{prefix}/#{id}", timeout: timeout)
      checks << "#{prefix} #{id} was not inspectable after create" unless inspect_status == 200
      delete_status, = request(socket: socket, method: "DELETE", path: "#{prefix}/#{id}", timeout: timeout)
      checks << "#{prefix} #{id} was not removable after create" unless delete_status == 204
    end
  end
  checks
end

def response_identity(value)
  value["Id"] || value["ID"]
end

def main(options = parse_options)
  abort "set --socket or GLASSDOCK_SOCKET" unless options[:socket]
  abort "socket does not exist: #{options[:socket]}" unless File.socket?(options[:socket])

  matrix = JSON.parse(File.read(options[:matrix]))
  unsupported = matrix.fetch("operations").select { |row| row.fetch("support") == "unsupported" }
  failures = []
  unsupported.each do |row|
    status, body = request(
      socket: options[:socket], method: row.fetch("method"), path: row.fetch("path"), timeout: options[:timeout]
    )
    begin
      parsed = JSON.parse(body) unless body.empty?
      message = parsed.is_a?(Hash) ? parsed["message"].to_s : ""
    rescue JSON::ParserError
      message = "invalid JSON error body"
    end
    body_is_valid = body_is_valid?(row.fetch("method"), message)
    unless status == 501 && body_is_valid
      failures << "#{row.fetch("method")} #{row.fetch("path")}: expected 501 Docker error, got #{status} #{message.inspect}"
    end
  end

  if options[:all]
    matrix.fetch("operations").each do |row|
      method = row.fetch("method")
      path = contract_path(row.fetch("path"))
      status, body, content_type = request(
        socket: options[:socket], method: method, path: path, timeout: options[:timeout],
        body: contract_body(row),
        body_content_type: row.fetch("path") == "/build" ? "application/x-tar" : nil
      )
      if (failure = validate_contract_response(row, status, body, content_type))
        failures << failure
      end
      failures.concat(check_side_effect(
        socket: options[:socket], row: row, status: status, body: body, timeout: options[:timeout]
      ))
    end
  end

  if options[:smoke]
    smoke = [
      ["GET", "/_ping", 200],
      ["HEAD", "/_ping", 200],
      ["GET", "/version", 200],
      ["GET", "/info", 200],
      ["GET", "/containers/json", 200],
      ["GET", "/images/json", 200],
      ["GET", "/volumes", 200]
    ]
    smoke.each do |method, path, expected|
      status, = request(socket: options[:socket], method: method, path: path, timeout: options[:timeout])
      failures << "#{method} #{path}: expected #{expected}, got #{status}" unless status == expected
    end
  end

  if failures.empty?
    coverage = options[:all] ? " plus 107 operation contract probes and side-effect checks" : ""
    puts "Moby v28.5.2 conformance passed: #{unsupported.size} explicit 501 operations#{options[:smoke] ? " plus core smoke probes" : ""}#{coverage}."
    return 0
  end

  warn "Moby v28.5.2 conformance failed (#{failures.size} failures):"
  warn failures.join("\n")
  1
end

exit(main) if __FILE__ == $PROGRAM_NAME
