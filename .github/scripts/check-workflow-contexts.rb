#!/usr/bin/env ruby
# Checks known context roots in workflow/job env only, not full Actions validity.
# https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability
require 'psych'
require 'strscan'

KNOWN_CONTEXTS = %w[github needs strategy matrix vars secrets inputs runner env job jobs steps].freeze
WORKFLOW_ENV_CONTEXTS = %w[github secrets inputs vars].freeze
JOB_ENV_CONTEXTS = %w[github needs strategy matrix vars secrets inputs].freeze

def context_roots(text)
  scanner = StringScanner.new(text)
  roots = []
  while scanner.scan_until(/\$\{\{/)
    previous = nil
    until scanner.eos? || scanner.scan(/\}\}/)
      if scanner.scan(/\s+/)
        next
      elsif scanner.scan(/'(?:[^']|'')*'/m)
        previous = :literal
      elsif (name = scanner.scan(/[A-Za-z_][A-Za-z0-9_-]*/))
        name = name.downcase
        roots << name if previous != '.' && KNOWN_CONTEXTS.include?(name)
        previous = :identifier
      else
        previous = scanner.getch
      end
    end
  end
  roots.uniq
end

def env_errors(value, allowed, location)
  case value
  when Hash
    value.flat_map { |key, item| env_errors(item, allowed, "#{location}.#{key}") }
  when Array
    value.each_with_index.flat_map { |item, i| env_errors(item, allowed, "#{location}[#{i}]") }
  when String
    (context_roots(value) - allowed).map do |context|
      "#{location}: context '#{context}' is unavailable here (allowed: #{allowed.join(', ')})"
    end
  else
    []
  end
end

def workflow_errors(document)
  return [] unless document.is_a?(Hash)
  errors = env_errors(document['env'], WORKFLOW_ENV_CONTEXTS, 'env')
  jobs = document['jobs']
  if jobs.is_a?(Hash)
    jobs.each do |name, job|
      next unless job.is_a?(Hash)
      errors.concat(env_errors(job['env'], JOB_ENV_CONTEXTS, "jobs.#{name}.env"))
    end
  end
  errors
end

def parse_workflow(text)
  Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
end

def self_test
  cases = []
  WORKFLOW_ENV_CONTEXTS.each do |context|
    cases << ["root allows #{context}", "env:\n  X: ${{ #{context}.value }}\n", 0]
  end
  JOB_ENV_CONTEXTS.each do |context|
    cases << ["job allows #{context}", "jobs:\n  test:\n    env:\n      X: ${{ #{context}['value'] }}\n", 0]
  end
  (KNOWN_CONTEXTS - WORKFLOW_ENV_CONTEXTS).each do |context|
    cases << ["root rejects #{context}", "env:\n  X: ${{ #{context}.value }}\n", 1]
  end
  (KNOWN_CONTEXTS - JOB_ENV_CONTEXTS).each do |context|
    cases << ["job rejects #{context}", "jobs:\n  test:\n    env:\n      X: ${{ toJSON(#{context}) }}\n", 1]
  end
  cases.concat([
    ['step runner allowed', "jobs:\n  test:\n    steps:\n      - env:\n          X: ${{ runner.temp }}\n        run: echo ${{ runner.os }}\n", 0],
    ['job bracket and whitespace access rejected', "jobs:\n  test:\n    env:\n      X: ${{ runner ['temp'] }}\n", 1],
    ['multiple expressions checked', "env:\n  X: ${{ github.ref }}/${{ runner.temp }}\n", 1],
    ['quoted roots ignored', "env:\n  X: ${{ format('runner.temp env job steps', github.ref) }}\n", 0],
    ['escaped quote and close ignored', "env:\n  X: ${{ format('it''s }} runner.temp', github.ref) }}\n", 0],
    ['property names ignored', "env:\n  X: ${{ github.event.runner.env }}\n", 0],
    ['bracket strings ignored', "env:\n  X: ${{ github['runner']['env'] }}\n", 0],
    ['nested argument checked', "env:\n  X: ${{ format('x', runner.temp) }}\n", 1],
    ['bare whole env checked', "env: ${{ toJSON(runner) }}\n", 1],
    ['case insensitive root checked', "env:\n  X: ${{ RUNNER.temp }}\n", 1],
    ['shell runtime variable allowed', "env:\n  X: literal runner.temp $RUNNER_TEMP\n", 0],
    ['other workflow keys outside scope', "jobs:\n  test:\n    runs-on: ${{ runner.os }}\n", 0],
    ['YAML on key does not affect env traversal', "on: push\nenv:\n  X: ${{ runner.temp }}\n", 1],
    ['YAML env alias checked per scope', "env: &vars\n  X: ${{ matrix.value }}\njobs:\n  test:\n    env: *vars\n", 1]
  ])
  cases.each do |name, yaml, count|
    errors = workflow_errors(parse_workflow(yaml))
    raise "#{name}: expected #{count} errors, got #{errors.inspect}" unless errors.length == count
  end
  puts "Workflow env context self-tests: #{cases.length} passed"
end

if ARGV == ['--self-test']
  self_test
  exit
end

files = ARGV.empty? ? Dir.glob('.github/workflows/*.{yml,yaml}').sort : ARGV
abort 'No workflow files supplied or found' if files.empty?
errors = files.flat_map do |file|
  begin
    workflow_errors(parse_workflow(File.read(file))).map { |error| "#{file}: #{error}" }
  rescue Psych::Exception, SystemCallError => e
    ["#{file}: #{e.class}: #{e.message}"]
  end
end
abort errors.join("\n") unless errors.empty?
puts "Workflow env contexts: #{files.length} files passed (workflow/job env only; full Actions validation still required)"
