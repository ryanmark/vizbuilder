$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'vizbuilder'
require 'minitest/autorun'
require 'fileutils'

class BuilderTest < Minitest::Test
  FIXTURES_PATH = File.expand_path('../test/fixtures', __dir__).freeze

  def before_setup
    @tmpdirs = {}
  end

  def after_teardown
    @tmpdirs.values.each do |dir|
      FileUtils.rm_rf(dir) if File.exist?(dir)
    end
    @tmpdirs = {}
  end

  # Get a temp dir that will get cleaned-up after this test
  # @param name [Symbol] name name of the tmpdir to get
  # @return [Pathname] absolute path
  def tmpdir(name = :test)
    @tmpdirs[name.to_sym] ||= Pathname.new(
      File.expand_path("#{Dir.tmpdir}/#{Time.now.to_i}#{rand(1000)}/")
    )
  end

  # autoshell fixture retriever
  #
  # @param name [Symbol] name of the fixture to retrieve
  # @return [Autoshell::Base]
  def fixture(name)
    fixture_path = File.join(FIXTURES_PATH, name.to_s)
    raise "Fixture #{name} does not exist at #{fixture_path}" unless Dir.exist? fixture_path

    dir = tmpdir(name)

    # copy fixture to the temp dir
    FileUtils.mkdir_p(dir)
    FileUtils.cp_r("#{fixture_path}/.", dir)

    FileUtils.cd(dir) { |path| yield path } if block_given?

    dir
  end

  def assert_exists(filename, msg = nil)
    assert File.exist?(filename), msg
  end

  def assert_content(expected, filename, msg = nil)
    assert_equal expected, File.read(filename), msg
  end
end
