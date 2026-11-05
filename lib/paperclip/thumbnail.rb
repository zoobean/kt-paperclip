module Paperclip
  # Native libvips thumbnails retain Paperclip geometry and tempfile contracts.
  # Style options are explicit: saver: { quality:, strip: }, flatten: [r, g, b],
  # and grayscale: :rec709_luminance. CLI option strings are intentionally rejected.
  class Thumbnail < Processor
    attr_accessor :current_geometry, :target_geometry, :format, :whiny,
                  :animated, :auto_orient, :frame_index

    def initialize(file, options = {}, attachment = nil)
      super
      @target_geometry = options.fetch(:string_geometry_parser, Geometry).parse(options[:geometry].to_s)
      @current_geometry = options.fetch(:file_geometry_parser, Geometry).from_file(file)
      @format = options[:format]
      @whiny = options.fetch(:whiny, true)
      @animated = options.fetch(:animated, true)
      @auto_orient = options.fetch(:auto_orient, true)
      @frame_index = options.fetch(:frame_index, 0)
      @current_geometry.auto_orient if auto_orient
    end

    def make
      raise Error, "Use style saver/flatten/grayscale options instead of convert_options" if options[:convert_options].present?
      raise Error, "Use native loader options instead of source_file_options" if options[:source_file_options].present?

      source = ::Vips::Image.new_from_file(file.path, access: :sequential)
      source_format = source.get("vips-loader").sub(/load.*/, "")
      extension = File.extname(file.path).delete_prefix(".").downcase
      output_format = format.to_s.presence || (extension == "svg" || native_saver?(extension) ? extension : source_format)
      preserve_animation = animated && source_format == "gif" && output_format == "gif" && source.get("n-pages") > 1
      loader = options.fetch(:loader, {}).merge(autorot: auto_orient)
      loader.merge!(n: preserve_animation ? -1 : 1, page: preserve_animation ? 0 : frame_index) if source.get_typeof("n-pages") != 0

      pipeline = if preserve_animation
                   ImageProcessing::Vips.source(resize_animation).loader(autorot: false)
                 else
                   resize_image(ImageProcessing::Vips.source(file).loader(**loader))
                 end
      pipeline = pipeline.flatten(background: options[:flatten]) if options[:flatten]
      pipeline = grayscale_image(pipeline) if options[:grayscale]
      pipeline = pipeline.saver(**options.fetch(:saver, {}))
      destination = TempfileFactory.new.generate("thumbnail.#{output_format}")
      if output_format == "svg"
        write_svg(pipeline, destination)
      else
        pipeline.call(destination: destination.path)
      end
      destination.rewind
      destination
    rescue ::Vips::Error, ImageProcessing::Error, Paperclip::Error => error
      destination.close! if destination
      raise Paperclip::Error, "Error processing #{File.basename(file.path)} with libvips: #{error.message}" if whiny

      file.rewind
      file
    end

    def crop?
      target_geometry && target_geometry.modifier == "#"
    end

    private

    def native_saver?(extension)
      saver = ::Vips.vips_foreign_find_save("thumbnail.#{extension}") if extension.present?
      saver && !saver.include?("Magick")
    end

    def resize_image(pipeline)
      return pipeline unless target_geometry

      width = target_geometry.width.positive? ? target_geometry.width.to_i : nil
      height = target_geometry.height.positive? ? target_geometry.height.to_i : nil
      case target_geometry.modifier
      when "#"
        pipeline.resize_to_fill(width, height)
      when ">"
        pipeline.resize_to_limit(width, height)
      when "<"
        pipeline.resize_to_fit(width, height, size: :up)
      when "!"
        pipeline.resize_to_fit(width, height, size: width && height ? :force : :both)
      when "^"
        pipeline.resize_to_cover(width, height)
      when "%"
        pipeline.resize_to_fit((current_geometry.width * width / 100.0).round,
                               (current_geometry.height * (height || width) / 100.0).round, size: :force)
      when "@", "@>", ">@"
        scale = Math.sqrt(width / (current_geometry.width * current_geometry.height))
        scale = [scale, 1].min if target_geometry.modifier.include?(">")
        pipeline.resize_to_fit((current_geometry.width * scale).round, (current_geometry.height * scale).round)
      else
        pipeline.resize_to_fit(width, height)
      end
    end

    def resize_animation
      # Coalesce in memory so a crop never crosses GIF frame boundaries. If
      # oversized animations become common, process and encode frames in a stream.
      source = ::Vips::Image.new_from_file(file.path, n: -1, access: :sequential).copy_memory
      page_height = source.get("page-height")
      frames = (source.height / page_height).times.map do |index|
        frame = source.crop(0, index * page_height, source.width, page_height)
        resize_image(ImageProcessing::Vips.source(frame).loader(autorot: auto_orient)).call(save: false)
      end
      image = ::Vips::Image.arrayjoin(frames, across: 1)
      image.set_type(GObject::GINT_TYPE, "page-height", frames.first.height)
      image
    end

    def grayscale_image(pipeline)
      raise Error, "Unsupported grayscale conversion: #{options[:grayscale]}" unless options[:grayscale] == :rec709_luminance

      # Rec709Luminance operates in linear light. B_W alone applies gamma and
      # makes existing grayscale badges visibly lighter than their stored values.
      pipeline.colourspace(:scrgb).recomb([[0.212656, 0.715158, 0.072186]])
        .linear(255, 0).rint.cast(:uchar).copy(interpretation: :b_w)
    end

    def write_svg(pipeline, destination)
      # libvips has a native SVG reader, but no SVG writer. Keep the requested
      # MIME/extension using a valid SVG containing the transformed PNG pixels.
      image = pipeline.call(save: false)
      png = image.pngsave_buffer(**options.fetch(:saver, {}).except(:quality))
      encoded = Base64.strict_encode64(png)
      destination.write(%(<svg xmlns="http://www.w3.org/2000/svg" width="#{image.width}" height="#{image.height}" viewBox="0 0 #{image.width} #{image.height}"><image width="#{image.width}" height="#{image.height}" href="data:image/png;base64,#{encoded}"/></svg>))
      destination.flush
    end
  end
end
