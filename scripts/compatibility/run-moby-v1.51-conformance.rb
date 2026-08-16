#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"

ROOT = File.expand_path("../..", __dir__)
DEFAULT_MATRIX = File.join(ROOT, "Compatibility", "moby-v28.5.2-matrix.json")

options = {
  matrix: DEFAULT_MATRIX,
  socket: ENV["GLASSDOCK_SOCKET"],
  timeout: 10,
  smoke: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: run-moby-v1.51-conformance.rb --socket PATH [options]"
  parser.on("--socket PATH", "Glass Dock's Unix socket") { |value| options[:socket] = value }
  parser.on("--matrix PATH", "Generated compatibility matrix") { |value| options[:matrix] = value }
  parser.on("--timeout SECONDS", Integer, "Per-request timeout (default: 10)") { |value| options[:timeout] = value }
  parser.on("--smoke", "Also probe the core implemented endpoints") { options[:smoke] = true }
end.parse!

abort "set --socket or GLASSDOCK_SOCKET" unless options[:socket]
abort "socket does not exist: #{options[:socket]}" unless File.socket?(options[:socket])

matrix = JSON.parse(File.read(options[:matrix]))
unsupported = matrix.fetch("operations").select { |row| row.fetch("support") == "unsupported" }

def concrete_path(path)
  path.gsub(/\{[^}]+\}/, "glassdock-compat-missing")
end

def request(socket:, method:, path:, timeout:)
  url = "http://localhost/v1.51#{concrete_path(path)}"
  args = [
    "curl", "--silent", "--show-error", "--max-time", timeout.to_s,
    "--unix-socket", socket, "-X", method,
    "-H", "Accept: application/json",
    "-w", "\n%{http_code}", url
  ]
  unless method == "GET" || method == "HEAD"
    args.insert(-2, "--data-binary", "{}")
    args.insert(-2, "-H", "Content-Type: application/json")
  end
  stdout, stderr, status = Open3.capture3(*args)
  abort "curl failed for #{method} #{path}: #{stderr}" unless status.success?
  lines = stdout.lines
  code = Integer(lines.pop.to_s.strip)
  [code, lines.join]
end

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
  body_is_valid = method == "HEAD" || message.downcase.include?("not implemented")
  unless status == 501 && body_is_valid
    failures << "#{row.fetch("method")} #{row.fetch("path")}: expected 501 Docker error, got #{status} #{message.inspect}"
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
  puts "Moby v28.5.2 conformance passed: #{unsupported.size} explicit 501 operations#{options[:smoke] ? " plus core smoke probes" : ""}."
  exit 0
end

warn "Moby v28.5.2 conformance failed (#{failures.size} failures):"
warn failures.join("\n")
exit 1
