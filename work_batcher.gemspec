Gem::Specification.new do |s|
  s.name         = 'work_batcher'
  s.version      = '1.0.1'
  s.summary      = 'Library for batching work'
  s.description  = 'Library for batching work.'
  s.email        = 'info@phusion.nl'
  s.homepage     = 'https://github.com/phusion/work_batcher'
  s.authors      = ['Hongli Lai']
  s.license      = 'MIT'
  s.files        = [
    'work_batcher.gemspec',
    'README.md',
    'LICENSE.md',
    'Rakefile',
    'lib/work_batcher.rb'
  ]
  s.add_dependency 'concurrent-ruby'
end
