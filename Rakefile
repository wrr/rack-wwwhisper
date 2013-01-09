require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs << 'test'
end

desc "Run tests"
task :default => :test

task :gem do
  sh "gem build rack-wwwhisper.gemspec"
end
