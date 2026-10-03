#!/bin/bash
# Release hygiene (ADR-0010): the repository-side half of keeping the CI signing key to the one job the
# operator approves. Runs in CI and in preflight. It reads files; it signs, uploads and changes nothing.
#
#   scripts/release-hygiene.sh [ROOT]     # ROOT defaults to the repository; scripts/test-release-hygiene.sh
#                                         # points it at scratch copies to prove each refusal fires
#
# Each refusal prints its code (HYG0…HYG9) so the test can pin the condition rather than the wording.
#
# The workflows are read with a YAML parser (Ruby's Psych, which macOS ships), not with line patterns. The
# first version used patterns, and the helper-security review of 2026-10-02 walked past every one of them:
# a `#` inside a quoted string read as a comment, flow style (`on: [push, workflow_dispatch]`,
# `{uses: …}`), quoted keys, and `toJSON( secrets )`. Anything the parser refuses — including anchors and
# aliases, which could hide a key behind a name — is refused here too (HYG0).
#
# What it cannot see: the environment's protection rules, the rulesets and the secrets themselves live in
# GitHub's settings, not in this tree, and a tag on a commit that is not on `main` runs that commit's
# workflows, which this never read. The required reviewer is the control for that (ADR-0010).
set -u -o pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
fail=0

# HYG1. Signing material is never tracked. Tracked, not merely present: an ignored file in a working copy is
# the operator's business; a committed one is public the moment it is pushed. By extension only: a key
# saved under another name is not caught (ADR-0010).
tracked=$(git ls-files 2>/dev/null) || { echo "release-hygiene: $ROOT is not a git work tree" >&2; exit 2; }
bad=$(printf '%s\n' "$tracked" | /usr/bin/grep -iE '\.(p12|pfx|p8|cer|der|pem|certSigningRequest|mobileprovision|provisionprofile|keychain|keychain-db)$')
if [ -n "$bad" ]; then
    echo "release-hygiene: HYG1 — signing material is tracked: $(echo "$bad" | tr '\n' ' ')" >&2
    fail=1
fi

/usr/bin/ruby -ryaml - "$ROOT" <<'RUBY' || fail=1
# encoding: utf-8
root = ARGV[0]
wf_dir = File.join(root, ".github", "workflows")
release_rel = ".github/workflows/release.yml"
SIGN = %w[MACOS_CERT_P12_BASE64 MACOS_CERT_P12_PASSWORD NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID]
# What each release job may be granted; anything else, including a missing block, is refused.
RELEASE_JOBS = {
  "build" => { "contents" => "read" },
  "sign" => { "contents" => "read" },
  "publish" => { "contents" => "write", "id-token" => "write", "attestations" => "write" },
}
$failed = false
def refuse(code, msg)
  warn "release-hygiene: #{code} — #{msg}"
  $failed = true
end

# Every string in a node, keys included, with the path that leads to it.
def strings(node, path = [], &blk)
  case node
  when Hash then node.each { |k, v| strings(k, path, &blk); strings(v, path + [k], &blk) }
  when Array then node.each { |v| strings(v, path, &blk) }
  when String then blk.call(node, path)
  end
end
def hashes(node, &blk)
  case node
  when Hash then blk.call(node); node.each_value { |v| hashes(v, &blk) }
  when Array then node.each { |v| hashes(v, &blk) }
  end
end
# Written for the Ruby macOS ships (2.6 on macOS 26.7), so no Ruby 3 syntax.
def key_like?(k, name)
  k.to_s.casecmp?(name)
end
def get(h, name)
  h.is_a?(Hash) ? h.find { |k, _| key_like?(k, name) }&.last : nil
end
def events(on)
  case on
  when String then [on]
  when Array then on.map(&:to_s)
  when Hash then on.keys.map(&:to_s)
  else []
  end
end
# Each mention of the `secrets` context in a string: [name or nil]. Nil means it is reached some other way
# than `secrets.NAME` (indexing, toJSON, passing the whole context), which no workflow here needs.
# Matched anywhere in the string, not only inside `${{ }}`: an `if:` is an expression without them.
def secret_refs(s)
  s.scan(/(?<![A-Za-z0-9_])secrets(?![A-Za-z0-9_])(\s*\.\s*([A-Za-z_][A-Za-z0-9_]*))?/i).map { |_, name| name&.upcase }
end

# A key as Psych will read it: a plain `on`, `On` or `true` all become the boolean true, so comparing the text
# alone let two spellings of one key through (review round 3, N10). Compared case-insensitively on top.
SCANNER = Psych::ScalarScanner.new(Psych::ClassLoader.new)
def resolved(k)
  return nil unless k.is_a?(Psych::Nodes::Scalar)
  (k.plain ? SCANNER.tokenize(k.value) : k.value).to_s.downcase
end
def mapping_problems(node, out = [])
  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map { |k, _| resolved(k) }
    keys.compact.group_by(&:itself).each { |k, v| out << "a duplicate key '#{k}'" if v.size > 1 }
    out << "a merge key '<<'" if keys.include?("<<")
    # Only plain keys. A quoted key is compared as text and a plain one as Psych reads it, so `"on"` beside a
    # plain `on` was two keys to the check and one name to Actions (review round 4, N11). No workflow here
    # needs a quoted or complex key; refusing them makes the one comparison above sufficient.
    out << "a quoted or complex key" if node.children.each_slice(2).any? { |k, _| !(k.is_a?(Psych::Nodes::Scalar) && k.plain) }
    # Only ASCII keys. `downcase` leaves `ſ` (long s) alone while case-insensitive matching elsewhere, Ruby's
    # and .NET's, reads it as `s`: `permiſſions` beside `permissions` passed (review round 5, N12).
    out << "a key that is not ASCII" if node.children.each_slice(2).any? { |k, _| k.is_a?(Psych::Nodes::Scalar) && !k.value.ascii_only? }
  end
  (node.children || []).each { |c| mapping_problems(c, out) } if node.respond_to?(:children)
  out
end

files = Dir.glob(File.join(wf_dir, "*.{yml,yaml}")).sort
release = File.join(root, release_rel)
unless File.exist?(release)
  refuse "HYG2", "#{release_rel} is missing; the checks below have nothing to read"
end
files.each do |path|
  rel = path.sub(root + "/", "")
  begin
    text = File.read(path)
    # Duplicate keys and merge keys (`<<`) make the parser and Actions read different documents: Psych keeps
    # the last duplicate and applies merges, and Actions may do neither. Refused before reading (review
    # round 2, N8 and N9).
    stream = Psych.parse_stream(text)
    bad_keys = stream.children.size == 1 ? mapping_problems(stream) : ["#{stream.children.size} YAML documents"]
    # The top-level keys, as written, are the ones Actions knows. `On:` or `true:` beside `on:` would be read
    # by Psych as the same key, and by Actions as another (or an error).
    top = stream.children.first&.root
    if top.is_a?(Psych::Nodes::Mapping)
      top.children.each_slice(2) do |k, _|
        name = k.is_a?(Psych::Nodes::Scalar) ? k.value : nil
        unless %w[name run-name on permissions concurrency env defaults jobs].include?(name)
          bad_keys << "a top-level key Actions does not define (#{name.inspect})"
        end
      end
    end
    unless bad_keys.empty?
      refuse "HYG0", "#{rel} has #{bad_keys.uniq.join(', ')}"
      next
    end
    doc = YAML.safe_load(text, aliases: false)
  rescue Psych::Exception => e
    refuse "HYG0", "#{rel} cannot be read as plain YAML (#{e.class}); anchors and aliases are refused"
    next
  end
  unless doc.is_a?(Hash)
    refuse "HYG0", "#{rel} is not a mapping"
    next
  end
  on = doc.key?(true) ? doc[true] : get(doc, "on")
  is_release = (rel == release_rel)

  # HYG3. `pull_request_target` runs a fork's pull request with the base repository's secrets and token.
  refuse "HYG3", "#{rel} uses pull_request_target" if events(on).any? { |e| e.casecmp?("pull_request_target") }

  # HYG4. Every action and reusable workflow is pinned by a full commit SHA; a tag can be moved by whoever
  # controls the action. Local `./` actions are this commit's own files.
  hashes(doc) do |h|
    h.each do |k, v|
      next unless key_like?(k, "uses")
      next if v.is_a?(String) && (v.start_with?("./") || v.match?(/@[0-9a-f]{40}\z/))
      refuse "HYG4", "#{rel} has an action not pinned by SHA: #{v}"
    end
  end

  jobs = get(doc, "jobs")
  jobs = {} unless jobs.is_a?(Hash)
  # Who may name which secret: the job a string sits under, or "(workflow)" for top-level keys like `env`.
  refs = []
  strings(doc) do |s, p|
    owner = key_like?(p[0], "jobs") && p.length >= 2 ? p[1].to_s : "(workflow)"
    secret_refs(s).each { |name| refs << [owner, name] }
  end
  env_jobs = jobs.select { |_, j| j.is_a?(Hash) && j.keys.any? { |k| key_like?(k, "environment") } }.keys.map(&:to_s)

  unless is_release
    # HYG5. Only release.yml names an environment; the `release` environment's secrets reach only its jobs.
    refuse "HYG5", "#{rel} names an environment (#{env_jobs.join(', ')})" unless env_jobs.empty?
    # HYG6. Other workflows use no secret but SONAR_TOKEN and GITHUB_TOKEN, and only by name.
    refs.each do |owner, name|
      if name.nil?
        refuse "HYG6", "#{rel} (#{owner}) reaches the secrets context other than by name"
      elsif !%w[SONAR_TOKEN GITHUB_TOKEN].include?(name)
        refuse "HYG6", "#{rel} (#{owner}) uses secrets.#{name}"
      end
    end
    next
  end

  # HYG7. release.yml runs on a pushed `v*` tag and on nothing else, starts from no permissions, has exactly
  # the three jobs, each granted exactly what RELEASE_JOBS says, and calls no reusable workflow.
  refuse "HYG7", "#{rel} must run on `push: tags: ['v*']` and nothing else" unless on == { "push" => { "tags" => ["v*"] } }
  perms = get(doc, "permissions")
  refuse "HYG7", "#{rel} does not start from 'permissions: {}'" unless perms == {}
  refuse "HYG7", "#{rel} must have exactly the jobs #{RELEASE_JOBS.keys.join(', ')}" unless jobs.keys.map(&:to_s).sort == RELEASE_JOBS.keys.sort
  jobs.each do |name, job|
    next unless job.is_a?(Hash) && RELEASE_JOBS.key?(name.to_s)
    refuse "HYG7", "#{rel} job #{name} grants #{get(job, 'permissions').inspect}" unless get(job, "permissions") == RELEASE_JOBS[name.to_s]
    refuse "HYG7", "#{rel} job #{name} calls a reusable workflow" if job.keys.any? { |k| key_like?(k, "uses") || key_like?(k, "secrets") }
  end

  # HYG8. The helper stays out of a release built here (bundle-app.sh lists what is open).
  strings(doc) { |s, _| refuse "HYG8", "#{rel} builds with --with-helper" if s.include?("--with-helper") }

  # HYG9. The signing secrets appear only in the job named `sign`, and that job is the only one with an
  # environment, which is `release`.
  refs.each do |owner, name|
    if name.nil?
      refuse "HYG9", "#{rel} (#{owner}) reaches the secrets context other than by name"
    elsif SIGN.include?(name)
      refuse "HYG9", "#{rel}: secrets.#{name} is named outside the sign job (#{owner})" unless owner == "sign"
    elsif name != "GITHUB_TOKEN"
      refuse "HYG9", "#{rel} uses an unexpected secret: #{name} (#{owner})"
    end
  end
  refuse "HYG9", "the environment must be on the sign job alone (found on: #{env_jobs.empty? ? 'none' : env_jobs.join(', ')})" unless env_jobs == ["sign"]
  sign_env = jobs["sign"].is_a?(Hash) ? get(jobs["sign"], "environment") : nil
  refuse "HYG9", "the sign job's environment is not 'release'" if env_jobs == ["sign"] && sign_env != "release"
end
exit($failed ? 1 : 0)
RUBY

[ "$fail" = 0 ] && echo "release-hygiene: ok"
exit "$fail"
