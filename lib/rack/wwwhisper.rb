# Rack middleware that uses wwwhisper service to authorize visitors.
# Copyright (C) 2013 Jan Wrobel <wrr@mixedbit.org>
#
# This program is freely distributable under the terms of the
# Simplified BSD License. See COPYING.

require 'addressable/uri'
require 'net/http/persistent'
require 'rack/utils'

module Rack

# An internal middleware used by Rack::WWWhisper to change directives
# that enable public caching into directives that enable private
# caching.
#
# To be on a safe side, all wwwhisper protected content is treated as
# sensitive and not publicly cacheable.
class NoPublicCache
  def initialize(app)
    @app = app
  end

  # If a response enables caching, makes sure it is private.
  def call(env)
    status, headers, body = @app.call(env)
    if cache_control = headers['Cache-Control']
      cache_control = cache_control.gsub(/public/, 'private')
      if (not cache_control.include? 'private' and
          cache_control.index(/max-age\s*=\s*0*[1-9]/))
        # max-age > 0 without 'public' or 'private' directive is
        # treated as 'public', so 'private' needs to be prepended.
        cache_control.insert(0, 'private, ')
      end
      headers['Cache-Control'] = cache_control
    end
    [status, headers, body]
  end

end

# Communicates with the wwwhisper service to authorize each incomming
# request. Acts as a proxy for requests to locations handled by
# wwwhisper (/wwwhisper/auth and /wwwhisper/admin)
#
# For each incomming request an authorization query is sent.
# The query contains a normalized path that a request is
# trying to access and a wwwhisper session cookies. The
# query result determines the action to be performed:
# [200] request is allowed and passed down the Rack stack.
# [401] the user is not authenticated, request is denied, login
#       page is returned.
# [403] the user is not authorized, request is denied, error is returned.
# [any other] error while communicating with wwwhisper, request is denied.
#
# For Persona assertion verification the middleware depends on a
# 'Host' header being verified by a frontend server. This is true on
# Heroku, where the 'Host' header is rewritten if a request sets it to
# incorrect value.  If the frontend server does does not perform such
# verification, SITE_URL environment variable must be set to enforce a
# valid url (for example `export SITE_URL="\https://example.com"`).
class WWWhisper
  # Requests to locations starting with this prefix are passed to wwwhisper.
  @@WWWHISPER_PREFIX = '/wwwhisper/'
  # Cookies starting with this prefix are passed to wwwhisper.
  @@AUTH_COOKIES_PREFIX = 'wwwhisper'
  # Headers that are passed to wwwhisper ('Cookie' is handled
  # in a special way: only wwwhisper related cookies are passed).
  @@FORWARDED_HEADERS = ['Accept', 'Accept-Language', 'Cookie', 'X-CSRFToken',
                         'X-Requested-With']
  @@DEFAULT_IFRAME = \
%Q[<iframe id="wwwhisper-iframe" src="%s" width="340" height="29"
 style="position:fixed; overflow:hidden; border:0px; bottom:0px;
 right:0px; z-index:11235; background-color:transparent;"> </iframe>
]

  # Following environment variables are recognized:
  # 1. WWWHISPER_DISABLE: useful for a local development environment.
  #
  # 2. WWWHISPER_URL: an address of a wwwhisper service that must be
  #    set if WWWHISPER_DISABLE is not set. The url includes
  #    credentials that identify a protected site. If the same
  #    credentials are used for \www.example.org and \www.example.com,
  #    the sites are treated as one: access control rules defined for
  #    one site, apply to the other site.
  #
  # 3. WWWHISPER_IFRAME: an HTML snippet that should be injected to
  #    returned HTML documents (has a default value).
  #
  # 4. SITE_URL: must be set if the frontend server does not validate
  #    the Host header.
  def initialize(app)
    @app = app
    if ENV['WWWHISPER_DISABLE'] == "1"
      def self.call(env)
        @app.call(env)
      end
      return
    end

    @app = NoPublicCache.new(app)

    if not ENV['WWWHISPER_URL']
      raise StandardError, 'WWWHISPER_URL environment variable not set'
    end

    @http = http_init('wwwhisper')
    @wwwhisper_uri = parse_uri(ENV['WWWHISPER_URL'])

    @wwwhisper_iframe = ENV['WWWHISPER_IFRAME'] ||
      sprintf(@@DEFAULT_IFRAME, wwwhisper_path('auth/overlay.html'))
    @wwwhisper_iframe_bytesize = Rack::Utils::bytesize(@wwwhisper_iframe)
  end

  # Exposed for tests.
  def wwwhisper_path(suffix)
    "#{@@WWWHISPER_PREFIX}#{suffix}"
  end

  # Exposed for tests.
  def auth_query(queried_path)
    wwwhisper_path "auth/api/is-authorized/?path=#{queried_path}"
  end

  def call(env)
    req = Request.new(env)

    # Requests to /@@WWWHISPER_PREFIX/auth/ should not be authorized,
    # every visitor can access login pages.
    return dispatch(req) if req.path =~ %r{^#{wwwhisper_path('auth')}}

    debug req, "sending auth request for #{req.path}"
    auth_resp = wwwhisper_auth_request(req)

    if auth_resp.code == '200'
      debug req, 'access granted'
      env['REMOTE_USER'] = auth_resp['User']
      status, headers, body = dispatch(req)
      if should_inject_iframe(status, headers)
        body = inject_iframe(headers, body)
      end
      headers['User'] = auth_resp['User']
      [status, headers, body]
    else
      debug req, {
        '401' => 'user not authenticated',
        '403' => 'access_denied',
      }[auth_resp.code] || 'auth request failed'
      sub_response_to_rack(req, auth_resp)
    end
  end

  private
  # Extends Rack::Request with more conservative scheme, host and port
  # setting rules. Rack::Request tries to obtain these values from
  # mutiple sources, whereas for wwwhisper it is crucial that the
  # values are not spoofed by the client.
  #
  # If SITE_URL environemnt variable is set: scheme, host and port are
  # always taken directly from it.
  #
  # If SITE_URL is not set, scheme is taken from the X-Forwarded-Proto
  # header, host is taken from the 'Host' header and port is taken
  # from the X-Forwarded-Port header. The frontend must ensure these
  # values can not be spoofed by client (a request to example.com,
  # that carries a Host header 'example.org' should be dropped or
  # rewritten).
  class Request < Rack::Request
    attr_reader :scheme, :host, :port, :site_url

    def initialize(env)
      super(env)
      normalize_path
      if (@site_url = ENV['SITE_URL'])
        uri = Addressable::URI.parse(@site_url)
        @scheme = uri.scheme
        @host = uri.host
        @port = uri.port || default_port(@scheme)
      else
        @scheme = env['HTTP_X_FORWARDED_PROTO'] || 'http'
        @host, port_from_host = env['HTTP_HOST'].split(/:/)
        @port = env['HTTP_X_FORWARDED_PORT'] || port_from_host ||
          default_port(@scheme)
        port_str = @port != default_port(@scheme) ? ":#{@port}" : ""
        @site_url = "#{@scheme}://#{@host}#{port_str}"
      end
    end

    private
    def normalize_path
      self.script_name =
        Addressable::URI.normalize_path(script_name).squeeze('/')
      self.path_info =
        Addressable::URI.normalize_path(path_info).squeeze('/')
      # Avoid /foo/ /bar being combined into /foo//bar
      self.script_name.chomp!('/') if self.path_info[0] == ?/
    end

    def default_port(proto)
      {
        'http' => 80,
        'https' => 443,
      }[proto]
    end
  end

  def debug(req, message)
    req.logger.debug "wwwhisper #{message}" if req.logger
  end

  def parse_uri(uri)
    parsed_uri = Addressable::URI.parse(uri)
    # If port is not specified, net/http/persistent uses port 80 for
    # https connections which is counterintuitive.
    parsed_uri.port ||= parsed_uri.default_port
    parsed_uri
  end

  def http_init(connection_id)
    http = Net::HTTP::Persistent.new(connection_id)
    store = OpenSSL::X509::Store.new()
    store.set_default_paths
    http.cert_store = store
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    return http
  end

  def sub_request_init(rack_req, method, path)
    sub_req = Net::HTTP.const_get(method).new(path)
    copy_headers(@@FORWARDED_HEADERS, rack_req.env, sub_req)
    sub_req['Site-Url'] = rack_req.site_url
    if @wwwhisper_uri.user and @wwwhisper_uri.password
      sub_req.basic_auth(@wwwhisper_uri.user, @wwwhisper_uri.password)
    end
    sub_req
  end

  def copy_headers(headers_names, env, sub_req)
    headers_names.each do |header|
      key = "HTTP_#{header.upcase}".gsub(/-/, '_')
      value = env[key]
      if value and key == 'HTTP_COOKIE'
        # Pass only wwwhisper's cookies to the wwwhisper service.
        value = value.scan(/#{@@AUTH_COOKIES_PREFIX}-[^;]*(?:;|$)/).join(' ')
      end
      sub_req[header] = value if value and not value.empty?
    end
  end

  def copy_body(rack_req, sub_req)
    if sub_req.request_body_permitted? and rack_req.body and
        (rack_req.content_length or
         rack_req.env['HTTP_TRANSFER_ENCODING'] == 'chunked')
      sub_req.body_stream = rack_req.body
      sub_req.content_length =
        rack_req.content_length if rack_req.content_length
      sub_req.content_type = rack_req.content_type if rack_req.content_type
    end
  end

  def sub_response_headers_to_rack(rack_req, sub_resp)
    rack_headers = Rack::Utils::HeaderHash.new()
    sub_resp.each_capitalized do |header, value|
      if header == 'Location'
        location = Addressable::URI.parse(value)
        location.scheme, location.host, location.port =
          rack_req.scheme, rack_req.host, rack_req.port
        value = location.to_s
      end
      # If sub request returned chunked response, remove the header
      # (chunks will be combined and returned with 'Content-Length).
      rack_headers[header] = value if header != 'Transfer-Encoding'
    end
    return rack_headers
  end

  def sub_response_to_rack(rack_req, sub_resp)
    headers = sub_response_headers_to_rack(rack_req, sub_resp)
    body = sub_resp.read_body() || ''
    if body.length and not headers['Content-Length']
      headers['Content-Length'] = Rack::Utils::bytesize(body).to_s
    end
    [ sub_resp.code.to_i, headers, [body] ]
  end

  def wwwhisper_auth_request(req)
    auth_req = sub_request_init(req, 'Get', auth_query(req.path))
    @http.request(@wwwhisper_uri, auth_req)
  end

  def should_inject_iframe(status, headers)
    # Do not attempt to inject iframe if result is already chunked,
    # compressed or checksummed.
    (status == 200 and
     headers['Content-Type'] =~ /text\/html/i and
     not headers['Transfer-Encoding'] and
     not headers['Content-Range'] and
     not headers['Content-Encoding'] and
     not headers['Content-MD5']
     )
  end

  def inject_iframe(headers, body)
    total = []
    body.each { |part|
      total << part
    }
    body.close if body.respond_to?(:close)

    total = total.join()
    if idx = total.rindex('</body>')
      total.insert(idx, @wwwhisper_iframe)
      headers['Content-Length'] &&= (headers['Content-Length'].to_i +
                                     @wwwhisper_iframe_bytesize).to_s
    end
    [total]
  end

  def dispatch(orig_req)
    if orig_req.path =~ %r{^#{@@WWWHISPER_PREFIX}}
      debug orig_req, "passing request to wwwhisper service #{orig_req.path}"

      method = orig_req.request_method.capitalize
      sub_req = sub_request_init(orig_req, method, orig_req.fullpath)
      copy_body(orig_req, sub_req)

      sub_resp = @http.request(@wwwhisper_uri, sub_req)
      sub_response_to_rack(orig_req, sub_resp)
    else
      debug orig_req, 'passing request to Rack stack'
      @app.call(orig_req.env)
    end
  end

end # class WWWhisper

end # module
