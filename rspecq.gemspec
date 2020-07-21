require_relative "lib/rspecq/version"

Gem::Specification.new do |s|
  s.name        = "rspecq"
  s.version     = RSpecQ::VERSION
  s.summary     = "Optimally distribute and run RSpec suites among parallel " \
                  "workers; for faster CI builds"
  s.authors     = "Agis Anastasopoulos"
  s.email       = "agis.anast@gmail.com"
  s.files       = Dir["lib/**/*", "CHANGELOG.md", "LICENSE", "Rakefile", "README.md"]
  s.executables << "rspecq"
  s.homepage    = "https://github.com/skroutz/rspecq"
  s.license     = "MIT"

  s.add_dependency "rspec-core"
  s.add_dependency "redis"

  s.add_development_dependency "rake"
  s.add_development_dependency "pry-byebug"
  s.add_development_dependency "minitest"
  s.add_development_dependency "rspec"
end
