require 'sketchup.rb'
require 'extensions.rb'

module Navro
  module Dokumentacja
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('navro. Dokumentacja', 'navro_dokumentacja/main')
      ex.description = 'Eksport scen SketchUpa do programu navro. Dokumentacja (arkusze, widoki w skali, wymiary).'
      ex.version     = '0.4.1'
      ex.creator     = 'navro.'
      ex.copyright   = 'navro.'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end
