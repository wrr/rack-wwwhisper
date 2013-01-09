Gem::Specification.new do |s|
  s.name        = 'rack-wwwhisper'
  s.version     = '1.0.1'
  s.date        = '2013-01-09'
  s.summary     = 'Persona based authorization layer for Rack applications.'
  s.description =
    'Rack middleware that uses wwwhisper service to authorize visitors.'
  s.authors     = ['Jan Wrobel']
  s.email       = 'wrr@mixedbit.org'
  s.files       = ['lib/rack/wwwhisper.rb',
                   'test/tc_wwwhisper.rb']
  s.homepage    = 'https://github.com/wrr/rack-wwwhisper'
  s.platform    = Gem::Platform::RUBY
end
