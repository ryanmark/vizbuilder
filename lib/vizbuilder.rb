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

class VizBuilder
  attr_reader :config
  delegate :sitemap, :data, :hooks, :helper_modules, to: :config

  BUILD_DIR = 'build'
  PREBUILT_DIR = 'prebuild'
  DATA_DIR = 'data'

  if foo

  def initialize(config = {}, &blk)
    # Config is an object used as the context for the given block
    @config = Config.new(config: config)
    # Load data into @data
    reload_data!
    # Execute the given block as a method of this class. The block can then use
    # the methods `add_page`, `add_data`, and `set`
    @config.instance_exec(&blk) if block_given?
    # Run any after load data hooks since they got added after the first load
    # data was called.
    run_hook!(:after_load_data)
    # Add helpers to the TemplateContext class
    TemplateContext.include(*helper_modules) unless helper_modules.empty?
    self
  end

  # Generate all pages in the sitemap and save to `build/`
  def build()
    ctx = TemplateContext.new(:production, :build, @config)
    index_prebuilt!
    # First we build prebuilt pages that need digests calculated by build_page
    digested = sitemap.select { |_path, page| page[:digest] == true }
    digested.each { |path, page| build_page(path, ctx) }
    # Then we build all other pages
    undigested = sitemap.select { |_path, page| page[:digest] != true }
    undigested.each { |path, page| build_page(path, ctx) }
  end

  # Run this builder as a server
  def runserver()
    status = 0 # running: 0, reload: 1, exit: 2
    # spawn a thread to watch the status flag and trigger a reload or exit
    monitor = Thread.new do
      sleep 0.1 while status.zero?
      Rack::Handler::WEBrick.shutdown
      sleep 0.1
      Kernel.exec(`ps #{$$} -o command`.split("\n").last) if status == 1
    end

    # trap ctrl-c and set status flag
    trap("SIGINT") do
      if status == 1
        status = 2 # ctrl-c hit twice or more, set status to exit
      elsif status.zero?
        # ctrl-c hit once, notify user and set status to reload
        puts "\nReloading the server, hit ctrl-c twice to exit\n"
        status = 1
      end
    end

    puts "\nStarting Dev server, hit ctrl-c once to reload, twice to exit\n"
    Rack::Handler::WEBrick.run(self, BindAddress: '127.0.0.1')
    monitor.join # let the monitor thread finish its work
  end

  # Support the call method so an instance can act as a Rack app
  def call(env)
    # Only support GET, OPTIONS, HEAD
    unless env['REQUEST_METHOD'].in?(%w(GET HEAD OPTIONS))
      return [405, {'Content-Type' => 'text/plain'}, ['METHOD NOT ALLOWED']]
    end

    # default response is 404 not found
    status = 404
    content_type = 'text/plain'
    content = "404 File not found"

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
      ctx = TemplateContext.new(:development, :server, @config)
      content = build_page(path, ctx)
      status = 200
    elsif File.exist?(build_filename)
      content_type = MimeMagic.by_path(path).to_s
      content = File.read(build_filename)
      status = 200
    end

    # Status code, headers and content for this response
    [status, {'Content-Type' => content_type}, [content]]
  #rescue StandardError => ex
    #[500, {'Content-Type' => 'text/html'}, ["<h1>#{ex}</h1><pre>#{ex.backtrace.join("\n")}</pre>"]]
  end

  # Force a reload of data files in `data/`
  def reload_data!
    data.merge!(load_data)
    # TODO: after load hooks only run once, not every time reload_data! is called
    run_hook!(:after_load_data)
  end

  # Like File.extname, but gets all extensions if multiple are present
  def self.fullextname(path)
    fname = File.basename(path)
    parts = fname.split('.')
    ".#{parts[1..-1].join('.')}"
  end

  # Convenience methods for configuring the site
  class Config
    attr_accessor :data, :config, :sitemap, :hooks, :helper_modules
    delegate :[], :[]=, :key?, to: :config

    def initialize(config: {})
      # Config is a Hash of site wide configuration variables
      @config = config.with_indifferent_access
      # Sitemap is a hash representing the documents in the site that will be
      # processed by Builder
      @sitemap = {}.with_indifferent_access
      # Data contains content and data that needs displaying
      @data = {}.with_indifferent_access
      # Hooks is a hash of hook names and arrays of blocks registered to be
      # executed when those hooks are reached
      @hooks = {}.with_indifferent_access
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
    def helpers(*mods, &blk)
      new_helpers = []
      # loop over the list of arguments, making sure they're all modules, and
      # then add them to the list of new helpers
      mods.each do |mod|
        raise ArgumentError.new("Helpers must be defined in a module or block") unless mods.is_a?(Module)
        new_helpers << mod
      end
      # if block is given, turn it into a module and add it to the helpers list
      new_helpers << Module.new(&blk) if blk

      if new_helpers.present?
        # extend the current Config instance with the helpers, making them available
        # to the rest of the configuration block
        self.extend(*new_helpers)
        # add our new helpers to our array of all helpers
        @helper_modules += new_helpers
      end

      self
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

    def initialize(target, mode, config)
      # Target is development or production
      @target = target.to_sym
      # Mode is build or server
      @mode = mode.to_sym
      # Config is our Builder config object
      @config_obj = config
      # Page is a hash representing the page. Is the same as whats in sitemap
      # for a given page path
      @page = {}
      # Locals is a hash thats used to resolve missing methods, making them
      # seem like local variables
      @locals = {}
      self
    end

    # Render any given template and return as a string. Can be used to render
    # partials.
    def render(template_path, locals={})
      old_locals = @locals
      @locals = locals.with_indifferent_access
      erb = ERB.new(File.read(template_path), nil, true)
      erb.filename = File.expand_path(template_path)
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

    # HELPERS

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
      if production? && page[:digest] == true
        raise "Missing digest for #{path}" if page[:digest_path].blank?
        path = page[:digest_path]
      end
      asset_http_prefix + path
    end

    # Generate and return the URL to any page
    def canonical_url(*args)
      http_prefix + args.join('/')
    end

    # Are we running as a server?
    def server?
      @mode == :server
    end

    # Are we building this app out?
    def build?
      @mode == :build
    end

    # Is this in production?
    def production?
      @target == :production
    end

    # Is this in development?
    def development?
      @target == :development
    end

    # Looks for an invoked method name in locals then in config, so locals
    # and config vars can be used as if they're local vars in the template
    def method_missing(sym)
      return @locals[sym] if @locals.key?(sym)
      return config[sym] if config.key?(sym)
      super
    end
  end

  private

  # Generate one page from the sitemap and save to `build/`
  def build_page(path, ctx)
    ctx.page = sitemap[path]
    out_fname = File.join(BUILD_DIR, path)

    # Check page data for info on how to build this path
    if ctx.page['template'].present?
      content = ctx.render(ctx.page['template'])
    elsif ctx.page['json'].present?
      content = ctx.page['json'].to_json
    elsif ctx.page['yaml'].present?
      content = ctx.page['yaml'].to_yaml
    elsif ctx.page['file'].present?
      content = File.read(ctx.page['file'])
    else
      raise ArgumentError("Page '#{path}' missing one of required attributes: 'template', 'json', 'yaml', 'file'.")
    end

    # If page data includes a digest flag, add sha1 digest to output filename
    if ctx.page['digest'] == true
      ext = Builder.fullextname(path)
      fname = File.basename(path, ext)
      dir = File.dirname(path)
      digest = Digest::SHA1.hexdigest(content)
      digest_fname = "#{fname}-#{digest}#{ext}"
      ctx.page['digest_path'] = "#{dir}/#{digest_fname}"
      out_fname = File.join(BUILD_DIR, dir, digest_fname)
    end

    puts "Writing #{out_fname}..."
    FileUtils.mkdir_p(File.dirname(out_fname))
    File.write(out_fname, content)
    content
  end

  # Read json and yaml files from `data/` and load them into a Hash using the
  # basename of the file names.
  def load_data()
    data = {}.with_indifferent_access

    Dir.glob("#{DATA_DIR}/*.json") do |fname|
      key = File.basename(fname, '.json').to_sym
      puts "Loading data[:#{key}] from #{fname}..."
      data[key] = JSON.parse(File.read(fname))
    end

    Dir.glob("#{DATA_DIR}/*.yaml") do |fname|
      key = File.basename(fname, '.yaml').to_sym
      puts "Loading data[:#{key}] from #{fname}..."
      data[key] = Psych.parse(fname)
    end

    data
  end

  # Execute all blocks in config registered with the given hook name.
  def run_hook!(name)
    return unless hooks[name.to_sym]
    hooks[name.to_sym].each { |blk| config.instance_exec(&blk) }
  end

  def run_after_load_data_hooks!
    run_hook!(:after_load_data)
  end

  # Find prebuilt assets and add them to the sitemap
  def index_prebuilt!
    Dir.glob("#{PREBUILT_DIR}/**/[^_]*.*") do |filename|
      sitemap[filename.sub("#{PREBUILT_DIR}/", '')] = { file: filename, digest: true }
    end
  end
end
