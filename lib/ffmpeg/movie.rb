require 'time'
require 'multi_json'
require 'uri'
require 'net/http'
require 'json'

module FFMPEG
  class Movie
    attr_reader :path, :duration, :time, :bitrate, :rotation, :creation_time
    attr_reader :video_stream, :video_codec, :video_bitrate, :colorspace, :width, :height, :sar, :dar, :level, :profile, :frame_rate
    attr_reader :audio_streams, :audio_stream, :audio_codec, :audio_bitrate, :audio_sample_rate, :audio_channels, :audio_tags
    attr_reader :max_volume, :mean_volume, :lkfs, :loudness_lra, :loudness_true_peak, :loudness_threshold, :target_offset, :normalize_command, :loudness_error
    attr_reader :container
    attr_reader :metadata, :format_tags

    UNSUPPORTED_CODEC_PATTERN = /^Unsupported codec with id (\d+) for input stream (\d+)$/

    def initialize(path)
      @path = path

      if remote?
        @head = head
        unless @head.is_a?(Net::HTTPSuccess)
          raise Errno::ENOENT, "the URL '#{path}' does not exist or is not available (response code: #{@head.code})"
        end
      else
        raise Errno::ENOENT, "the file '#{path}' does not exist" unless File.exist?(path)
      end

      @path = path

      set_loudness

      # ffmpeg will output to stderr
      command = [FFMPEG.ffprobe_binary, '-i', path, *%w(-print_format json -show_format -show_streams -show_error)]
      std_output = ''
      std_error = ''

      Open3.popen3(*command) do |stdin, stdout, stderr|
        std_output = stdout.read unless stdout.nil?
        std_error = stderr.read unless stderr.nil?
      end

      get_levels_command = [FFMPEG.ffmpeg_binary, '-i', path, *%w(-af volumedetect -f null /dev/null)]
      output = Open3.popen3(*get_levels_command) do |stdin, stdout, stderr|
        std_error = stderr.read unless stderr.nil?
      end

      fix_encoding(std_output)
      fix_encoding(std_error)

      @mean_volume = output[/mean_volume:\ (.*)/, 1]

      @max_volume = output[/max_volume:\ (.*)/, 1]

      begin
        @metadata = MultiJson.load(std_output, symbolize_keys: true)
      rescue MultiJson::ParseError
        raise "Could not parse output from FFProbe:\n#{ std_output }"
      end

      if @metadata.key?(:error)

        @duration = 0

      else
        video_streams = @metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'video' }
        audio_streams = @metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'audio' }

        @container = @metadata[:format][:format_name]

        @duration = @metadata[:format][:duration].to_f

        @time = @metadata[:format][:start_time].to_f

        @format_tags = @metadata[:format][:tags]

        @creation_time = if @format_tags and @format_tags.key?(:creation_time)
                           begin
                             Time.parse(@format_tags[:creation_time])
                           rescue ArgumentError
                             nil
                           end
                         else
                           nil
                         end

        @bitrate = @metadata[:format][:bit_rate].to_i

        # TODO: Handle multiple video codecs (is that possible?)
        video_stream = video_streams.first
        unless video_stream.nil?
          @video_codec = video_stream[:codec_name]
          @colorspace = video_stream[:pix_fmt]
          @width = video_stream[:width]
          @height = video_stream[:height]
          @video_bitrate = video_stream[:bit_rate].to_i
          @sar = video_stream[:sample_aspect_ratio]
          @dar = video_stream[:display_aspect_ratio]
          @level = video_stream[:level]
          @profile = video_stream[:profile]

          @frame_rate = unless video_stream[:avg_frame_rate] == '0/0'
                          Rational(video_stream[:avg_frame_rate])
                        else
                          nil
                        end

          @video_stream = "#{video_stream[:codec_name]} (#{video_stream[:profile]}) (#{video_stream[:codec_tag_string]} / #{video_stream[:codec_tag]}), #{colorspace}, #{resolution} [SAR #{sar} DAR #{dar}]"

          @rotation = if video_stream.key?(:tags) and video_stream[:tags].key?(:rotate)
                        video_stream[:tags][:rotate].to_i
                      else
                        nil
                      end
        end

        @audio_streams = audio_streams.map do |stream|
          {
            :index => stream[:index],
            :channels => stream[:channels].to_i,
            :codec_name => stream[:codec_name],
            :sample_rate => stream[:sample_rate].to_i,
            :bitrate => stream[:bit_rate].to_i,
            :channel_layout => stream[:channel_layout],
            :tags => stream[:streams],
            :overview => "#{stream[:codec_name]} (#{stream[:codec_tag_string]} / #{stream[:codec_tag]}), #{stream[:sample_rate]} Hz, #{stream[:channel_layout]}, #{stream[:sample_fmt]}, #{stream[:bit_rate]} bit/s"
          }
        end

        audio_stream = @audio_streams.first
        unless audio_stream.nil?
          @audio_channels = audio_stream[:channels]
          @audio_codec = audio_stream[:codec_name]
          @audio_sample_rate = audio_stream[:sample_rate]
          @audio_bitrate = audio_stream[:bitrate]
          @audio_channel_layout = audio_stream[:channel_layout]
          @audio_tags = audio_stream[:audio_tags]
          @audio_stream = audio_stream[:overview]
        end

      end

      unsupported_stream_ids = unsupported_streams(std_error)
      nil_or_unsupported = ->(stream) { stream.nil? || unsupported_stream_ids.include?(stream[:index]) }

      @invalid = true if nil_or_unsupported.(video_stream) && nil_or_unsupported.(audio_stream)
      @invalid = true if @metadata.key?(:error)
      @invalid = true if std_error.include?("could not find codec parameters")
    end

    def set_loudness
      lkfs_command = [FFMPEG.ffmpeg_binary, '-i', path, '-af', *%w(loudnorm=I=-24:TP=-1.5:LRA=11:print_format=json -f null -)]
      _stdin, _stdout, std_err, wait_thr = Open3.popen3(*lkfs_command)

      raise 'Could not parse lkfs' unless wait_thr.value.success?

      stats = JSON.parse(std_err.read.lines[-12, 12].join)
      @lkfs = stats['input_i']
      @loudness_lra = stats['input_lra']
      @loudness_threshold = stats['input_thresh']
      @loudness_true_peak = stats['input_tp']
      @target_offset = stats['target_offset']

      # This attribute can be used as the input to 'loudness_normalization' when doing two-pass transcoding
      @normalize_command = "loudnorm=I=-24:TP=-1.5:LRA=11:measured_I=#{@lkfs}"\
        ":measured_LRA=#{@loudness_lra}:measured_TP=#{@loudness_true_peak}:measured_thresh"\
        "=#{@loudness_threshold}:offset=#{@target_offset}:linear=true:print_format=summary"
    rescue
      @invalid = true
      @loudness_error = 'Could not parse lkfs'
    ensure
      std_err.flush
    end

    def unsupported_streams(std_error)
      [].tap do |stream_indices|
        std_error.each_line do |line|
          match = line.match(UNSUPPORTED_CODEC_PATTERN)
          stream_indices << match[2].to_i if match
        end
      end
    end

    def valid?
      not @invalid
    end

    def remote?
      @path =~ URI::regexp(%w(http https))
    end

    def local?
      not remote?
    end

    def width
      rotation.nil? || rotation == 180 ? @width : @height;
    end

    def height
      rotation.nil? || rotation == 180 ? @height : @width;
    end

    def resolution
      unless width.nil? or height.nil?
        "#{width}x#{height}"
      end
    end

    def calculated_aspect_ratio
      aspect_from_dar || aspect_from_dimensions
    end

    def calculated_pixel_aspect_ratio
      aspect_from_sar || 1
    end

    def size
      if local?
        File.size(@path)
      else
        @head.content_length
      end
    end

    def audio_channel_layout
      # TODO Whenever support for ffmpeg/ffprobe 1.2.1 is dropped this is no longer needed
      @audio_channel_layout || case(audio_channels)
                                 when 1
                                   'stereo'
                                 when 2
                                   'stereo'
                                 when 6
                                   '5.1'
                                 else
                                   'unknown'
                               end
    end

    def transcode(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options, **transcoder_options).run &block
    end

    def screenshot(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options.merge(screenshot: true), **transcoder_options).run &block
    end

    protected
    def aspect_from_dar
      calculate_aspect(dar)
    end

    def aspect_from_sar
      calculate_aspect(sar)
    end

    def calculate_aspect(ratio)
      return nil unless ratio
      w, h = ratio.split(':')
      return nil if w == '0' || h == '0'
      @rotation.nil? || (@rotation == 180) ? (w.to_f / h.to_f) : (h.to_f / w.to_f)
    end

    def aspect_from_dimensions
      aspect = width.to_f / height.to_f
      aspect.nan? ? nil : aspect
    end

    def fix_encoding(output)
      output[/test/] # Running a regexp on the string throws error if it's not UTF-8
    rescue ArgumentError
      output.force_encoding("ISO-8859-1")
    end

    def head(location=@path, limit=FFMPEG.max_http_redirect_attempts)
      url = URI(location)
      return unless url.path

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.port == 443
      response = http.request_head(url.request_uri)

      case response
        when Net::HTTPRedirection then
          raise FFMPEG::HTTPTooManyRequests if limit == 0
          new_uri = url + URI(response['Location'])

          head(new_uri, limit - 1)
        else
          response
      end
    rescue SocketError, Errno::ECONNREFUSED => e
      nil
    end
  end
end
