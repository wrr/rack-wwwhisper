Gem::Specification.new do |s|
  s.name        = 'rack-wwwhisper'
  s.version     = '1.0.3.pre'
  s.platform    = Gem::Platform::RUBY
  s.date        = '2013-01-11'
  s.summary     = 'Persona based authorization layer for Rack applications.'
  s.description =
    'Middleware that uses wwwhisper service to authorize requests.'
  s.author      = 'Jan Wrobel'
  s.email       = 'wrr@mixedbit.org'
  s.files       = [
                   'lib/rack/wwwhisper.rb',
                   'test/test_wwwhisper.rb',
                   'Rakefile',
                  ]
  s.test_files  = ['test/test_wwwhisper.rb']
  s.homepage    = 'https://github.com/wrr/rack-wwwhisper'
  s.license     = 'BSD'
  s.add_runtime_dependency 'rack', '~> 1.0'
  s.add_runtime_dependency 'addressable', '~> 2.0'
  s.add_runtime_dependency 'net-http-persistent'
  s.add_development_dependency 'rack-test'
  s.add_development_dependency 'webmock'
  s.add_development_dependency 'rake'
end
