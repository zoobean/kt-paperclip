# Run without the historical ActiveRecord/database harness:
# ruby -Ilib spec/paperclip/thumbnail_spec.rb
require "rspec/autorun"
require "active_model"
require "active_support/core_ext"
require "paperclip"
require "vips"
require "fileutils"
require "rexml/document"
require "base64"

RSpec.describe "Native libvips image processing" do
  before do
    @directory = Dir.mktmpdir("paperclip-vips")
    @results = []
    Paperclip.options[:log] = false
    Paperclip.options[:use_exif_orientation] = true
    expect(Paperclip).not_to receive(:run)
  end

  after do
    @results.each(&:close!)
    FileUtils.remove_entry(@directory)
    Paperclip.options[:use_exif_orientation] = true
  end

  def image_file(name = "source.png", width: 160, height: 80, color: [255, 0, 0])
    path = File.join(@directory, name)
    image = Vips::Image.black(width, height).new_from_image(color).copy(interpretation: :srgb)
    image.write_to_file(path)
    path
  end

  def thumbnail(path, **options)
    File.open(path, "rb") do |file|
      result = Paperclip::Thumbnail.make(file, options)
      @results << result unless result.equal?(file)
      result
    end
  end

  def dimensions(result)
    image = Vips::Image.new_from_file(result.path)
    [image.width, image.height]
  end

  def animated_file(extension = "gif")
    first = Vips::Image.black(16, 8).new_from_image([255, 0, 0]).copy(interpretation: :srgb)
    image = first.join(first.invert, :vertical)
    image.set_type(GObject::GINT_TYPE, "page-height", 8)
    image.set_type(Vips::ARRAY_INT_TYPE, "delay", [50, 100])
    image.set_type(GObject::GINT_TYPE, "loop", 3)
    path = File.join(@directory, "animated.#{extension}")
    image.write_to_file(path)
    path
  end

  {
    "100x100" => [100, 50],
    "100x100>" => [100, 50],
    "320x320>" => [160, 80],
    "100x100#" => [100, 100],
    "40x" => [40, 20],
    "x40" => [80, 40],
    "100x100!" => [100, 100],
    "320x320<" => [320, 160],
    "32x32<" => [160, 80],
    "100x100^" => [200, 100],
    "50%" => [80, 40],
    "3200@" => [80, 40],
    "51200@>" => [160, 80],
    nil => [160, 80],
  }.each do |geometry, expected|
    it "preserves #{geometry.inspect} geometry" do
      result = thumbnail(image_file, geometry: geometry)
      expect(dimensions(result)).to eq(expected)
      expect(result.read).not_to be_empty
      expect(result.pos).to be > 0
    end
  end

  it "uses the center of the image when cropping" do
    image = Vips::Image.xyz(160, 80)[0].cast(:uchar)
    path = File.join(@directory, "gradient.png")
    image.write_to_file(path)
    output = Vips::Image.new_from_file(thumbnail(path, geometry: "80x80#").path)
    expect(output.getpoint(0, 40).first).to be_within(1).of(40)
    expect(output.getpoint(79, 40).first).to be_within(1).of(119)
  end

  it "reports raw dimensions and preserves EXIF orientation behavior" do
    image = Vips::Image.black(160, 80).new_from_image([200, 40, 0]).copy(interpretation: :srgb)
    image.set_type(GObject::GINT_TYPE, "orientation", 6)
    path = File.join(@directory, "oriented.jpg")
    image.jpegsave(path)
    geometry = Paperclip::Geometry.from_file(path)
    expect([geometry.width, geometry.height]).to eq([160, 80])
    geometry.auto_orient
    expect([geometry.width, geometry.height]).to eq([80, 160])
    expect(dimensions(thumbnail(path, geometry: "40x40>"))).to eq([20, 40])
    expect(dimensions(thumbnail(path, geometry: "40x40>", auto_orient: false))).to eq([40, 20])
    Paperclip.options[:use_exif_orientation] = false
    geometry = Paperclip::Geometry.from_file(path)
    geometry.auto_orient
    expect([geometry.width, geometry.height]).to eq([160, 80])
  end

  it "keeps GIF frame count, coalesced canvases, timing, and loop count" do
    result = thumbnail(animated_file, geometry: "8x8#", saver: { strip: true })
    image = Vips::Image.new_from_file(result.path, n: -1)
    expect([image.width, image.height, image.get("page-height")]).to eq([8, 16, 8])
    expect(image.get("delay")).to eq([50, 100])
    expect(image.get("loop")).to eq(3)
    expect(image.getpoint(4, 4).take(3)).to eq([255, 0, 0])
    expect(image.getpoint(4, 12).take(3)).to eq([0, 255, 255])
  end

  it "can select a static frame or convert animated GIF to a static format" do
    source = animated_file
    expect(dimensions(thumbnail(source, geometry: "8x8", animated: false))).to eq([8, 4])
    result = thumbnail(source, geometry: "8x8", frame_index: 1, format: :png)
    expect(dimensions(result)).to eq([8, 4])
    expect(Vips::Image.new_from_file(result.path).getpoint(2, 2).take(3)).to eq([0, 255, 255])
    expect { thumbnail(source, frame_index: 5, format: :png) }.to raise_error(Paperclip::Error)
  end

  it "preserves the historical first-frame behavior for non-GIF animation" do
    result = thumbnail(animated_file("webp"), geometry: "8x8")
    expect(dimensions(result)).to eq([8, 4])
    image = Vips::Image.new_from_file(result.path, n: -1)
    expect(image.get_typeof("n-pages").zero? ? 1 : image.get("n-pages")).to eq(1)
  end

  it "detects input encoding when the extension is absent or unknown" do
    source = image_file
    %w[source source.unknown].each do |name|
      path = File.join(@directory, name)
      FileUtils.cp(source, path)
      result = thumbnail(path, geometry: "40x40")
      expect(dimensions(result)).to eq([40, 20])
      expect(result.read(8)).to eq("\x89PNG\r\n\x1a\n".b)
    end
  end

  it "flattens alpha onto white while retaining alpha when no flatten is requested" do
    source = image_file(color: [0, 0, 0, 0])
    transparent = Vips::Image.new_from_file(thumbnail(source, format: :png).path)
    expect(transparent.has_alpha?).to be(true)
    flattened = Vips::Image.new_from_file(thumbnail(source, flatten: [255, 255, 255], format: :png).path)
    expect(flattened.has_alpha?).to be(false)
    expect(flattened.getpoint(0, 0)).to eq([255, 255, 255])
  end

  it "matches baseline linear Rec709 luminance values, including midgray" do
    [[[255, 0, 0], 54], [[0, 255, 0], 182], [[0, 0, 255], 18], [[128, 128, 128], 55]].each do |color, gray|
      result = thumbnail(image_file("color-#{color.join('-')}.png", color: color), grayscale: :rec709_luminance, format: :png)
      image = Vips::Image.new_from_file(result.path)
      expect(image.bands).to eq(1)
      expect(image.getpoint(0, 0).first).to be_within(1).of(gray)
    end
  end

  it "strips metadata and applies JPEG quality" do
    image = Vips::Image.xyz(160, 80).bandjoin(80).cast(:uchar).copy(interpretation: :srgb)
    image.set_type(GObject::GSTR_TYPE, "exif-ifd0-ImageDescription", "private metadata")
    path = File.join(@directory, "metadata.jpg")
    image.jpegsave(path, Q: 100)
    low = thumbnail(path, saver: { quality: 10, strip: true }, format: :jpg)
    high = thumbnail(path, saver: { quality: 95 }, format: :jpg)
    expect(File.size(low.path)).to be < File.size(high.path)
    expect(Vips::Image.new_from_file(low.path).get_typeof("exif-data")).to eq(0)
    expect(Vips::Image.new_from_file(high.path).get("exif-ifd0-ImageDescription")).to include("private metadata")
    expect(low.read(2)).to eq("\xff\xd8".b)
  end

  it "rasterizes SVG natively and returns valid SVG when that is the requested format" do
    source = File.join(@directory, "source.svg")
    File.write(source, '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80"><rect width="160" height="80" fill="red"/></svg>')
    expect(Paperclip::Geometry.from_file(source).to_s).to eq("160x80")
    expect(dimensions(thumbnail(source, geometry: "40x40>", format: :png))).to eq([40, 20])
    svg = thumbnail(source, geometry: "40x40>")
    document = REXML::Document.new(svg.read)
    expect(document.root.name).to eq("svg")
    expect(document.root.attributes["width"]).to eq("40")
    expect(document.root.attributes["height"]).to eq("20")
    expect(document.root.elements["image"].attributes["href"]).to start_with("data:image/png;base64,")
    expect(dimensions(svg)).to eq([40, 20])
  end

  it "raises the existing geometry error for blank, corrupt, or missing sources" do
    path = File.join(@directory, "corrupt.png")
    File.write(path, "not an image")
    [nil, "", path, File.join(@directory, "missing.png")].each do |source|
      expect { Paperclip::Geometry.from_file(source) }.to raise_error(Paperclip::Errors::NotIdentifiedByImageMagickError)
    end
  end

  it "raises for legacy CLI image options rather than dropping transformations" do
    expect { thumbnail(image_file, convert_options: "-strip") }.to raise_error(Paperclip::Error, /saver/)
    expect { thumbnail(image_file, source_file_options: "-density 72") }.to raise_error(Paperclip::Error, /loader/)
  end

  it "does not return an empty tempfile when whiny processing is disabled" do
    path = image_file
    File.open(path, "rb") do |file|
      result = Paperclip::Thumbnail.make(file, format: :png, grayscale: :unknown, whiny: false)
      expect(result).to equal(file)
      expect(result.read).not_to be_empty
    end
  end

  it "runs with no image command line programs on PATH" do
    source = image_file
    previous = ENV["PATH"]
    begin
      ENV["PATH"] = ""
      expect(Paperclip::Geometry.from_file(source).to_s).to eq("160x80")
      expect(dimensions(thumbnail(source, geometry: "40x40>"))).to eq([40, 20])
    ensure
      ENV["PATH"] = previous
    end
  end

  it "blocks all ImageMagick loaders and savers even when present in libvips" do
    source = image_file
    %w[magickload magickload_buffer magick7load magick7load_buffer].each do |operation|
      next if Vips.type_find("VipsOperation", operation).zero?

      input = operation.end_with?("buffer") ? File.binread(source) : source
      expect { Vips::Operation.call(operation, [input]) }.to raise_error(Vips::Error, /blocked/)
    end
    image = Vips::Image.new_from_file(source)
    %w[magicksave magicksave_buffer magick7save magick7save_buffer].each do |operation|
      next if Vips.type_find("VipsOperation", operation).zero?

      args = operation.end_with?("buffer") ? [image] : [image, File.join(@directory, "forbidden.gif")]
      expect { Vips::Operation.call(operation, args) }.to raise_error(Vips::Error, /blocked/)
    end
  end
end
