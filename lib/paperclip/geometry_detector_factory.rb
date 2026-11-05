module Paperclip
  class GeometryDetector
    def initialize(file)
      @file = file
      raise_if_blank_file
    end

    def make
      geometry = GeometryParser.new(geometry_string.strip).make
      geometry || raise(Errors::NotIdentifiedByVipsError.new("Could not identify image size"))
    end

    private

    def geometry_string
      image = ::Vips::Image.new_from_file(path, access: :sequential)
      orientation = if Paperclip.options[:use_exif_orientation] && image.get_typeof("orientation") != 0
                      image.get("orientation")
                    else
                      1
                    end
      "#{image.width}x#{image.height},#{orientation}"
    rescue ::Vips::Error
      ""
    end

    def path
      @file.respond_to?(:path) ? @file.path : @file
    end

    def raise_if_blank_file
      if path.blank?
        raise Errors::NotIdentifiedByVipsError, "Cannot find the geometry of a file with a blank name"
      end
    end
  end
end
