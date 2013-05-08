# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)
 
require 'duck/version'
 
Gem::Specification.new do |s|
  s.name        = "duck-installer"
  s.version     = Duck::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["John-John Tedro", "Nathan Ferch", "Martin Parm"]
  s.email       = ["johnjohn.tedro@gmail.com"]
  s.homepage    = "http://github.com/udoprog/duck"
  s.summary     = "Tool for generating a minimalistic initramfs installer system"
  s.description = "Duck takes a configuration and generates a bootable initramfs that gives over to a minimalistic installation environment based on (em)debian."
 
  s.required_rubygems_version = ">= 1.3.6"
  s.rubyforge_project         = "duck"
 
  s.add_development_dependency "rspec"
 
  s.files        = Dir.glob("{lib,files,fixes}/**/*") + %w(LICENSE README duck.yaml)
  s.executables  << 'duck'
  s.require_path = 'lib'
end
