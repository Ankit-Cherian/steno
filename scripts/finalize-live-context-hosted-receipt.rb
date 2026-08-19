#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "set"

RESULT_BUNDLE, RECEIPT_PATH, MONITOR_SUMMARY_PATH, GIT_SHA, EXPORT_ROOT = ARGV
unless RESULT_BUNDLE && RECEIPT_PATH && MONITOR_SUMMARY_PATH && GIT_SHA && EXPORT_ROOT
  abort("usage: #{$PROGRAM_NAME} RESULT_BUNDLE RECEIPT MONITOR_SUMMARY GIT_SHA EXPORT_ROOT")
end

def run!(*arguments)
  stdout, stderr, status = Open3.capture3(*arguments)
  raise "#{arguments.join(" ")} failed: #{stderr.strip}" unless status.success?

  stdout
end

def stream_sha256_and_canary_count(path, canaries)
  digest = Digest::SHA256.new
  matches = Set.new
  overlap = "".b
  bytes_read = 0
  maximum_canary_bytes = canaries.map(&:bytesize).max
  File.open(path, "rb") do |file|
    while (chunk = file.read(1_048_576))
      digest.update(chunk)
      searchable = overlap + chunk
      searchable_start = bytes_read - overlap.bytesize
      canaries.each_with_index do |canary, canary_index|
        offset = 0
        while (match = searchable.index(canary, offset))
          absolute_start = searchable_start + match
          matches << [absolute_start, absolute_start + canary.bytesize, canary_index]
          offset = match + canary.bytesize
        end
      end
      overlap_bytes = [maximum_canary_bytes - 1, searchable.bytesize].min
      overlap = searchable.byteslice(-overlap_bytes, overlap_bytes) || "".b
      bytes_read += chunk.bytesize
    end
  end
  claimed_ranges = []
  matches.to_a.sort_by { |start_byte, end_byte, index| [-(end_byte - start_byte), start_byte, index] }.each do |start_byte, end_byte, _index|
    next if claimed_ranges.any? { |claimed_start, claimed_end| start_byte < claimed_end && claimed_start < end_byte }

    claimed_ranges << [start_byte, end_byte]
  end
  [digest.hexdigest, claimed_ranges.count]
end

def sorted_json(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, result| result[key] = sorted_json(value[key]) }
  when Array
    value.map { |element| sorted_json(element) }
  else
    value
  end
end

raise "result bundle is missing" unless File.directory?(RESULT_BUNDLE)
raise "hosted receipt is missing" unless File.file?(RECEIPT_PATH)
raise "network monitor summary is missing" unless File.file?(MONITOR_SUMMARY_PATH)
raise "invalid git SHA" unless GIT_SHA.match?(/\A[0-9a-fA-F]{40}\z/)
raise "attestation export path already exists" if File.exist?(EXPORT_ROOT)

FileUtils.mkdir_p(EXPORT_ROOT)
diagnostics_path = File.join(EXPORT_ROOT, "diagnostics")
attachments_path = File.join(EXPORT_ROOT, "attachments")
decoded_path = File.join(EXPORT_ROOT, "decoded")
FileUtils.mkdir_p(decoded_path)

run!("/usr/bin/xcrun", "xcresulttool", "export", "diagnostics", "--path", RESULT_BUNDLE, "--output-path", diagnostics_path)
run!("/usr/bin/xcrun", "xcresulttool", "export", "attachments", "--path", RESULT_BUNDLE, "--output-path", attachments_path)
summary = run!("/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path", RESULT_BUNDLE, "--compact")
tests = run!("/usr/bin/xcrun", "xcresulttool", "get", "test-results", "tests", "--path", RESULT_BUNDLE, "--compact")
File.binwrite(File.join(decoded_path, "summary.json"), summary)
File.binwrite(File.join(decoded_path, "tests.json"), tests)

seed = Digest::SHA256.hexdigest([
  "steno-live-context-hosted-canary/v2",
  GIT_SHA.downcase
].join("\0"))
base_canary = "STENO-LIVE-CONTEXT-HOSTED-#{seed}"
canaries = [
  base_canary,
  "#{base_canary}-PROVISIONAL",
  "#{base_canary}-CONTEXT",
  "#{base_canary}-SNIPPET-EXPANSION"
].map(&:b)

roots = {
  "result-bundle" => RESULT_BUNDLE,
  "diagnostics" => diagnostics_path,
  "attachments" => attachments_path,
  "decoded" => decoded_path
}
manifest_rows = []
canary_findings = 0
scanned_file_count = 0
roots.each do |label, root|
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path)

    relative_path = path.delete_prefix("#{root}/")
    sha256, findings = stream_sha256_and_canary_count(path, canaries)
    manifest_rows << "#{label}/#{relative_path}\0#{sha256}"
    canary_findings += findings
    scanned_file_count += 1
  end
end
raise "result bundle scan did not observe any files" unless scanned_file_count.positive?

monitor = JSON.parse(File.binread(MONITOR_SUMMARY_PATH))
receipt = JSON.parse(File.binread(RECEIPT_PATH))
raise "hosted receipt git SHA changed" unless receipt.fetch("gitSHA") == GIT_SHA.downcase
raise "hosted receipt already contains wrapper attestation" if receipt.key?("wrapperAttestation") && receipt["wrapperAttestation"]
privacy = receipt.fetch("privacy")
raise "hosted canary derivation mismatch" unless privacy.fetch("canaryDerivationDefinition") == "git-bound-base-v2-plus-provisional-context-and-snippet-expansion-suffixes-v1"
expected_canary_hashes = canaries.map { |canary| Digest::SHA256.hexdigest(canary) }
receipt_canary_hashes = [
  privacy.fetch("baseCanarySHA256"),
  privacy.fetch("provisionalCanarySHA256"),
  privacy.fetch("contextCanarySHA256"),
  privacy.fetch("snippetExpansionCanarySHA256")
]
raise "hosted canary identities mismatch" unless receipt_canary_hashes == expected_canary_hashes

attestation = monitor.merge(
  "networkObservationDefinition" => "50ms-lsof-polling-hosted-xctest-pid-and-descendants-transient-fds-between-polls-not-observed",
  "resultBundleScanDefinition" => "raw-xcresult-plus-exported-diagnostics-attachments-and-decoded-test-summary-all-derived-deterministic-canaries-scan",
  "resultBundleScanPerformed" => true,
  "resultBundleScannedFileCount" => scanned_file_count,
  "resultBundleCanaryFindings" => canary_findings,
  "resultBundleManifestSHA256" => Digest::SHA256.hexdigest(manifest_rows.sort.join("\n"))
)
identity_fields = [
  attestation.fetch("testIdentifier"),
  attestation.fetch("networkObservationDefinition"),
  attestation.fetch("resultBundleScanDefinition"),
  attestation.fetch("hostedTestProcessID").to_s,
  attestation.fetch("observationStartUnixMilliseconds").to_s,
  attestation.fetch("observationEndUnixMilliseconds").to_s,
  attestation.fetch("networkMonitorPerformed").to_s,
  attestation.fetch("networkPollIntervalMilliseconds").to_s,
  attestation.fetch("networkScanCount").to_s,
  attestation.fetch("networkObservationDurationMilliseconds").to_s,
  attestation.fetch("maximumObservedProcessTreeCount").to_s,
  attestation.fetch("observedNetworkFileDescriptorCount").to_s,
  attestation.fetch("resultBundleScanPerformed").to_s,
  attestation.fetch("resultBundleScannedFileCount").to_s,
  attestation.fetch("resultBundleCanaryFindings").to_s,
  attestation.fetch("resultBundleManifestSHA256")
]
attestation["attestationIdentitySHA256"] = Digest::SHA256.hexdigest(identity_fields.join("\0"))
receipt["wrapperAttestation"] = attestation

encoded = JSON.pretty_generate(sorted_json(receipt)) + "\n"
raise "raw hosted canary escaped into receipt" if canaries.any? { |canary| encoded.b.include?(canary) }

temporary_path = "#{RECEIPT_PATH}.tmp"
File.binwrite(temporary_path, encoded)
File.rename(temporary_path, RECEIPT_PATH)
