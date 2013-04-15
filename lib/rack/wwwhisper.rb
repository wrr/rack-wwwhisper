# Rack middleware that uses wwwhisper service to authorize visitors.
# Copyright (C) 2013 Jan Wrobel <wrr@mixedbit.org>
#
# This program is freely distributable under the terms of the
# Simplified BSD License. See COPYING.

require 'addressable/uri'
require 'net/http/persistent'
require 'rack/utils'
require 'rack/wwwhisper_version'

module Rack

# Communicates with the wwwhisper service to authorize each incoming
# request. Acts as a proxy for requests to locations handled by
# wwwhisper (/wwwhisper/auth and /wwwhisper/admin)
#
# For each incoming request an authorization query is sent.
# The query contains a normalized path that a request is
# trying to access and wwwhisper session cookies. The
# query result determines the action to be performed:
# [200] request is allowed and passed down the Rack stack.
# [401] the user is not authenticated, request is denied, login
#       page is returned.
# [403] the user is not authorized, request is denied, error is returned.
# [any other] error while communicating with wwwhisper, request is denied.
#
# This class is thread safe, it can handle multiple simultaneous requests.
class WWWhisper
  # Path prefix of requests that are passed to wwwhisper.
  @@WWWHISPER_PREFIX = '/wwwhisper/'
  # Name prefix of cookies that are passed to wwwhisper.
  @@AUTH_COOKIES_PREFIX = 'wwwhisper'

  # Headers that are passed to wwwhisper ('Cookie' is handled
  # in a special way: only wwwhisper related cookies are passed).
  #
  # In addition, the current site URL is passed in the Site-Url header.
  # This is needed to perform URL verification of Persona assertions and to
  # construct Location headers in redirects.
  #
  # wwwhisper library version is passed in the User-Agent header. This
  # is to warn the site owner if a vulnerability in the library is
  # discovered and the library needs to be updated.
  @@FORWARDED_HEADERS = ['Accept', 'Accept-Language', 'Cookie', 'Origin',
                         'X-CSRFToken', 'X-Requested-With']
  @@DEFAULT_IFRAME = %Q[<script type="text/javascript" src="%s"> </script>
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
  # 3. WWWHISPER_IFRAME: an HTML snippet to be injected into returned
  #    HTML documents (has a default value).
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

    # net/http/persistent connections are thread safe.
    @http = http_init('wwwhisper')
    @wwwhisper_uri = parse_uri(ENV['WWWHISPER_URL'])

    @wwwhisper_iframe = ENV['WWWHISPER_IFRAME'] ||
      sprintf(@@DEFAULT_IFRAME, wwwhisper_path('auth/iframe.js'))
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
    normalize_path(req)

    # Requests to /@@WWWHISPER_PREFIX/auth/ should not be authorized,
    # every visitor can access login pages.
    return dispatch(req) if req.path =~ %r{^#{wwwhisper_path('auth')}}

    debug req, "sending auth request for #{req.path}"
    auth_resp = auth_request(req)

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
  def debug(req, message)
    req.logger.debug "wwwhisper #{message}" if req.logger
  end

  def parse_uri(uri)
    parsed_uri = Addressable::URI.parse(uri)
    # If port is not specified, net/http/persistent uses port 80 for
    # https connections which is counter-intuitive.
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

  def normalize_path(req)
    req.script_name =
      Addressable::URI.normalize_path(req.script_name).squeeze('/')
    req.path_info =
      Addressable::URI.normalize_path(req.path_info).squeeze('/')
    # Avoid /foo/ and /bar being combined into /foo//bar
    req.script_name.chomp!('/') if req.path_info[0] == ?/
  end

  def sub_request_init(rack_req, method, path)
    sub_req = Net::HTTP.const_get(method).new(path)
    copy_headers(rack_req.env, sub_req)
    scheme = rack_req.env['HTTP_X_FORWARDED_PROTO'] ||=  rack_req.scheme
    sub_req['Site-Url'] = "#{scheme}://#{rack_req.env['HTTP_HOST']}"
    sub_req['User-Agent'] = "Ruby-#{Rack::WWWHISPER_VERSION}"
    if @wwwhisper_uri.user and @wwwhisper_uri.password
      sub_req.basic_auth(@wwwhisper_uri.user, @wwwhisper_uri.password)
    end
    sub_req
  end

  def copy_headers(env, sub_req)
    @@FORWARDED_HEADERS.each do |header|
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
      # If sub request returned chunked response, remove the header
      # (chunks will be combined and returned with 'Content-Length).
      rack_headers[header] = value if header !~ /Transfer-Encoding|Set-Cookie/
    end
    # Multiple Set-Cookie headers need to be set as a single value
    # separated by \n (see Rack SPEC).
    cookies = sub_resp.get_fields('Set-Cookie')
    rack_headers['Set-Cookie'] = cookies.join("\n") if cookies
    return rack_headers
  end

  def sub_response_to_rack(rack_req, sub_resp)
    code = sub_resp.code.to_i
    headers = sub_response_headers_to_rack(rack_req, sub_resp)
    body = sub_resp.read_body() || ''
    if code < 200 or [204, 205, 304].include?(code)
      # To make sure Rack SPEC is respected.
      headers.delete('Content-Length')
      headers.delete('Content-Type')
    elsif (body.length || 0) != 0 and not headers['Content-Length']
      headers['Content-Length'] = Rack::Utils::bytesize(body).to_s
    end
    [ code, headers, [body] ]
  end

  def auth_request(req)
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
  end # class NoPublicCache

end # class WWWhisper

end # module
