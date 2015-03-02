require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe "Url" do

  def shorten(url = nil, user = nil)
    url ||= "http://example.com/"
    user ||= "user"
    Firefly::Url.shorten(url, user)
  end

  describe "shortening" do
    it "should generate a code after create" do
      url = shorten
      Firefly::Url.where(url: "http://example.com/").first.code.should_not be_nil
    end

    it "should set a clicks count of 0 for newly shortened urls" do
      url = shorten
      Firefly::Url.where(url: "http://example.com/").first.clicks.should eql(0)
    end

    it "should create a new Firefly::Url with a new long_url" do
      lambda {
        shorten
      }.should change(Firefly::Url, :count).by(1)
    end

    it "should return an existing Firefly::Url if the long_url exists" do
      shorten
      lambda {
        shorten
      }.should_not change(Firefly::Url, :count)
    end

    it "should normalize urls correctly" do
      # Note the trailing '/'
      shorten
      lambda {
        shorten
      }.should_not change(Firefly::Url, :count)
    end

    it "should shortend urls containing spaces" do
      lambda {
        url = shorten("http://example.com/article with spaces.html")
      }.should change(Firefly::Url, :count).by(1)
    end

    it "should escape urls with spaces" do
      url = shorten("http://example.com/article with spaces.html")
      url.url.should eql("http://example.com/article%20with%20spaces.html")
    end

    it "should shortend urls containing weird characters" do
      lambda {
        url = shorten("http://example.com/?a=\11\15")
      }.should change(Firefly::Url, :count).by(1)
    end

    it "should escape urls with weird characters" do
      url = shorten("http://example.com/?a=\11\15")
      url.url.should eql("http://example.com/?a=%09%0D")
    end

    it "should not unescape invalid URL characters" do
      url = shorten("http://example.com/?a=%09")
      url.url.should eql("http://example.com/?a=%09")
    end

    it "should not escape already escaped URLs" do
      url = shorten("http://en.wikipedia.org/wiki/Tarski%27s_circle-squaring_problem")
      url.url.should eql("http://en.wikipedia.org/wiki/Tarski's_circle-squaring_problem")
    end

    it "should automatically forward code to prevent duplicates" do
      url = shorten("http://example.com/")
      the_code = url.code.next
      Firefly::Url.create(url: "http://example.com/blah", code: the_code)

      url_correct = shorten("http://example.com/testit")
      url_correct.code.should_not eql(the_code)
      url_correct.code.should eql(the_code.next)
    end
  end

  describe "long url validation" do
    [ "http://ariejan.net",
      "https://ariejan.net",
      "http://ariejan.net/page/1",
      "http://ariejan.net/page/1?q=x&p=123",
      "http://ariejan.net:8080/"
    ].each do |url|
      it "should accept #{url}" do
        shorten(url).should_not be_nil
      end
    end

    [ "ftp://ariejan.net",
      "irc://freenode.org/rails",
      "skype:adevroom",
      "ariejan.net",
    ].each do |url|
      it "should not accept #{url}" do
        lambda {
          shorten(url).should be_nil
        }.should raise_error(Firefly::InvalidUrlError)
      end
    end
  end

  describe "multi-user" do
    it "should store user correctly" do
      url = shorten("http://example.com", "some_user")
      url.user.should eql("some_user")
    end

    it "should be impossible to steal url from another user" do
      url = shorten("http://example.com", "some_user")
      lambda {
        shorten("http://example.com/", "some_other_user")
      }.should_not change(Firefly::Url, :count)
    end
  end

  describe "clicking" do
    before(:each) do
      Firefly::Url.create(
        url: 'http://example.com/123',
        code: 'alpha',
        clicks: 69
      )
      @url = Firefly::Url.where(code: 'alpha').first
    end

    it "should increase the click count" do
      lambda {
        @url.register_click!
      }.should change(@url, :clicks).by(1)
    end
  end
end
