#!/usr/bin/env ruby

require "rubygems"
require "nokogiri"
require "open-uri"
require "exifr"
require "optparse"
require "fileutils"

module Enumerable
  def uniq_by
    seen = Hash.new { |h,k| h[k] = true; false }
    reject { |v| seen[yield(v)] }
  end
end


class Image

  @@read_images = Hash.new

  def initialize(url, folder, options)
    @url,@folder,@options = url, folder, options
  end

  def analyze(file)
    if file.downcase[".jpg"] or file.downcase[".jpeg"] then
      begin
        jpg = EXIFR::JPEG.new(file)
        puts "#{file}: #{jpg.comment}" if jpg.comment
        if jpg.exif? then  
          if jpg.exif.gps_latitude != nil then
            lat = jpg.exif.gps_latitude[0].to_f  + (jpg.exif.gps_latitude[1].to_f / 60) + (jpg.exif.gps_latitude[2].to_f / 3600)
            long = jpg.exif.gps_longitude[0] + (jpg.exif.gps_longitude[1].to_f / 60) + (jpg.exif.gps_longitude[2].to_f / 3600)
            long = long * -1 if jpg.exif.gps_longitude_ref == "W"   # (W is -, E is +)

            puts "Picture: #{file} Latitude: #{lat} Longitude #{long}"
            puts "Google Maps: http://maps.google.com/maps?ll=#{lat},#{long}&q=#{lat},#{long}"
          end
        end
      rescue RuntimeError, TypeError, NoMethodError => error
        puts "#{error} while analyzing #{file}"
      end
    end
  end

  def fetch
    if @@read_images[@url] then
      puts "Schon geladen: #{@url}" if @options[:verbose]
    else
      puts "Lade #{@url}" if @options[:verbose]
      filename = File.join(@folder, @url[/\d+\..*/])     
      begin
        if !File.exists?(filename) then
          File.open(filename, 'w') do |file|
            file.write(open(@url).read)           
          end
          analyze(filename) if @options[:gps]
        else  
          puts "File exists already: #{filename}" if File.exists?(filename) && @options[:verbose]
        end
        @@read_images[@href] = true
      rescue OpenURI::HTTPError => error
        puts error
        puts @url + " already gone..."
        File.delete(filename) 
      rescue => error
        puts "Error: #{error} while trying to fetch #{@url}."
        File.delete(filename)
      end
    end   
  end

end

class Faden 

  def initialize(root, url, folder, options)
    @root, @url, @folder, @options = root, url, folder, options
    puts "Lese Thread #{url}" if @options[:verbose]
  end

  def url
    case @options[:chan]
      when "krautchan"
        @root + @url
      when "4chan"
        @root + "/" + @options[:channel] + "/" + @url
    end
  end

  def fetch
    begin
      @doc = Nokogiri(open(url))
      case @options[:chan]
        when "krautchan" then
          @images = @doc/"a[@href*='files']"
        when "4chan" then
          @images = @doc/"a[@href*='src/']"
      end
      @images.each do |element|
        Image.new(case @options[:chan] when "krautchan" then @root+element[:href] when "4chan" then element[:href] end,@folder,@options).fetch
      end
    rescue OpenURI::HTTPError => error
      puts "Error while fetching #{url} - #{error}"
    end
  end
end

class Page
  
  def initialize(options, pagenum)
    @channel,@pagenum,@folder,@options = options[:channel],pagenum,File.join(options[:folder],options[:channel]), options
    @root, @suffix = "http://krautchan.net",".html" if @options[:chan] == "krautchan"
    @root, @suffix = "http://boards.4chan.org","" if @options[:chan] == "4chan"
  end

  def page
    
    case @options[:chan]
      when "krautchan" then
        @pagenum.to_s + @suffix
      when "4chan" then
        if @pagenum == 0 then "" else @pagenum.to_s end 
    end
  end

  def url
    @root + "/" + @channel + "/" + page
  end

  def fetch
    begin
      puts url
      @doc = Nokogiri(open(url))

      case @options[:chan]
        when "krautchan"
          @threads = @doc/"a[@href*='thread-']"
        when "4chan"
          @threads = @doc/"a[@href*='res/']"
      end
      @threads = @threads.uniq_by { |element| element[:href].split("#")[0]}
      FileUtils.makedirs(@folder)
      @threads.each do |thread|
        Faden.new(@root,thread[:href],@folder,@options).fetch
      end
    rescue => error
      puts "Something went wrong while fetching #{url}, trying next page."
      puts "Error: #{error}"
    end
  end
end

class Downloader

  def initialize(options)
    @channel,@folder, @options = options[:channel], options[:folder], options
    if File.exists?(File.join(@folder, @channel + "_downloaded")) then
      puts @channel + "_downloaded existiert"
    end
  end

  def really_fetch(pagenum)
    Page.new(@options,pagenum).fetch
  end

  def fetch_once
    threads = [] if @options[:threaded]
    (0..10).each do |pagenum|
      if @options[:threaded] then
        threads << Thread.new { really_fetch(pagenum) }        
      else
        really_fetch(pagenum)
      end
    end
    threads.each do |thread| thread.join end if @options[:threaded]
  end

  def fetch_endlessly
    while true do
      fetch_once
    end
  end

  def fetch
    if @options[:endless]
      fetch_endlessly
    else
      fetch_once
    end
  end

end

options = {}

optparse = OptionParser.new do |opts|

  opts.banner = "Usage: stalkerchan.rb [options]"

  options[:verbose] = false
  opts.on( "-v","--verbose","Verbose mode") do
    options[:verbose] = true
  end

  options[:threaded] = false
  opts.on("-t","--threaded","Use threads") do
    options[:threaded] = true
  end

  options[:channel] = "b"
  opts.on("-c","--channel CHANNEL","set channel to scrape (default: b)") do |channel|
    options[:channel] = channel
  end

  options[:folder] = "images"
  opts.on("-o","--output FOLDER","set output folder (default: images)") do |folder|
    options[:folder] = folder
  end

  options[:chan] = "krautchan"
  opts.on("-f","--fourchan","scrape 4chan instead of Krautchan") do
    options[:chan] = "4chan"
  end

  options[:gps] = false
  opts.on("-g","--gps","look for GPS data") do
    options[:gps] = true
  end
  
  options[:endless] = false
  opts.on("-e","--endless","download endlessly") do
    options[:endless] = true
  end

  opts.on("-h","--help","Display this screen") do
    puts opts
    exit
  end
end

optparse.parse!

Downloader.new(options).fetch
