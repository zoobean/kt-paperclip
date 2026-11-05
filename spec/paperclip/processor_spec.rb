require "spec_helper"

describe Paperclip::Processor do
  it "instantiates and call #make when sent #make to the class" do
    processor = double
    expect(processor).to receive(:make)
    expect(Paperclip::Processor).to receive(:new).with(:one, :two, :three).and_return(processor)
    Paperclip::Processor.make(:one, :two, :three)
  end

  it "does not expose ImageMagick command helpers" do
    processor = Paperclip::Processor.new("filename")
    expect(processor).not_to respond_to(:convert)
    expect(processor).not_to respond_to(:identify)
  end
end
