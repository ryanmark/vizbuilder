lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'vizbuilder'
  spec.version       = File.read('VERSION').strip
  spec.authors       = ['Ryan Mark']
  spec.email         = ['ryan@mrk.cc']

  spec.summary       = 'Simple and fast static site generator'
  spec.homepage      = 'https://github.com/ryanmark/vizbuilder-ruby'

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport', '~> 5.2'
  spec.add_dependency 'mimemagic', '~> 0.3'
  spec.add_dependency 'rack', '~> 2.0'
  spec.add_dependency 'ruby_dig', '~> 0.0.2'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'minitest', '~> 5.11'
  spec.add_development_dependency 'rake', '~> 12.3'
end
