# Rack middleware that uses wwwhisper service to authorize visitors.
# Copyright (C) 2013 Jan Wrobel <wrr@mixedbit.org>
#
# This program is freely distributable under the terms of the
# Simplified BSD License. See COPYING.

require 'rack/test'
require 'test/unit'
require 'webmock/test_unit'
require 'rack/wwwhisper'
require 'rack/wwwhisper_version'

ENV['RACK_ENV'] = 'test'

TEST_USER = 'foo@example.com'

class MockBackend
  include Test::Unit::Assertions
  attr_accessor :response

  def initialize(email)
    @response = [200, {'Content-Type' => 'text/html'}, ['Hello World']]
    @expected_email = email
  end

  def call(env)
    # Make sure remote user is set by wwwhisper.
    assert_equal @expected_email, env['REMOTE_USER']
    @response
  end

  def add_response_header(key, value)
    # Frozen strings as header values must be handled correctly.
    @response[1][key] = value.freeze
  end

end

class TestWWWhisper < Test::Unit::TestCase
  include Rack::Test::Methods
  WWWHISPER_URL = 'https://wwwhisper.org'
  SITE_PROTO = 'https'
  SITE_HOST = 'bar.io'

  def setup()
    @backend = MockBackend.new(TEST_USER)
    ENV.delete('WWWHISPER_DISABLE')
    ENV.delete('SITE_URL')
    ENV['WWWHISPER_URL'] = WWWHISPER_URL
    @wwwhisper = Rack::WWWhisper.new(@backend)
  end

  def app
    @wwwhisper
  end

  def full_url(path)
    "#{WWWHISPER_URL}#{path}"
  end

  def get path, params={}, rack_env={}
    rack_env['HTTP_HOST'] ||= SITE_HOST
    rack_env['HTTP_X_FORWARDED_PROTO'] ||= SITE_PROTO
    super path, params, rack_env
  end

  def granted()
    {:status => 200, :body => '', :headers => {'User' => TEST_USER}}
  end

  def open_location_granted()()
    # Open locations allow not authenticated access, 'User' can be not set
    {:status => 200, :body => '', :headers => {}}
  end

  def test_wwwhisper_url_required
    ENV.delete('WWWHISPER_URL')
    # Exception should not be raised during initialization, but during
    # the first request.
    @wwwhisper = Rack::WWWhisper.new(MockBackend.new(nil))
    assert_raise(StandardError) {
      get '/foo/bar'
    }
  end

  def test_disable_wwwhisper
    ENV.delete('WWWHISPER_URL')
    ENV['WWWHISPER_DISABLE'] = "1"
    # Configure MockBackend to make sure REMOTE_USER is not set.
    @wwwhisper = Rack::WWWhisper.new(MockBackend.new(nil))

    path = '/foo/bar'
    get path
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert !last_response.original_headers.has_key?('User')
  end

  def test_auth_query_path
    assert_equal('/wwwhisper/auth/api/is-authorized/?path=/foo/bar',
                 @wwwhisper.auth_query('/foo/bar'))
  end

  def test_request_allowed
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())

    get path
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert_equal TEST_USER, last_response['User']
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_open_location_request_allowed
    # Configure MockBackend to make sure REMOTE_USER is not set.
    @wwwhisper = Rack::WWWhisper.new(MockBackend.new(nil))
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(open_location_granted())

    get path
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert !last_response.original_headers.has_key?('User')
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_login_required
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(:status => 401, :body => 'Login required', :headers => {})

    get path
    assert !last_response.ok?
    assert_equal 401, last_response.status
    assert_equal 'Login required', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_request_denied
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(:status => 403, :body => 'Not authorized', :headers => {})

    get path
    assert !last_response.ok?
    assert_equal 403, last_response.status
    assert_equal 'Not authorized', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_iframe_injected_to_html_response
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())
    # wwwhisper iframe is injected only when response is a html document
    # with <body></body>
    body = '<html><body>Hello World</body></html>'
    @backend.response= [200, {'Content-Type' => 'text/html'}, [body]]

    get path
    assert last_response.ok?
    assert_match(/.*<script.*src="\/wwwhisper.*/, last_response.body)
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_iframe_not_injected_to_non_html_response
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())
    body = '<html><body>Hello World</body></html>'
    @backend.response= [200, {'Content-Type' => 'text/plain'}, [body]]

    get path
    assert last_response.ok?
    assert_equal(body, last_response.body)
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_response_body_combined
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())
    @backend.response= [200, {'Content-Type' => 'text/html'},
                        ['abc', 'def', 'ghi']]
    get path
    assert last_response.ok?
    assert_equal('abcdefghi', last_response.body)
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_auth_query_not_sent_for_login_request
    path = '/wwwhisper/auth/api/login'
    stub_request(:get, full_url(path)).
      to_return(:status => 200, :body => 'Login', :headers => {})

    get path
    assert last_response.ok?
    assert_equal 'Login', last_response.body
  end

  def test_auth_cookies_passed_to_wwwhisper
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {
             'Cookie' => /wwwhisper-auth=xyz; wwwhisper-csrftoken=abc/
           }).
      to_return(granted())

    get(path, {},
        {'HTTP_COOKIE' => 'wwwhisper-auth=xyz; wwwhisper-csrftoken=abc'})
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_non_wwwhisper_cookies_not_passed_to_wwwhisper
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {
             'Cookie' => /wwwhisper-auth=xyz; wwwhisper-csrftoken=abc/
           }).
      to_return(granted())

    get(path, {},
        {'HTTP_COOKIE' => 'session=123; wwwhisper-auth=xyz;' +
          'settings=foobar; wwwhisper-csrftoken=abc'})
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_library_version_passed_to_wwwhisper
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {'User-Agent' => "Ruby-#{Rack::WWWHISPER_VERSION}"}).
      to_return(granted())

    get path
    assert last_response.ok?
  end

  def assert_path_normalized(normalized, requested, script_name=nil)
    stub_request(:get, full_url(@wwwhisper.auth_query(normalized))).
      to_return(granted())

    env = script_name ? { 'SCRIPT_NAME' => script_name } : {}
    get(requested, {}, env)
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(normalized))
    WebMock.reset!
  end

  def test_path_normalization
    assert_path_normalized '/', '/'
    assert_path_normalized '/foo/bar', '/foo/bar'
    assert_path_normalized '/foo/bar/', '/foo/bar/'

    assert_path_normalized '/foo/', '/auth/api/login/../../../foo/'
    assert_path_normalized '/', '//'
    assert_path_normalized '/', ''
    assert_path_normalized '/', '/../'
    assert_path_normalized '/', '/./././'
    assert_path_normalized '/bar', '/foo/./bar/../../bar'
    assert_path_normalized '/foo/', '/foo/bar/..'
    assert_path_normalized '/foo/', '/foo/'
    assert_path_normalized '/', '/./././/'
  end

  def test_path_normalization_with_script_name
    assert_path_normalized '/foo/', '/', '/foo'
    assert_path_normalized '/foo/bar/hello', '/bar/hello', '/foo'

    assert_path_normalized '/baz/bar/hello', '/bar/hello', '/foo/../baz'

    assert_path_normalized '/foo/baz/bar/hello', 'bar/hello', '/foo/./baz'
    assert_path_normalized '/foo/', '/', '/foo/'
    assert_path_normalized '/bar/hello', '/bar/hello', '/foo/..'
  end

  def test_admin_request
    path = '/wwwhisper/admin/api/users/xyz'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())
    stub_request(:delete, full_url(path)).
      # Test that a header with multiple '-' is correctly passed
      with(:headers => {'X-Requested-With' => 'XMLHttpRequest'}).
      to_return(:status => 200, :body => 'admin page', :headers => {})

    delete(path, {}, {'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'})
    assert last_response.ok?
    assert_equal 'admin page', last_response.body
  end

  def test_invalid_auth_request
    path = '/foo'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(:status => 400, :body => 'invalid request', :headers => {})

    get path
    assert !last_response.ok?
    assert_equal 400, last_response.status
    assert_equal 'invalid request', last_response.body
  end

  def test_site_url
    path = '/wwwhisper/admin/index.html'

    # X-Forwarded headers must be sent to wwwhisper backend.
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {
             'Site-Url' =>  "#{SITE_PROTO}://#{SITE_HOST}"
           }).
      to_return(granted())
    stub_request(:get, full_url(path)).
      with(:headers => {'Site-Url' =>  "#{SITE_PROTO}://#{SITE_HOST}"}).
      to_return(:status => 200, :body => 'Admin page', :headers => {})

    get path
    assert last_response.ok?
    assert_equal 200, last_response.status
    assert_equal 'Admin page', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
    assert_requested :get, full_url(path)
  end

  def test_host_with_port
    path = '/foo'
    host = 'localhost:5000'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      # Test makes sure that port is not repeated in Site-Url.
      with(:headers => {'Site-Url' => "#{SITE_PROTO}://#{host}"}).
      to_return(:status => 401, :body => 'Login required', :headers => {})

    get(path, {}, {'HTTP_HOST' => host})
    assert_equal 401, last_response.status
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_chunked_encoding_from_wwwhisper_removed
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(:status => 401, :body => 'Login required',
                :headers => {'Transfer-Encoding' => 'chunked'})
    get path
    assert_equal 401, last_response.status
    assert_nil last_response['Transfer-Encoding']
    assert_not_nil last_response['Content-Length']
  end

  def test_public_caching_disabled
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())

    @backend.add_response_header('Cache-Control', 'public, max-age=60')
    get path
    assert last_response.ok?
    assert_equal 'private, max-age=60', last_response['Cache-Control']

    @backend.add_response_header('Cache-Control', 'max-age=60')
    get path
    assert last_response.ok?
    assert_equal 'private, max-age=60', last_response['Cache-Control']

    @backend.add_response_header('Cache-Control', 'private, max-age=60')
    get path
    assert last_response.ok?
    assert_equal 'private, max-age=60', last_response['Cache-Control']

  end

end
