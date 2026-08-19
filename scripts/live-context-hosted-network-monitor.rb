#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "set"

CONTROL_DIRECTORY, OUTPUT_PATH = ARGV
abort("usage: #{$PROGRAM_NAME} CONTROL_DIRECTORY OUTPUT_PATH") unless CONTROL_DIRECTORY && OUTPUT_PATH

START_PATH = File.join(CONTROL_DIRECTORY, "observation-start.json")
END_PATH = File.join(CONTROL_DIRECTORY, "observation-end.json")
ABORT_PATH = File.join(CONTROL_DIRECTORY, "abort")
POLL_INTERVAL_SECONDS = 0.05
POLL_INTERVAL_MILLISECONDS = 50
START_DEADLINE_SECONDS = 180

def read_json(path)
  JSON.parse(File.binread(path))
end

def process_tree(root_pid)
  stdout, stderr, status = Open3.capture3("/bin/ps", "-axo", "pid=,ppid=")
  raise "ps failed: #{stderr.strip}" unless status.success?

  children = Hash.new { |hash, key| hash[key] = [] }
  observed_pids = Set.new
  stdout.each_line do |line|
    pid_text, parent_text = line.split
    next unless pid_text && parent_text

    pid = Integer(pid_text, exception: false)
    parent = Integer(parent_text, exception: false)
    next unless pid && parent

    observed_pids << pid
    children[parent] << pid
  end
  return nil unless observed_pids.include?(root_pid)

  result = []
  pending = [root_pid]
  until pending.empty?
    pid = pending.shift
    next if result.include?(pid)

    result << pid
    pending.concat(children[pid])
  end
  result
end

def network_file_descriptors(pids)
  stdout, stderr, status = Open3.capture3(
    "/usr/sbin/lsof", "-nP", "-a", "-p", pids.join(","), "-i"
  )
  unless status.success? || (status.exitstatus == 1 && stdout.empty? && stderr.empty?)
    raise "lsof failed: #{stderr.strip}"
  end

  lines = stdout.lines.map(&:strip).reject(&:empty?)
  lines.shift if lines.first&.start_with?("COMMAND ")
  lines
end

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_DEADLINE_SECONDS
until File.file?(START_PATH)
  abort("hosted test aborted before observation began") if File.exist?(ABORT_PATH)
  abort("timed out waiting for hosted test observation marker") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep(POLL_INTERVAL_SECONDS)
end

start = read_json(START_PATH)
test_identifier = start.fetch("testIdentifier")
root_pid = Integer(start.fetch("hostedTestProcessID"))
start_milliseconds = Integer(start.fetch("observationStartUnixMilliseconds"))
raise "invalid hosted test process identifier" unless root_pid.positive?
raise "invalid observation start" unless start_milliseconds.positive?

scan_count = 0
maximum_process_tree_count = 0
observed_network_descriptors = Set.new
loop do
  break if scan_count.positive? && File.file?(END_PATH)

  pids = process_tree(root_pid)
  if pids.nil?
    break if scan_count.positive? && File.file?(END_PATH)

    raise "hosted test process exited before observation completed"
  end
  descriptors = network_file_descriptors(pids)
  scan_count += 1
  maximum_process_tree_count = [maximum_process_tree_count, pids.count].max
  descriptors.each { |line| observed_network_descriptors << line }
  break if File.file?(END_PATH)
  raise "hosted test aborted during observation" if File.exist?(ABORT_PATH)

  sleep(POLL_INTERVAL_SECONDS)
end

finish = read_json(END_PATH)
raise "test identifier changed during observation" unless finish.fetch("testIdentifier") == test_identifier
raise "test process changed during observation" unless Integer(finish.fetch("hostedTestProcessID")) == root_pid
raise "observation start changed" unless Integer(finish.fetch("observationStartUnixMilliseconds")) == start_milliseconds

end_milliseconds = Integer(finish.fetch("observationEndUnixMilliseconds"))
raise "invalid observation end" if end_milliseconds < start_milliseconds
raise "network monitor performed no scans" unless scan_count.positive?

summary = {
  "testIdentifier" => test_identifier,
  "hostedTestProcessID" => root_pid,
  "observationStartUnixMilliseconds" => start_milliseconds,
  "observationEndUnixMilliseconds" => end_milliseconds,
  "networkMonitorPerformed" => true,
  "networkPollIntervalMilliseconds" => POLL_INTERVAL_MILLISECONDS,
  "networkScanCount" => scan_count,
  "networkObservationDurationMilliseconds" => end_milliseconds - start_milliseconds,
  "maximumObservedProcessTreeCount" => maximum_process_tree_count,
  "observedNetworkFileDescriptorCount" => observed_network_descriptors.count
}
temporary_path = "#{OUTPUT_PATH}.tmp"
File.binwrite(temporary_path, JSON.pretty_generate(summary) + "\n")
File.rename(temporary_path, OUTPUT_PATH)
