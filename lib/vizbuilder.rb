# frozen_string_literal: true

require 'psych'
require 'fileutils'
require 'erb'
require 'json'
require 'rack'
require 'mimemagic'
require 'active_support/all'
require 'ruby_dig'
require 'base64'
require 'digest'
require 'English'

# The VizBuilder class does all the stuff for a viz builder app
class VizBuilder
  attr_reader :config
  delegate :sitemap, :data, :hooks, :helper_modules, to: :config

  BUILD_DIR = 'build'
  PREBUILT_DIR = 'prebuild'
  DATA_DIR = 'data'

  def initialize(config = {}, &blk)
    # Config is an object used as the context for the given block
    @config = Config.new(config: config)
    @config_block = block_given? ? blk : nil
    @config.helpers(Helpers)
    @config.helpers(ConfigHelpers, type: :config)
    @config.helpers(TemplateHelpers, type: :template)
    @_configured = false
  end

  # Generate all pages in the sitemap and save to `build/`
  def build!(silent: false)
    configure!(mode: :build, target: :production)
    ctx = TemplateContext.new(@config)
    index_prebuilt!
    # First we build prebuilt pages that need digests calculated by build_page
    digested = sitemap.select { |_path, page| page[:digest] == true }
    digested.each { |path, _page| build_page(path, ctx, silent: silent) }
    # Then we build all other pages
    undigested = sitemap.reject { |_path, page| page[:digest] == true }
    undigested.each { |path, _page| build_page(path, ctx, silent: silent) }
  end

  # Run this builder as a server
  def runserver!(host: '127.0.0.1', port: '3456')
    configure!(mode: :server, target: :development)
    status = 0 # running: 0, reload: 1, exit: 2
    # spawn a thread to watch the status flag and trigger a reload or exit
    monitor = Thread.new do
      sleep 0.1 while status.zero?
      # Shutdown the server, wait for it to finish and then wait a tick
      Rack::Handler::WEBrick.shutdown
      sleep 0.1
      # Use ps to get the command that the user executed, and use Kernel.exec
      # to execute the command, replacing the current process.
      # Basically restart everything.
      Kernel.exec(`ps #{$PID} -o command`.split("\n").last) if status == 1
    end

    # trap ctrl-c and set status flag
    trap('SIGINT') do
      if status == 1
        status = 2 # ctrl-c hit twice or more, set status to exit
      elsif status.zero?
        # ctrl-c hit once, notify user and set status to reload
        puts "\nReloading the server, hit ctrl-c twice to exit\n"
        status = 1
      end
    end

    puts "\nStarting Dev server, hit ctrl-c once to reload, twice to exit\n"
    require 'webrick/accesslog'
    access_log = [[$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT]]
    Rack::Handler::WEBrick.run(self, Host: host, Port: port, AccessLog: access_log)
    monitor.join # let the monitor thread finish its work
  end

  # Support the call method so an instance can act as a Rack app
  def call(env)
    raise 'VizBuilder configuration incomplete!' unless @_configured

    # Only support GET, OPTIONS, HEAD
    unless env['REQUEST_METHOD'].in?(%w[GET HEAD OPTIONS])
      return [405, { 'Content-Type' => 'text/plain' }, ['METHOD NOT ALLOWED']]
    end

    # default response is 404 not found
    status = 404
    content_type = 'text/plain'
    content = '404 File not found'

    # Validate the requested path
    path = env['PATH_INFO']
    if path =~ %r{/$}
      # path is for a directory
      path += 'index.html'
    elsif path =~ %r{/[^./]+$}
      # path looks like a directory but is missing a trailing slash
      path += '/index.html'
    end

    # remove any leading slashes
    path = path[1..-1] if path =~ %r{^/}

    # filename for a potential prebuilt asset
    build_filename = File.join(PREBUILT_DIR, path)

    # Check our sitemap then our prebuilt folder for content to serve
    if sitemap[path].present?
      content_type = MimeMagic.by_path(path).to_s
      ctx = TemplateContext.new(@config)
      content = build_page(path, ctx)
      status = 200
    elsif File.exist?(build_filename)
      content_type = MimeMagic.by_path(path).to_s
      content = File.read(build_filename)
      status = 200
    end

    # Status code, headers and content for this response
    [status, { 'Content-Type' => content_type }, [content]]
  rescue StandardError => e
    full_exception = "#{e.class.name}: #{e.message}\n\n\t#{e.backtrace.join("\n\t")}"
    puts full_exception
    [500, { 'Content-Type' => 'text/plain' }, [full_exception]]
  end

  # Force a reload of data files in `data/`
  def reload_data!
    data.merge!(load_data)
    # TODO: after load hooks only run once, not every time reload_data! is called
    run_hook!(:after_load_data)
    # Chainable
    self
  end

  # Complete the configuration for this app. Is used by build! and runserver!.
  # You will only need this method if you're running VizBuilder as a rack app
  # without using runserver!.
  def configure!(kwargs = nil)
    return self if @_configured
    # Update config with any kwargs
    @config.merge!(kwargs) if kwargs.present?
    # Load data into @data
    reload_data!
    # Execute the given block as a method of this class. The block can then use
    # the methods `add_page`, `add_data`, and `set`
    @config.instance_exec(&@config_block) if @config_block.present?
    # Run any after load data hooks since they got added after the first load
    # data was called.
    run_hook!(:after_load_data)
    # Add helpers to the TemplateContext class
    TemplateContext.include(*helper_modules) unless helper_modules.empty?
    # Mark app configured
    @_configured = true
    # Chainable
    self
  end

  # Like File.extname, but gets all extensions if multiple are present
  def self.fullextname(path)
    fname = File.basename(path)
    parts = fname.split('.')
    ".#{parts[1..-1].join('.')}"
  end

  # Plaster over API changes in ERB
  def self.erb_new(template_path)
    # The parameters of ERB.new are changed in ruby 2.6
    erb_changed_ruby_version = Gem::Version.new('2.6.0')
    current_ruby_version = Gem::Version.new(RUBY_VERSION)
    erb = if current_ruby_version >= erb_changed_ruby_version
            ERB.new(File.read(template_path), trim_mode: '-')
          else
            ERB.new(File.read(template_path), nil, '-')
          end
    erb.filename = File.expand_path(template_path)
    erb
  end

  # Convenience methods for configuring the site
  class Config
    attr_accessor :data, :config, :sitemap, :hooks, :helper_modules
    delegate :[], :[]=, :key?, :update, :merge!, to: :config

    def initialize(config: {})
      # Config is a Hash of site wide configuration variables
      @config = config.with_indifferent_access
      # Data contains content and data that needs displaying
      @data = {}.with_indifferent_access
      # Hooks is a hash of hook names and arrays of blocks registered to be
      # executed when those hooks are reached
      @hooks = {}.with_indifferent_access
      # Sitemap is a hash representing the documents in the site that will be
      # processed by Builder. No indifferent access since the keys are all
      # file paths.
      @sitemap = {}
      # Helpers is an array of Modules that will get mixed into the template
      # context and with the current Config instance
      @helper_modules = []
    end

    # Add a page to the sitemap
    def add_page(path, kwargs)
      @sitemap[path] = kwargs.with_indifferent_access
      self
    end

    # Add or replace data
    def add_data(key, val)
      @data[key] = val.is_a?(Hash) ? val.with_indifferent_access : val
      self
    end

    # Set a global config option
    def set(key, val)
      @config[key] = val.is_a?(Hash) ? val.with_indifferent_access : val
      self
    end

    # Set a global config option if it isn't already set
    def set_default(key, val)
      set(key, val) unless @config.key?(key)
    end

    # Add code to run after data is loaded or reloaded. Is also run after object
    # is created.
    def after_load_data(&blk)
      hook(:after_load_data, &blk)
      self
    end

    # Add a block to a hook name
    def hook(name, &blk)
      @hooks[name.to_sym] ||= []
      @hooks[name.to_sym] << blk
      self
    end

    # Add helper modules or define helpers in a block
    def helpers(*mods, type: nil, &blk)
      new_helpers = []
      # loop over the list of arguments, making sure they're all modules, and
      # then add them to the list of new helpers
      mods.each do |mod|
        unless mod.is_a?(Module)
          raise ArgumentError, 'Helpers must be defined in a module or block'
        end

        new_helpers << mod
      end
      # if block is given, turn it into a module and add it to the helpers list
      new_helpers << Module.new(&blk) if blk

      if new_helpers.present?
        # extend the current Config instance with the helpers, making them available
        # to the rest of the configuration block
        extend(*new_helpers) if type.nil? || type.to_sym == :config
        # add our new helpers to our array of all helpers
        @helper_modules += new_helpers if type.nil? || type.to_sym == :template
      end

      self
    end

    def respond_to_missing?(sym, *)
      config.key?(sym) || super
    end

    # Treat config options as local
    def method_missing(sym)
      return config[sym] if config.key?(sym)

      super
    end
  end

  # Templates are rendered using this class. Templates are effectively treated
  # as methods of this class when rendered. So any methods or attributes exposed
  # in this class are available inside of templates.
  class TemplateContext
    attr_accessor :page
    delegate :data, :sitemap, :config, to: :@config_obj

    def initialize(config)
      # Config is our Builder config object
      @config_obj = config
      # Page is a hash representing the page. Is the same as whats in sitemap
      # for a given page path
      @page = {}
      # Locals is a hash thats used to resolve missing methods, making them
      # seem like local variables
      @locals = {}
    end

    # Render any given template and return as a string. Can be used to render
    # partials.
    def render(template_path, locals = {})
      old_locals = @locals
      @locals = locals.with_indifferent_access
      erb = VizBuilder.erb_new(template_path)
      ret = erb.result(binding)
      @locals = old_locals
      ret
    end

    # Load the content of a pre-rendered file and return it
    def include_file(filepath)
      content = File.read(filepath)
      mime = MimeMagic.by_path(filepath)
      if mime.text?
        return content
      elsif mime.image?
        return Base64.strict_encode64(content)
      else
        raise "File '${filepath}' of type '${mime}' can't be included as text"
      end
    end

    # Looks for an invoked method name in locals then in config, so locals
    # and config vars can be used as if they're local vars in the template
    def method_missing(sym)
      return @locals[sym] if @locals.key?(sym)
      return config[sym] if config.key?(sym)
      super
    end

    def respond_to_missing?(sym, *)
      @locals.key?(sym) || config.key?(sym) || super
    end
  end

  # HELPERS

  # The Helpers module holds methods that are added to both the config and
  # template contexts. So you can use these in the config block and in
  # templates.
  module Helpers
    # Are we running as a server?
    def server?
      config[:mode] == :server
    end

    # Are we building this app out?
    def build?
      config[:mode] == :build
    end

    # Is this in production?
    def production?
      config[:target] == :production
    end

    # Is this in development?
    def development?
      config[:target] == :development
    end
  end

  # The TemplateHelpers modules hold methods that are added to the template
  # context only. So you can only use these in templates.
  module TemplateHelpers
    # Get the full URL to the root of this site
    def http_prefix
      return '/' if server? && development?
      prefix = config[:http_prefix] || '/'
      prefix += '/' unless prefix =~ %r{/$}
      prefix
    end

    # Get the full URL to the root of where assets are stored
    def asset_http_prefix
      return '/' if server? && development?
      prefix = config[:asset_http_prefix] || http_prefix
      prefix += '/' unless prefix =~ %r{/$}
      prefix
    end

    # Generate and return the URL to any asset
    def asset_path(*args)
      path = args.join('/')
      page = sitemap[path]
      if production?
        raise "Missing asset #{path}" if page.blank?
        if page[:digest] == true
          raise "Missing digest for #{path}" if page[:digest_path].blank?
          path = page[:digest_path]
        end
      end
      asset_http_prefix + path
    end

    # Generate and return the URL to any page
    def canonical_url(*args)
      http_prefix + args.join('/')
    end
  end

  # The ConfigHelpers modules hold methods that are added to the config block
  # context only. So you can only use these with the config object instance.
  module ConfigHelpers; end

  private

  # Generate one page from the sitemap and save to `build/`
  def build_page(path, ctx, silent: false)
    ctx.page = sitemap[path]
    out_fname = File.join(BUILD_DIR, path)
    puts "Rendering #{out_fname}..." unless silent

    # Check page data for info on how to build this path
    if ctx.page['template'].present?
      # Check if we have a layout defined, use it
      layout = ctx.page.key?('layout') ? ctx.page['layout'] : config['layout']

      # Make sure to render the template inside the layout render so code in the
      # erb layout and template are executed in a sensible order.
      content =
        if layout.present?
          ctx.render(layout) { ctx.render(ctx.page['template']) }
        else
          ctx.render(ctx.page['template'])
        end
    elsif ctx.page['json'].present?
      content = ctx.page['json'].to_json
    elsif ctx.page['file'].present?
      content = File.read(ctx.page['file'])
    else
      raise(
        ArgumentError,
        "Page '#{path}' missing one of required attributes: 'template', 'json', 'file'."
      )
    end

    # If page data includes a digest flag, add sha1 digest to output filename
    if ctx.page['digest'] == true
      ext = VizBuilder.fullextname(path)
      fname = File.basename(path, ext)
      dir = File.dirname(path)
      digest = Digest::SHA1.hexdigest(content)
      digest_fname = "#{fname}-#{digest}#{ext}"
      ctx.page['digest_path'] = "#{dir}/#{digest_fname}"
      out_fname = File.join(BUILD_DIR, dir, digest_fname)
    end

    FileUtils.mkdir_p(File.dirname(out_fname))
    File.write(out_fname, content)
    content
  end

  # Read json and yaml files from `data/` and load them into a Hash using the
  # basename of the file names.
  def load_data
    data = {}.with_indifferent_access

    %w[.json .yaml].each do |ext|
      Dir.glob("#{DATA_DIR}/*#{ext}") do |fname|
        key = File.basename(fname, ext).to_sym
        puts "Loading data[:#{key}] from #{fname}..."
        data[key] =
          if ext == '.json'
            JSON.parse(File.read(fname))
          else
            Psych.parse(fname)
          end
      end
    end

    data
  end

  # Execute all blocks in config registered with the given hook name.
  def run_hook!(name)
    return unless hooks[name.to_sym]
    hooks[name.to_sym].each { |blk| config.instance_exec(&blk) }
  end

  # Find prebuilt assets and add them to the sitemap
  def index_prebuilt!
    Dir.glob("#{PREBUILT_DIR}/**/[^_]*.*") do |filename|
      config.add_page(filename.sub("#{PREBUILT_DIR}/", ''), file: filename, digest: true)
    end
  end
end
