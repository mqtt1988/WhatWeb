=begin
Copyright 2009, 2017 Andrew Horton and Brendan Coles

This file is part of WhatWeb.

WhatWeb is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or at your option) any later version.

WhatWeb is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with WhatWeb.  If not, see <http://www.gnu.org/licenses/>.
=end

class Target
  attr_reader :target
  attr_reader :uri, :status, :ip, :body, :headers, :raw_headers, :raw_response
  attr_reader :cookies
  attr_reader :md5sum
  attr_reader :tag_pattern
  attr_reader :is_url, :is_file
  attr_accessor :http_options

  @@meta_refresh_regex=/<meta[\s]+http\-equiv[\s]*=[\s]*['"]?refresh['"]?[^>]+content[\s]*=[^>]*[0-9]+;[\s]*url=['"]?([^"'>]+)['"]?[^>]*>/i

  def inspect
    #	"#{target} " + [@uri,@status,@ip,@body,@headers,@raw_headers,@raw_response,@cookies,@md5sum,@tag_pattern,@is_url,@is_file].join(",")
    "URI\n#{'*' * 40}\n#{@uri}" +
        "status\n#{'*' * 40}\n#{@status}" +
        "ip\n#{'*' * 40}\n#{@ip}" +
        "header\n#{'*' * 40}\n#{@headers}" +
        "cookies\n#{'*' * 40}\n#{@cookies}" +
        "raw_headers\n#{'*' * 40}\n#{@raw_headers}" +
        "raw_response\n#{'*' * 40}\n#{@raw_response}" +
        "body\n#{'*' * 40}\n#{@body}" +
        "md5sum\n#{'*' * 40}\n#{@md5sum}" +
        "tag_pattern\n#{'*' * 40}\n#{@tag_pattern}" +
        "is_url\n#{'*' * 40}\n#{@is_url}" +
        "is_file\n#{'*' * 40}\n#{@is_file}"
  end

  def to_s
    @target
  end

  def Target.meta_refresh_regex
    @@meta_refresh_regex
  end

  def is_file?
    @is_file
  end

  def is_url?
    @is_url
  end

  def initialize(target = nil)
    @target = target
    @headers = {}
    @http_options = {:method => "GET"}
#		@status=0

    if @target =~ /^http[s]?:\/\//
      @is_url = true
    else
      @is_url = false
    end

    if File.exists?(@target)
      @is_file = true
      if File.directory?(@target)
        raise "Error: #{@target} is a directory"
      end
      if File.readable?(@target) == false
        raise "Error: You do not have permission to view #{@target}"
      end
    else
      @is_file = false
    end

    if self.is_url?
      @uri=URI.parse(URI.encode(@target))

      # is this taking control away from the user?
      # [400] http://www.alexa.com  [200] http://www.alexa.com/
      @uri.path = "/" if @uri.path.empty?
    else
      # @uri=URI.parse("file://"+@target)
      @uri = URI.parse("")
    end
  end

  def open
    if self.is_file?
      open_file
    else
      open_url(@http_options)
    end

    ## after open
    if @body.nil?
      # Initialize @body variable if the connection is terminated prematurely
      # This is usually caused by HTTP status codes: 101, 102, 204, 205, 305
      @body = ""
    else
      @md5sum = Digest::MD5.hexdigest(@body)
      @tag_pattern = make_tag_pattern(@body)
      if @raw_headers
        @raw_response = @raw_headers + @body
      else
        @raw_response = @body
        @raw_headers = ""
        @cookies = []
      end
    end
  end


  def open_file
    begin
      # target is a file
      @body=File.open(@target).read
      if String.method_defined?(:encode)
          @body.encode!('UTF-16', 'UTF-8', :invalid => :replace, :replace => '')
          @body.encode!('UTF-8', 'UTF-16')
      else
         ic = Iconv.new('UTF-8', 'UTF-8//IGNORE')
         @body = ic.iconv(@body)
      end
      # target is a http packet file
      if @body =~ /^HTTP\/1\.\d [\d]{3} (.+)\r\n\r\n/m
        # extract http header
        @headers = Hash.new
        pageheaders = body.to_s.split(/\r\n\r\n/).first.to_s.split(/\r\n/)
        @raw_headers = pageheaders.join("\n") + "\r\n\r\n"
        @status = pageheaders.first.scan(/^HTTP\/1\.\d ([\d]{3}) /).flatten.first.to_i
        @cookies = []
        for k in 1...pageheaders.length
          section = pageheaders[k].split(/:/).first.to_s.downcase
          if section =~ /^set-cookie$/i
            @cookies << pageheaders[k].scan(/:[\s]*(.+)$/).flatten.first
          else
            @headers[section] = pageheaders[k].scan(/:[\s]*(.+)$/).flatten.first
          end
        end
        @headers["set-cookie"] = @cookies.join("\n") unless @cookies.nil? or @cookies.empty?
        # extract html source
        if @body =~ /^HTTP\/1\.\d [\d]{3} .+?\r\n\r\n(.+)/m
          @body = @body.scan(/^HTTP\/1\.\d [\d]{3} .+?\r\n\r\n(.+)/m).flatten.first
        end
      end
    rescue => err
      raise
    end
  end

  def open_url(options)

    begin
      @ip = Resolv.getaddress(@uri.host)
    rescue => err
      raise
    end

    begin
      if $USE_PROXY == true
        http = ExtendedHTTP::Proxy($PROXY_HOST, $PROXY_PORT, $PROXY_USER, $PROXY_PASS).new(@uri.host, @uri.port)
      else
        http = ExtendedHTTP.new(@uri.host, @uri.port)
      end

      # set timeouts
      http.open_timeout = $HTTP_OPEN_TIMEOUT
      http.read_timeout = $HTTP_READ_TIMEOUT

      # if it's https://
      # i wont worry about certificates, verfication, etc
      if @uri.class == URI::HTTPS
        http.use_ssl = true
	      OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:ciphers] = "TLSv1:TLSv1.1:TLSv1.2:SSLv3:SSLv2"
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      getthis = @uri.path + (@uri.query.nil? ? "" : "?" + @uri.query)
      req = nil

      if options[:method] == "GET"
        req = ExtendedHTTP::Get.new(getthis, $CUSTOM_HEADERS)
      end
      if options[:method] == "HEAD"
        req = ExtendedHTTP::Head.new(getthis, $CUSTOM_HEADERS)
      end
      if options[:method] == "POST"
        req = ExtendedHTTP::Post.new(getthis, $CUSTOM_HEADERS)
        req.set_form_data(options[:data])
      end

      if $BASIC_AUTH_USER
        req.basic_auth $BASIC_AUTH_USER, $BASIC_AUTH_PASS
      end

      res = http.request(req)
      
      @raw_headers = http.raw.join("\n")
      
      @headers = {}
      res.each_header { |x, y| @headers[x] = y }

      @headers["set-cookie"] = res.get_fields('set-cookie').join("\n") unless @headers["set-cookie"].nil?

      @body = res.body            
      @status = res.code.to_i
      puts @uri.to_s + " [#{status}]" if $verbose > 1

    rescue => err
      raise
    end

  end


  def get_redirection_target
    newtarget_m, newtarget_h, newtarget = nil

    if @@meta_refresh_regex =~ @body
      metarefresh = @body.scan(@@meta_refresh_regex).flatten.first
      metarefresh = decode_html_entities(metarefresh)
      newtarget_m = URI.join(@target, metarefresh).to_s # this works for relative and absolute
    end

    # HTTP 3XX redirect
    if (300..399) === @status and @headers and @headers['location']
      # downcase location scheme
      location = @headers["location"].gsub(/^HTTPS:\/\//, 'https://').gsub(/^HTTP:\/\//, 'http://')
      newtarget_h = URI.join(@target,location).to_s
    end

    # if both meta refresh location and HTTP location are set, then the HTTP location overrides
    if newtarget_m or newtarget_h
      case $FOLLOW_REDIRECT
        when "never"
          no_redirects=true # this never gets back to main loop but no prob
        when "http-only"
          newtarget = newtarget_h
        when "meta-only"
          newtarget = newtarget_m
        when "same-site"
          newtarget = (newtarget_h or newtarget_m) if URI.parse((newtarget_h or newtarget_m)).host == @uri.host # defaults to _h if both are present
        when "always"
          newtarget = (newtarget_h or newtarget_m)
        else
          error("Error: Invalid REDIRECT mode")
      end
    end
    newtarget = nil if newtarget == @uri.to_s # circular redirection not allowed

    newtarget
  end

end

