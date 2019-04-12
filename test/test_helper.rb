$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'vizbuilder'
require 'minitest/autorun'
require 'fileutils'

class BuilderTest < Minitest::Test
  FIXTURES_PATH = File.expand_path('../../test/fixtures', __dir__).freeze

  def before_setup
    @dirs = {}
  end

  def after_teardown
    @dirs.values.each do |dir|
      FileUtils.rm_rf(dir) if File.exist?(dir)
    end
  end

  # Get a temp dir that will get cleaned-up after this test
  # @param name [Symbol] name name of the tmpdir to get
  # @return [Pathname] absolute path
  def dir(name = :test)
    @dirs[name.to_sym] ||= Pathname.new(
      File.expand_path("#{Dir.tmpdir}/#{Time.now.to_i}#{rand(1000)}/")
    )
  end

  # autoshell fixture retriever
  #
  # @param name [Symbol] name of the fixture to retrieve
  # @return [Autoshell::Base]
  def fixture(name)
    tmpdir = dir(name)

    # if there is a matching dir in fixtures, copy it to the temp dir
    fixture_path = File.join(FIXTURES_PATH, name.to_s)
    if Dir.exist? fixture_path
      FileUtils.mkdir_p(tmpdir)
      FileUtils.cp_r(fixture_path, tmpdir)
    end

    if block_given?
      FileUtils.cd(tmpdir) { |path| yield path }
    else
      tmpdir
    end
  end
end
