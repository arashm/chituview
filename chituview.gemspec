require_relative "lib/chituview/version"

Gem::Specification.new do |spec|
  spec.name        = "chituview"
  spec.version     = Chituview::VERSION
  spec.authors     = ["Arash Mousavi"]
  spec.email       = ["arash.mousavi@stewark.com"]
  spec.summary     = "Read-only live terminal dashboard for Chitu-firmware (SDCP) resin 3D printers."
  spec.description = "Discovers a Chitu/SDCP resin printer on the LAN and shows live print status " \
                     "(progress, layers, time, errors) in a terminal UI, with a keypress to open the camera."
  spec.homepage    = "https://github.com/arashmousavi/chituview"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files       = Dir["lib/**/*.rb", "bin/*", "README.md"]
  spec.bindir      = "bin"
  spec.executables = ["chituview"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bubbletea", "~> 0.1"
  spec.add_dependency "lipgloss", "~> 0.2"
  spec.add_dependency "bubbles", "~> 0.1"
  spec.add_dependency "websocket", ">= 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
