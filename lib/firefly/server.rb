# encoding: UTF-8
require 'sinatra/base'
require 'haml'
require 'digest/md5'
require 'warden'
require 'warden/ldap'

module Firefly
  class InvalidUrlError < StandardError
  end

  class InvalidCodeError < StandardError
  end

  class Server < Sinatra::Base
    enable :sessions

    Warden::Ldap.configure do |c|
      c.config_file = 'ldap.yml'
      c.env = 'development'
    end

    use Warden::Manager do |config|

      config.scope_defaults :default,
                            # "strategies" is an array of named methods with which to
                            # attempt authentication. We have to define this later.
                            strategies: [:ldap],
                            # The action is a route to send the user to when
                            # warden.authenticate! returns a false answer. We'll show
                            # this route below.
                            action: 'login'
      # When a user tries to log in and cannot, this specifies the
      # app to send the user to.
      config.failure_app = self
    end



    if Firefly.environment == "development"
      enable :logging,:dump_errors, :raise_errors
    end

    # TODO: Replace this properly with Firefly.root
    dir = File.join(File.dirname(__FILE__), '..', '..')

    set :views,          "#{dir}/views"
    set :public_folder,  "#{dir}/public"
    set :haml,           format: :html5
    set :static,         true
    set :session_secret, nil

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

      def generate_short_url(url = nil, requested_code = nil)
        code, result = nil, nil

        begin
          ff_url  = Firefly::Url.shorten(url, requested_code)
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
      @title         = "Firefly at http://#{@config[:hostname]}"

      set :session_secret, @config[:session_secret]
    end

    get '/' do
      env['warden'].authenticate!
      @highlight = Firefly::Url.where(code: params[:highlight]).first
      @error     = params[:highlight] == "error"

      sort_column = params[:s] || 'created_at'
      sort_order  = params[:d] || 'desc'

      @urls = Firefly::Url.limit(config[:recent_urls]).order("#{sort_column} #{sort_order}").all

      haml :index
    end

    get '/login' do
      haml :login
    end

    post '/login' do
      env['warden'].authenticate
      redirect '/'
    end

    # GET /b3d+
    #
    # Show info on the URL
    get '/api/info/:code' do
      validate_api_permission or return "Permission denied: Invalid API key"

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

    def initialize(configuration_file = nil)
      super

      configuration_file ||= File.join(Firefly.root, 'config/firefly.yml')
      @config = Firefly::Config.new(configuration_file)

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

