require "bundler/setup"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/system/**/*")
end

# Needs Chrome or Chromium; run separately so `rake test` works without one.
Rake::TestTask.new("test:system") do |t|
  t.libs << "test"
  t.test_files = FileList["test/system/**/*_test.rb"]
end

task default: :test
