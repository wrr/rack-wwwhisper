require 'addressable/uri'
require 'net/http/persistent'
require 'rack/utils'

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
    if not ENV['WWWHISPER_URL']
      raise StandardError, 'WWWHISPER_URL environment variable not set'
    end

    wwwhisper_http = http_init('wwwhisper')
    wwwhisper_uri = parse_uri(ENV['WWWHISPER_URL'])

    @wwwhisper_iframe = ENV['WWWHISPER_IFRAME'] ||
      sprintf(@@DEFAULT_IFRAME, wwwhisper_path('auth/overlay.html'))

    @request_config = {
      :auth => {
        :forwarded_headers => ['Cookie'],
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
      @aliases[wwwhisper_path k] = wwwhisper_path v
    end
  end

  def wwwhisper_path(suffix)
    "#{@@WWWHISPER_PREFIX}#{suffix}"
  end

  def auth_query(queried_path)
    wwwhisper_path "auth/api/is-authorized/?path=#{queried_path}"
  end

  def auth_login_path()
    wwwhisper_path 'auth/login.html'
  end

  def auth_denied_path()
    wwwhisper_path 'auth/not_authorized.html'
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

  def default_port(proto)
    {
      'http' => 80,
      'https' => 443,
    }[proto]
  end

  def proto_host_port(env)
    proto = env['HTTP_X_FORWARDED_PROTO'] || 'http'
    return proto,
    env['HTTP_HOST'],
    env['HTTP_X_FORWARDED_PORT'] || default_port(proto)
  end

  def site_url(env)
    proto, host, port = proto_host_port(env)
    port_str = if port != default_port(proto)
                 ":#{port}"
               else
                 ''
               end
    "#{proto}://#{host}#{port_str}"
  end

  def request_init(config, env, method, path)
    path = @aliases[path] || path
    request = Net::HTTP.const_get(method).new(path)
    copy_headers(config[:forwarded_headers], env, request)
    request['Site-Url'] = site_url(env) if config[:send_site_url]
    uri = config[:uri]
    request.basic_auth(uri.user, uri.password) if uri.user and uri.password
    request
  end

  def has_value(dict, key)
    dict[key] != nil and !dict[key].empty?
  end

  def copy_headers(headers_names, env, request)
    headers_names.each do |header|
      key = "HTTP_#{header.upcase}".gsub(/-/, '_')
      request[header] = env[key] if has_value(env, key)
      #puts "Sending header #{header} #{request[header]} #{key} #{env[key]}"
    end
  end

  def copy_body(src_request, dst_request)
    if dst_request.request_body_permitted? and src_request.body
      dst_request.body_stream = src_request.body
      dst_request.content_length = src_request.content_length
      dst_request.content_type =
        src_request.content_type if src_request.content_type
    end
  end

  def extract_headers(env, response)
    headers = Rack::Utils::HeaderHash.new()
    response.each_capitalized do |k,v|
      #puts "Header #{k} VAL #{v}"
      if k.to_s =~ /location/i
        location = Addressable::URI.parse(v)
        location.scheme, location.host, location.port = proto_host_port(env)
        v = location.to_s
      end
      # Transfer encoding and content-length are set correctly by Rack.
      # TODO: what is transfer encoding?
      headers[k] = v unless k.to_s =~ /transfer-encoding|content-length/i
    end
    return headers
  end

  def dispatch(env)
    orig_request = Rack::Request.new(env)
    if orig_request.path =~ %r{^#{@@WWWHISPER_PREFIX}}
      debug orig_request, "passing request to wwwhisper service"

      config =
        if orig_request.path =~ %r{^#{@@WWWHISPER_PREFIX}(auth|admin)/api/}
          @request_config[:api]
        else
          @request_config[:assets]
        end

      method = orig_request.request_method.capitalize
      request = request_init(config, env, method, orig_request.fullpath)
      copy_body(orig_request, request)

      response = config[:http].request(config[:uri], request)
      net_http_response_to_rack(env, response)
    else
      debug orig_request, "passing request to Rack stack"
      @app.call(env)
    end
  end

  def net_http_response_to_rack(env, response)
    [
     response.code.to_i,
     extract_headers(env, response),
     [(response.read_body() or '')]
    ]
  end

  def wwwhisper_auth_request(env, req)
    config = @request_config[:auth]
    auth_request = request_init(config, env, 'Get', auth_query(req.path))
    auth_response = config[:http].request(config[:uri], auth_request)
    net_http_response_to_rack(env, auth_response)
  end

  def should_inject_iframe(status, headers)
    status == 200 and headers['Content-Type'] =~ /text\/html/i
  end

  def inject_iframe(headers, body)
    # If Content-Length is missing, Rack sets correct one.
    headers.delete('Content-Length')
    #todo: iterate?
    body[0] = body[0].sub(/<\/body>/, "#{@wwwhisper_iframe}</body>")
  end

  def call(env)
    req = Rack::Request.new(env)

    req.path_info = Addressable::URI.normalize_path(req.path)
    if req.path =~ %r{^#{@@WWWHISPER_PREFIX}auth}
      # Requests to /@@WWWHISPER_PREFIX/auth/ should not be authorized,
      # every visitor can access login pages.
      return dispatch(env)
    end
    debug req, "sending auth request for #{req.path}"
    auth_status, auth_headers, auth_body = wwwhisper_auth_request(env, req)

    case auth_status
    when 200
      debug req, "access granted"
      status, headers, body = dispatch(env)
      inject_iframe(headers, body) if should_inject_iframe(status, headers)
      [status, headers, body]
    when 401, 403
      login_needed = (auth_status == 401)
      debug req,  login_needed ? "user not authenticated" : "access_denied"
      req.path_info = login_needed ? auth_login_path() : auth_denied_path()
      status, headers, body = dispatch(env)
      auth_headers['Content-Type'] = headers['Content-Type']
      # TODO: only here?
      auth_headers['Content-Encoding'] = headers['Content-Encoding']
      [auth_status, auth_headers, body]
    else
      debug req, "auth request failed"
      [auth_status, auth_headers, auth_body]
    end
  end

  # TODO: more private
  private

  def debug(req, message)
    req.logger.debug "wwwhisper #{message}" if req.logger
  end

end
