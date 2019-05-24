require 'test_helper'

class TestBuilder < BuilderTest
  def test_construct
    app = VizBuilder.new
    assert_instance_of VizBuilder, app
    assert app.config.present?
    assert_instance_of VizBuilder::Config, app.config
    refute_nil app.sitemap
    assert_instance_of Hash, app.sitemap
    refute_nil app.data
    assert_instance_of ActiveSupport::HashWithIndifferentAccess, app.data
  end

  def test_fullextname
    assert_equal '.gif', VizBuilder.fullextname('images/thing.gif')
    assert_equal '.jpg', VizBuilder.fullextname('photo.jpg')
    assert_equal '.html', VizBuilder.fullextname('/index.html')
    assert_equal '.html.erb', VizBuilder.fullextname('/page/index.html.erb')
    assert_equal '.html.html.erb', VizBuilder.fullextname('/page/index.html.html.erb')
    assert_equal '..html.erb', VizBuilder.fullextname('index..html.erb')
  end

  def test_config
    app = VizBuilder.new thing1: 'foo', thing2: 'bar'
    assert_equal 'foo', app.config[:thing1]
    assert_equal 'bar', app.config[:thing2]
    assert_equal 'foo', app.config.thing1
    assert_equal 'bar', app.config.thing2

    app = VizBuilder.new do
      set :thing1, 'foo'
      set :thing2, 'bar'
    end.configure!

    assert_equal 'foo', app.config[:thing1]
    assert_equal 'bar', app.config[:thing2]
    assert_equal 'foo', app.config.thing1
    assert_equal 'bar', app.config.thing2
  end

  def test_data
    app = VizBuilder.new do
      add_data :foo, thing1: 'foo', thing2: 'bar'
    end.configure!

    assert_equal 'foo', app.data[:foo][:thing1]
    assert_equal 'bar', app.data[:foo][:thing2]
    assert_equal 'foo', app.data.dig(:foo, :thing1)
    assert_equal 'bar', app.data.dig(:foo, :thing2)
  end

  def test_sitemap
    page_data = { thing1: 'foo', thing2: 'bar' }
    app = VizBuilder.new do
      add_page 'index.html', page_data
    end.configure!

    assert_equal page_data.with_indifferent_access, app.sitemap['index.html']
  end

  def test_after_load_data
    call_count = 0

    assert_equal 0, call_count

    app = VizBuilder.new do
      after_load_data do
        call_count += 1
      end
    end.configure!

    assert_equal 1, call_count
    app.reload_data!
    assert_equal 2, call_count
    app.reload_data!
    assert_equal 3, call_count
  end

  def test_project_layout
    fixture(:simple) do
      app = VizBuilder.new do
        set :layout, 'layout.html.erb'
        add_page 'index.html', template: 'test_layout.html.erb'
      end
      app.build! silent: true

      assert_exists 'build/index.html', 'Index file is built'
      assert_content "<html>\n<head></head>\n<body>\nHello!\n</body>\n</html>\n",
                     'build/index.html', 'Index file content is correct'
    end
  end

  def test_page_layout
    fixture(:simple) do
      app = VizBuilder.new do
        add_page 'index.html', template: 'test_layout.html.erb', layout: 'layout.html.erb'
      end
      app.build! silent: true

      assert_exists 'build/index.html', 'Index file is built'
      assert_content "<html>\n<head></head>\n<body>\nHello!\n</body>\n</html>\n",
                     'build/index.html', 'Index file content is correct'
    end
  end
end
