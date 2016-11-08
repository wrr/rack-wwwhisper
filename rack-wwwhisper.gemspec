# -*- encoding: utf-8 -*-
require File.expand_path('../lib/rack/wwwhisper_version', __FILE__)

Gem::Specification.new do |s|
  s.name        = 'rack-wwwhisper'
  s.version     = Rack::WWWHISPER_VERSION
  s.platform    = Gem::Platform::RUBY
  s.summary     = 'Verified email based authorization for Rack applications.'
  s.description = 'Middleware uses wwwhisper service to authorize requests.'
  s.author      = 'Jan Wrobel'
  s.email       = 'wrr@mixedbit.org'
  s.files       = [
                   'lib/rack/wwwhisper.rb',
                   'lib/rack/wwwhisper_version.rb',
                   'test/test_wwwhisper.rb',
                   'Rakefile',
                  ]
  s.test_files  = ['test/test_wwwhisper.rb']
  s.homepage    = 'https://github.com/wrr/rack-wwwhisper'
  s.license     = 'BSD'
  if RUBY_VERSION.match('(^2\.[0|1]\.)|1\.9\.')
    s.add_runtime_dependency 'rack', '~> 1.0'
  else
    s.add_runtime_dependency 'rack', '>= 2.0'
  end
  s.add_runtime_dependency 'addressable', '~> 2.0'
  s.add_runtime_dependency 'net-http-persistent', '< 3.0'
  s.add_development_dependency 'rack-test'
  s.add_development_dependency 'webmock'
  s.add_development_dependency 'test-unit'
  s.add_development_dependency 'rake'
end
