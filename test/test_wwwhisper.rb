# Rack middleware that uses wwwhisper service to authorize visitors.
# Copyright (C) 2013 Jan Wrobel <wrr@mixedbit.org>
#
# This program is freely distributable under the terms of the
# Simplified BSD License. See COPYING.

require 'rack/test'
require 'test/unit'
require 'webmock/test_unit'
require 'rack/wwwhisper'

ENV['RACK_ENV'] = 'test'

TEST_USER = 'foo@example.com'

class MockBackend
  include Test::Unit::Assertions
  attr_accessor :response

  def initialize()
    @response = [200, {'Content-Type' => 'text/html'}, ['Hello World']]
  end

  def call(env)
    # Make sure remote user is set by wwwhisper.
    assert_equal TEST_USER, env['REMOTE_USER']
    @response
  end
end

class TestWWWhisper < Test::Unit::TestCase
  include Rack::Test::Methods
  WWWHISPER_URL = 'https://example.com'
  WWWHISPER_ASSETS_URL = 'https://assets.example.com'
  SITE_PROTO = 'https'
  SITE_HOST = 'bar.io'
  SITE_PORT = 443

  def setup()
    @backend = MockBackend.new()
    ENV['WWWHISPER_URL'] = WWWHISPER_URL
    ENV['WWWHISPER_ASSETS_URL'] = WWWHISPER_ASSETS_URL
    @wwwhisper = Rack::WWWhisper.new(@backend)
  end

  def app
    @wwwhisper
  end

  def full_url(path)
    "#{WWWHISPER_URL}#{path}"
  end

  def full_assets_url(path)
    "#{WWWHISPER_ASSETS_URL}#{path}"
  end

  def test_wwwhisper_url_required
    ENV.delete('WWWHISPER_URL')
    assert_raise(StandardError) {
      Rack::WWWhisper.new(@backend)
    }
  end

  def get path, params={}, rack_env={}
    rack_env['HTTP_HOST'] ||= SITE_HOST
    rack_env['HTTP_X_FORWARDED_PROTO'] ||= SITE_PROTO
    rack_env['HTTP_X_FORWARDED_PORT'] ||= SITE_PORT
    super path, params, rack_env
  end

  def test_auth_query_path
    assert_equal('/wwwhisper/auth/api/is-authorized/?path=/foo/bar',
                 @wwwhisper.auth_query('/foo/bar'))
  end

  def granted()
    {:status => 200, :body => '', :headers => {'User' => TEST_USER}}
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
    assert_match(/.*<iframe id="wwwhisper-iframe".*/, last_response.body)
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

  def test_auth_cookies_passed_to_wwwhisper()
    path = '/foo/bar'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {'Cookie' => /wwwhisper_auth.+wwwhisper_csrf.+/}).
      to_return(granted())

    get(path, {},
        {'HTTP_COOKIE' => 'wwwhisper_auth=xyz; wwwhisper_csrf_token=abc'})
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
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

    # These two do not seem to be handled correctly and consistency,
    # but this is not a big issue, because wwwhisper rejects such
    # paths.
    assert_path_normalized '/foo//', '/foo//'
    assert_path_normalized '//', '/./././/'
  end

  def test_path_normalization_with_script_name
    assert_path_normalized '/foo/', '/', '/foo'
    assert_path_normalized '/foo/bar/hello', '/bar/hello', '/foo'

    assert_path_normalized '/baz/bar/hello', '/bar/hello', '/foo/../baz'

    assert_path_normalized '/foo/baz/bar/hello', 'bar/hello', '/foo/./baz'

    # Not handled too well (see comment above).
    assert_path_normalized '/foo//', '/', '/foo/'
    assert_path_normalized '//bar/hello', '/bar/hello', '/foo/..'
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

    # Site-Url header should be sent to wwwhisper backend but not to
    # assets server.
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {'Site-Url' => "#{SITE_PROTO}://#{SITE_HOST}"}).
      to_return(granted())
    stub_request(:get, full_assets_url(path)).
      with { |request| request.headers['Site-Url'] == nil}.
      to_return(:status => 200, :body => 'Admin page', :headers => {})

    get path
    assert last_response.ok?
    assert_equal 200, last_response.status
    assert_equal 'Admin page', last_response.body
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
    assert_requested :get, full_assets_url(path)
  end

  def test_site_url_with_non_default_port
    path = '/foo/bar'
    port = 11235
    # Site-Url header should be sent to wwwhisper backend but not to
    # assets server.
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      with(:headers => {'Site-Url' => "#{SITE_PROTO}://#{SITE_HOST}:#{port}"}).
      to_return(:status => 400, :body => '', :headers => {})

    get(path, {}, {'HTTP_X_FORWARDED_PORT' => port.to_s})
    assert !last_response.ok?
    assert_equal 400, last_response.status
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
  end

  def test_aliases
    requested_path = '/wwwhisper/auth/login'
    expected_path = requested_path + '.html'
    stub_request(:get, full_assets_url(expected_path)).
      to_return(:status => 200, :body => 'Login', :headers => {})

    get requested_path
    assert last_response.ok?
    assert_equal 'Login', last_response.body
  end

  def test_redirects
    path = '/wwwhisper/admin/index.html'
    stub_request(:get, full_url(@wwwhisper.auth_query(path))).
      to_return(granted())
    stub_request(:get, full_assets_url(path)).
      to_return(:status => 303, :body => 'Admin page moved',
                :headers => {'Location' => 'https://new.location/foo/bar'})

    get path
    assert !last_response.ok?
    assert_equal 303, last_response.status
    assert_equal 'Admin page moved', last_response.body
    assert_equal("#{SITE_PROTO}://#{SITE_HOST}:#{SITE_PORT}/foo/bar",
                 last_response['Location'])
    assert_requested :get, full_url(@wwwhisper.auth_query(path))
    assert_requested :get, full_assets_url(path)
  end

end
