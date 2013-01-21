# Rack middleware that uses wwwhisper service to authorize visitors.
# Copyright (C) 2013 Jan Wrobel <wrr@mixedbit.org>
#
# This program is freely distributable under the terms of the
# Simplified BSD License. See COPYING.

require 'addressable/uri'
require 'net/http/persistent'
require 'rack/utils'

module Rack

class WWWhisper
  @@DEFAULT_ASSETS_URL = 'https://c693db817dca7e162673-39ba3573e09a1fa9bea151a745461b70.ssl.cf1.rackcdn.com'
  @@WWWHISPER_PREFIX = '/wwwhisper/'
  #@@AUTH_COOKIES_PREFIX = 'wwwhisper'

  @@DEFAULT_IFRAME = \
%Q[<iframe id="wwwhisper-iframe" src="%s"
 width="340" height="29" frameborder="0" scrolling="no"
 style="position:fixed; overflow:hidden; border:0px; bottom:0px;
 right:0px; z-index:11235; background-color:transparent;"> </iframe>
]

  def initialize(app)
    @app = app

    if ENV['WWWHISPER_DISABLE'] == "1"
      def self.call(env)
        @app.call(env)
      end
      return
    end

    if not ENV['WWWHISPER_URL']
      raise StandardError, 'WWWHISPER_URL environment variable not set'
    end

    wwwhisper_http = http_init('wwwhisper')
    wwwhisper_uri = parse_uri(ENV['WWWHISPER_URL'])

    @wwwhisper_iframe = ENV['WWWHISPER_IFRAME'] ||
      sprintf(@@DEFAULT_IFRAME, wwwhisper_path('auth/overlay.html'))
    @wwwhisper_iframe_bytesize = Rack::Utils::bytesize(@wwwhisper_iframe)

    @request_config = {
      # TODO: probably now auth can be removed.
      :auth => {
        :forwarded_headers => ['Accept', 'Accept-Language', 'Cookie'],
        :http => wwwhisper_http,
        :uri => wwwhisper_uri,
        :send_site_url => true,
      },
      :api => {
        :forwarded_headers => ['Accept', 'Accept-Language', 'Cookie',
                               'X-CSRFToken', 'X-Requested-With'],
        :http => wwwhisper_http,
        :uri => wwwhisper_uri,
        :send_site_url => true,
      },
      :assets => {
        # Don't pass Accept-Encoding to get uncompressed response (so
        # iframe can be inserted to it).
        :forwarded_headers => ['Accept', 'Accept-Language'],
        :http => http_init('wwwhisper-assets'),
        :uri => parse_uri(ENV['WWWHISPER_ASSETS_URL'] || @@DEFAULT_ASSETS_URL),
        :send_site_url => false,
      },
    }

    @aliases = {}
    {
      'auth/login' => 'auth/login.html',
      'auth/logout' => 'auth/logout.html',
      'admin/' => 'admin/index.html',
    }.each do |k, v|
      @aliases[wwwhisper_path(k)] = wwwhisper_path(v)
    end
  end

  def wwwhisper_path(suffix)
    "#{@@WWWHISPER_PREFIX}#{suffix}"
  end

  def auth_query(queried_path)
    wwwhisper_path "auth/api/is-authorized/?path=#{queried_path}"
  end

  def call(env)
    req = Request.new(env)

    if req.path =~ %r{^#{@@WWWHISPER_PREFIX}auth}
      # Requests to /@@WWWHISPER_PREFIX/auth/ should not be authorized,
      # every visitor can access login pages.
      return dispatch(req)
    end

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

  class Request < Rack::Request
    def initialize(env)
      super(env)
      normalize_path
    end

    def scheme
      env['HTTP_X_FORWARDED_PROTO'] || 'http'
    end

    def host_with_port
      env['HTTP_HOST']
    end

    def host
      host_with_port.to_s.gsub(/:\d+\z/, '')
    end

    def port
      env['HTTP_X_FORWARDED_PORT'] || host_with_port.split(/:/)[1] ||
        default_port(scheme)
    end

    def site_url
      port_str = port != default_port(scheme) ? ":#{port}" : ""
      "#{scheme}://#{host}#{port_str}"
    end

    private
    def normalize_path()
      self.script_name =
        Addressable::URI.normalize_path(script_name).squeeze('/')
      self.path_info =
        Addressable::URI.normalize_path(path_info).squeeze('/')
      # Avoid /foo/ /bar being combined into /foo//bar
      if self.path_info[0] == ?/
        self.script_name.chomp!('/')
      end
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

  def sub_request_init(config, rack_req, method, path)
    path = @aliases[path] || path
    sub_req = Net::HTTP.const_get(method).new(path)
    copy_headers(config[:forwarded_headers], rack_req.env, sub_req)
    sub_req['Site-Url'] = rack_req.site_url if config[:send_site_url]
    uri = config[:uri]
    sub_req.basic_auth(uri.user, uri.password) if uri.user and uri.password
    sub_req
  end

  def has_value(dict, key)
    dict[key] != nil and !dict[key].empty?
  end

  def copy_headers(headers_names, env, sub_req)
    headers_names.each do |header|
      key = "HTTP_#{header.upcase}".gsub(/-/, '_')
      sub_req[header] = env[key] if has_value(env, key)
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
    config = @request_config[:auth]
    auth_req = sub_request_init(config, req, 'Get', auth_query(req.path))
    config[:http].request(config[:uri], auth_req)
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

      config =
        if orig_req.path =~ %r{^#{@@WWWHISPER_PREFIX}(auth|admin)/api/}
          @request_config[:api]
        else
          @request_config[:assets]
        end

      method = orig_req.request_method.capitalize
      sub_req = sub_request_init(config, orig_req, method, orig_req.fullpath)
      copy_body(orig_req, sub_req)

      sub_resp = config[:http].request(config[:uri], sub_req)
      sub_response_to_rack(orig_req, sub_resp)
    else
      debug orig_req, 'passing request to Rack stack'
      @app.call(orig_req.env)
    end
  end

end # class WWWhisper

end # module
