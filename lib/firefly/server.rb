# encoding: UTF-8
require 'sinatra/base'
require 'haml'
require 'digest/md5'
require 'warden'
require_relative 'auth'

module Firefly
  class InvalidUrlError < StandardError
  end

  class InvalidCodeError < StandardError
  end

  class Server < Sinatra::Base
    enable :sessions

    if Firefly.environment == "development"
      enable :logging, :dump_errors, :raise_errors
    end

    # TODO: Replace this properly with Firefly.root
    dir = File.join(File.dirname(__FILE__), '..', '..')

    set :views,          "#{dir}/views"
    set :public_folder,  "#{dir}/public"
    set :haml,           format: :html5
    set :static,         true

    attr_accessor :config

    helpers do
      include Rack::Utils
      alias_method :h, :escape_html

      def url(*path_parts)
        [ path_prefix, path_parts ].join("/").squeeze('/')
      end
      alias_method :u, :url

      def path_prefix
        request.env['SCRIPT_NAME']
      end

      def set_api_cookie(key)
        session["firefly_session"] = Digest::MD5.hexdigest(key)
      end

      # Taken from Rails
      def truncate(text, length, options = {})
        options[:omission] ||= "..."

        length_with_room_for_omission = length - options[:omission].length
        chars = text
        stop = options[:separator] ?
          (chars.rindex(options[:separator], length_with_room_for_omission) || length_with_room_for_omission) : length_with_room_for_omission

        (chars.length > length ? chars[0...stop] + options[:omission] : text).to_s
      end

      def short_url(url)
        "http://#{config[:hostname]}/#{url.code}"
      end

      def generate_short_url(url, user, requested_code = nil)
        code, result = nil, nil

        begin
          ff_url  = Firefly::Url.shorten(url, user, requested_code)
          code, result = ff_url.code, "http://#{config[:hostname]}/#{ff_url.code}"
        rescue Firefly::InvalidUrlError
          code, result = nil, "ERROR: The URL you posted is invalid."
        rescue Firefly::InvalidCodeError
          code, result = nil, "ERROR: The code is invalid or already exists."
        rescue
          code, result = nil, "ERROR: An unknown error occured"
        end

        return code, result
      end

      def is_highlighted?(url)
        return false unless @highlight
        @highlight == url.code
      end

    end

    before do
      @config        = config
      @highlight     = nil
      @title         = "Url shortener (http://#{@config[:hostname]})"
    end

    get '/' do
      env['warden'].authenticate!
      @highlight = Firefly::Url.where(code: params[:highlight]).first
      @error     = params[:highlight] == "error"

      sort_column = params[:s] || 'created_at'
      sort_order  = params[:d] || 'desc'

      @urls = Firefly::Url.where(user: env['warden'].user.username).limit(config[:recent_urls]).order("#{sort_column} #{sort_order}")

      haml :index
    end

    post '/login' do
      begin
        env['warden'].authenticate!
      ensure
        redirect '/'
      end
    end

    # Use an explicit redirect to the login page so that the browser is pointed
    # back to /login.
    get '/redirect_login' do
      redirect '/login'
    end

    post '/redirect_login' do
      redirect '/login'
    end

    get '/login' do
      haml @config[:authentication]['login_form'].to_sym
    end

    # GET /add?url=http://ariejan.net&api_key=test
    # POST /add?url=http://ariejan.net&api_key=test
    #
    # Returns the shortened URL
    api_add = lambda {
      env['warden'].authenticate!
      user = env['warden'].user.username

      @url            = params[:url]
      @requested_code = params[:short]
      @code, @result  = generate_short_url(@url, user, @requested_code)
      invalid = @code.nil?

      if params[:visual]
        @code.nil? ? haml(:error) : redirect("/?highlight=#{@code}")
      else
        # head(422) if invalid
        status 422 if invalid
        @result
      end
    }

    # GET /delete?code=code&api_key=test
    get '/api/delete/:code' do
      env['warden'].authenticate!
      user = env['warden'].user.username

      @requested_code = params[:code]
      url = Firefly::Url.where(code: params[:code]).first
      valid = !url.nil?
      authorized = valid && url.user == user
      # head(422) if invalid
      status 403 if not authorized
      status 422 if not valid
      url.destroy if valid and authorized
    end

    get '/api/add', &api_add
    post '/api/add', &api_add

    # GET /b3d+
    #
    # Show info on the URL
    get '/api/info/:code' do
      env['warden'].authenticate!

      @url = Firefly::Url.where(code: params[:code]).first

      if @url.nil?
        status 404
        "Sorry, that code is unknown."
      else
        @short_url = "http://#{config[:hostname]}/#{@url.code}"
        haml :info
      end
    end

    if defined? Barby
      # GET /b3d.png
      #
      # Return a QR code image
      get '/:code.png' do
        @url = Firefly::Url.where(code: params[:code]).first

        if @url.nil?
          status 404
          "Sorry, that code is unknown."
        else
          qr = Barby::QrCode.new(short_url(@url))
          content_type('image/png')
          cache_control :public, max_age: 2592000 # One month
          body(qr.to_png(xdim: 15, margin: 30))
        end
      end
    end

    # GET /b3d
    #
    # Redirect to the shortened URL
    get '/:code' do
      @url = Firefly::Url.where(code: params[:code]).first

      if @url.nil?
        status 404
        "Sorry, that code is unknown."
      else
        @url.register_click!
        redirect @url.url, 301
      end
    end

    def self.config_object(configuration_file = nil)
      configuration_file ||= Config.DefaultConfigFile
      Firefly::Config.new(configuration_file)
    end

    def initialize(config = nil)
      super

      @config||= Server.config_object

      begin
        # TODO: Check for proper database collation with ActiveRecord
        # check_mysql_collation
        check_code_factory
      rescue
        puts "Error setting up database connection. Please check the `database` setting in config.ru"
        puts $!
        puts "-------"
        puts $!.backtrace
        exit(1)
      end
    end

    # Create the Server object, and register the right warden strategy within it.
    def self.create(configuration_file = nil)
      config = self.config_object configuration_file
      strategy = config[:authentication]['strategy'].to_sym
      if strategy == :api_key
        register_api_key_strategy(config[:authentication]['api_key'])
      elsif strategy == :ldap
        register_ldap_strategy(config[:authentication]['config_file'])
      end
      
      # Read https://github.com/sklise/sinatra-warden-example for more details
      self.use Warden::Manager do |config|
        config.scope_defaults :default,
                              strategies: [strategy],
                              # redirect to /login when not authenticated
                              action: 'redirect_login'
        config.failure_app = self
      end
      self.use Rack::Session::Cookie, :expire_after => 60*60*24*365, :secret => config[:session_secret]
      self.new(config)
    end

    def check_code_factory
      Firefly::CodeFactory.first || Firefly::CodeFactory.create(count: 0)
    end

    def check_mysql_collation(first_try = true)
      # Make sure the 'code' column is case-sensitive. This hack is for
      # MySQL only, other database systems don't have this problem.
      if DataMapper.repository(:default).adapter =~ "DataMapper::Adapters::MysqlAdapter"
        query     = "SHOW FULL COLUMNS FROM firefly_urls WHERE Field='code';"
        collation = DataMapper.repository(:default).adapter.select(query)[0][:collation]

        if collation != "utf8_bin"
          if first_try
            puts " ~ Your MySQL database is not using the 'utf8-bin' collation. Trying to fix..."
            DataMapper.repository(:default).adapter.execute("ALTER TABLE firefly_urls MODIFY `code` varchar(255) CHARACTER SET utf8 COLLATE utf8_bin;")
            return check_mysql_collation(false)
          else
            puts " ~ Failed to set the collation for `code` in `firefly_urls`. Please see http://wiki.github.com/ariejan/firefly/faq for details."
            return false
          end
        else
          if !first_try
            puts " ~ Successfully fixed your database."
          end
          return true
        end
      end
    end
  end
end

