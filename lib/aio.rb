module AIO
  module Util
    class << self

      def to_encoding x
        if x.is_a? Encoding
          return x
        else
          Encoding._load x
        end
      end

    end
  end

  module Filterable
    module ClassMethods
      def munge *tokens
        ("__" + ["filter",*tokens].join("_")).intern
      end

      def method_filtered? meth
        method_defined? munge(meth, :base)
      end

      def method_hooked? meth
        instance_method(meth) == instance_method(munge(meth, :invoke))
      end

      def send_unfiltered meth, *args, &block
        if method_filtered? meth
          send munge(meth, :base), *args, &block
        else
          send meth, *args, &block
        end
      end

      def method_added meth
        if method_filtered?(meth) && !method_hooked?(meth)
          alias_method munge(meth, :base), meth
          alias_method meth, munge(meth, :invoke)
        end
      end

      def method_chain *tokens
        n = 0
        Enumerator.new do |y|
          while method_defined? munge(*tokens,n)
            y << munge(*tokens,n)
            n += 1
          end
        end
      end

      def remove_filters meth
        alias_method meth, munge(meth,:base) if method_defined? munge(meth,:base)
        method_chain(meth,:before).each {|m| remove_method m }
        remove_method munge(meth,:invoke) if method_defined? munge(meth,:invoke)
        remove_method munge(meth,:base) if method_defined? munge(meth,:invoke)
      end

      def before_filter meth, &block
        alias_method munge(meth, :base), meth unless method_filtered?(meth)

        len = method_chain(meth, :before).count
        define_method munge(meth, :before, len), &block
        len += 1

        define_method munge(meth, :invoke) do |*args, &block|
          len.times {|i| send "__filter_#{meth}_before_#{i}".intern, *args, &block }
          send "__filter_#{meth}_base".intern, *args, &block
        end

        alias_method meth, munge(meth, :invoke)
      end
    end

    def included klass
      klass.extend ClassMethods
      super
    end
  end

  module Stream
    # Used to implement external_encoding and general encoding functionality.
    # Should always return the intrinsic encoding of the stream source.
    # Default implementation returns +Encoding.default_external+.
    def _external_encoding
      Encoding.default_external
    end

    # Used to implement +tty?+ and +isatty+
    # Default implementation returns +false+
    def _tty?
      false
    end

    # Initialize the internal state of this stream object with external encoding set to +enc+.
    # This method must be called before the stream object is used.
    def _init enc
      @_external_encoding = enc
      _init_converter
    end

    # Pretend we are an IO to satisfy type checks.
    def kind_of? mod
      mod == IO or super
    end
    alias_method :is_a?, :kind_of?

    # These methods have no general implementation but they do (mostly) have sensible defaults
    def tty?; _tty?; end
    alias_method :isatty, :tty?
    def ioctl *args; end
    def fileno; end
    def fsync; end
    def stat; end
    def to_io; self; end
    def sync; @_sync; end
    def sync= arg; @_sync = arg; end
    def flush; end
    def fcntl *args; end
    def pid; end
    def close_on_exec= arg; @_close_on_exec = arg; end
    def close_on_exec; @_close_on_exec; end
    alias_method :close_on_exec?, :close_on_exec

    def _init_converter opt={}
      if @_internal_encoding
        c = Encoding::Converter.new @_external_encoding || _external_encoding,
                                    @_internal_encoding,
                                    opt
        @_converter = proc {|s| c.convert s }
      else
        @_converter = proc {|s| s }
      end
    end

    # Internal encoding conversion implementation
    def external_encoding; @_external_encoding || _external_encoding; end
    def internal_encoding; @_internal_encoding; end

    def set_encoding a, b=nil, opt={}
      if b
        @_external_encoding = Util.to_encoding a
        @_internal_encoding = Util.to_encoding b
      elsif a.is_a? Encoding
        @_external_encoding = a
        @_internal_encoding = nil
      elsif a.nil?
        @_external_encoding = @_internal_encoding = nil
      else
        a = a.to_s
        if a =~ /:/
          @_external_encoding, @_internal_encoding = a.split(/:/).map {|e| Encoding._load e }
        else
          @_external_encoding = Encoding._load a
          @_internal_encoding = nil
        end
      end

      _init_converter opt
      return self
    end

    def binmode
      @_binmode = true
      set_encoding Encoding::BINARY
      self
    end
    def binmode?; @_binmode || false; end
  end

  module Readable
    include Enumerable

    # Should return truthy if we are at the "end" of the stream i.e. there are no more bytes to read.
    # This method must be implemented if the stream is finite in length.
    # Default implementation always returns +false+ which is what you would want for an endless stream.
    def prim_eof?
      false
    end

    # Should read one *byte* and return it as a string with ASCII-8BIT encoding.
    # If at the end of the stream, +nil+ should be returned.
    # A minimal Readable implementation only needs to override this one method.
    # However, the multi-byte overrides can also be overridden for better efficiency.
    # Default implementation raises NotImplementedError.
    def prim_read_byte
      raise NotImplementedError.new "reading is not implemented"
    end

    # Should read to the "end" of the stream or +length+ *bytes* (not chars) if +length+ is not +nil+.
    # The read data should be returned as a string with ASCII-8BIT encoding.
    # If already at the end of the stream, +nil+ should be returned.
    # Used to implement all per-byte blocking reads.
    # Default implementation uses +prim_read_byte+ to read one byte at a time.
    def prim_read length
      buf = "".encode Encoding::BINARY
      if length.nil?
        buf << b until (b = _read_byte).nil?
      else
        until length.zero? || (b = _read_byte).nil?
          buf << b
          length -= 1
        end
      end
      return buf
    end

    # Should read until +delim+ is found in the stream or
    #                   the "end" of the stream is reached or
    #                   +limit+ *bytes* are read, if +limit+ is not +nil+.
    # +delim+ will be a non-empty string with ASCII-8BIT encoding.
    # The read data should be returned as a string with ASCII-8BIT encoding
    # and should include +delim+, if it was found.
    # If no bytes can be read because we are at the end of the stream, +nil+ should be returned.
    # Used to implement many delimited blocking reads.
    # Default implementation uses +prim_read_byte+ to read one byte at a time.
    def prim_read_until delim, limit
      buf = ""
      if limit.nil?
        until buf.end_with? delim || (b = _read_byte).nil?
          buf << c
        end
      else
        until limit.zero? || buf.end_with?(delim) || (b = _read_byte).nil?
          buf << c
          limit -= 1
        end
      end
      return buf unless buf == "" && limit != 0
    end

    # Should read up to +maxlen+ *bytes* (not chars) that are immediately available in the stream, without blocking.
    # The read data should be returned as a string with ASCII-8BIT encoding.
    # If no bytes are available without blocking, but we are not at the end of the stream, +:block+ should be returned.
    # If at the end of the stream, +nil+ should be returned.
    # Used to implement +read_nonblock+ and +readpartial+
    # Default implementation raises NotImplementedError.
    def prim_read_nonblock maxlen
      raise NotImplementedError.new "non-blocking read is not implemented"
    end


    ###############################
    # These are overridden in BufferedReader 

    alias_method :_eof?,            :prim_eof?
    alias_method :_read_byte,       :prim_read_byte
    alias_method :_read,            :prim_read
    alias_method :_read_until,      :prim_read_until
    alias_method :_read_nonblock,   :prim_read_nonblock

    ###############################
    # Internal primitives

    def _check_read_open
      raise IOError.new "closed stream" if @_read_closed
    end

    def _process_gets_args sep, limit
      if sep.is_a? Integer
        limit = sep
        sep = $/
      end
      sep = sep.force_encoding external_encoding
      raise ArgumentError.new "encoding mismatch: #{external_encoding} stream with #{str.encoding} argument" unless e.valid_encoding?
      return [sep,limit]
    end

    ###############################
    # Derived read methods

    def each_byte
      _check_read_open
      if block_given?
        yield b.ord while b = _read_byte
        return self
      else
        Enumerator.new {|y| self.each_byte {|b| y << b } }
      end
    end

    def bytes
      _check_read_open
      Enumerator.new {|y| self.each_byte {|b| y << b } }
    end

    def each_char
      _check_read_open
      if block_given?
        while b = _read_byte
          c = @_converter[b]
          yield c unless c.empty?
        end
        return self
      else
        Enumerator.new {|y| self.each_char {|c| y << c } }
      end
    end

    def chars
      _check_read_open
      Enumerator.new {|y| self.each_char {|c| y << c } }
    end

    def each_line sep=$/, limit=nil
      _check_read_open
      if block_given?
        yield @_converter[l] while l = _read_until(*_process_gets_args(sep, limit))
        return self
      else
        Enumerator.new {|y| self.each_line(sep, limit) {|l| y << l } }
      end
    end
    alias_method :each, :each_line

    def lines sep=$/, limit=nil
      Enumerator.new {|y| self.each_line(sep, limit) {|l| y << l } }
    end

    def eof
      _check_read_open
      _eof
    end
    alias_method :eof?, :eof

    def getbyte
      _check_read_open
      return b.ord if b = _read_byte
    end

    def readbyte
      _check_read_open
      return (_read_byte or raise EOFError.new "end of stream reached")
    end

    def getc
      _check_read_open
      (return c unless (c = @_converter[b]).empty?) while b = _read_byte
    end    

    def readchar
      _check_read_open
      return (getc or raise EOFError.new "end of stream reached")
    end

    def gets sep=$/, limit=nil
      _check_read_open
      return $_ = (@_converter[l] if l = _read_until(_process_gets_args sep, limit))
    end

    def readline sep=$/, limit=nil
      _check_read_open
      return (_read_until(_process_gets_args(sep, limit)) or raise EOFError.new "end of stream reached")
    end

    def readlines sep=$/, limit=nil
      lines(sep, limit).to_a
    end

    def read length=nil, buffer=nil
      if buffer
        buffer.replace s.force_encoding(buffer.encoding) if s = _read(length)
      else
        _read length
      end
    end
    alias_method :sysread, :read

    def readpartial maxlen, outbuf=nil
      _check_read_open
      return "" if maxlen.zero?
      raise EOFError.new "end of stream reached" unless s = _read_nonblock(maxlen)
      return s unless s == :block
      return _read maxlen
    end

  end

  # Adds seperate internal closed? states for reading and writing and adds appropriate checks to the standard methods.
  module Closable
    # Should close the readable part of the stream.
    # Used to implement +close_read+ and +close+.
    # Default implementation sets the internal state checked by read methods and +closed?+
    def _close_read
      @_read_closed = true
    end

    # Should close the writable part of the stream.
    # Used to implement +close_write+ and +close+.
    # Default implementation sets the internal state checked by write methods and +closed?+
    def _close_write
      @_write_closed = true
    end

    # Closing implementation
    def close; _close_read; _close_write; nil; end
    def close_read; _close_read; nil; end
    def close_write; _close_write; nil; end
    def closed?; @_read_closed && @_write_closed; end
  end

  module CountedReadable
    # Line counting based on per-line read calls
    # and +rewind+, if +RandomlyAccessible+ is mixed in
    def lineno; @_lineno; end
    def lineno= n; @_lineno = n; end
  end

  # Adds an internal buffer to Readable and implements +ungetc+ and +ungetbyte+
  module BufferedReadable
    include Readable

    def ungetbyte b; end
    def ungetc c; end
  end

  module RandomlyAccessible
    # Should set the read/write position of the stream to +amount+, which is relative to +whence+.
    # +whence+ will be one of +IO::SEEK_CUR+, +IO::SEEK_END+ or +IO::SEEK_SET+.
    # Used to implement all random seeking.
    def _seek amount, whence
      raise NotImplementedError.new "_seek method is not implemented"
    end

    def seek pos, whence=IO::SEEK_SET
    end

    def sysseek *args; end
    def tell; end
    def pos; end
    def pos= n; end

    def rewind
      pos = 0
      lineno = 0 if respond_to? :lineno=
    end
  end

  module Writable
    # Should write +string+ to the stream and return the number of bytes written.
    # +string+ will be encoded as ASCII-8BIT.
    # Used to implement all per-character blocking writes
    # Default implementation raises NotImplementedError.
    def _write string
      raise NotImplementedError.new "_write method is not implemented"
    end

    # Used to implement write_nonblock.
    # Default implementation raises NotImplementedError.
    def _write_nonblock string
      raise NotImplementedError.new "_write method is not implemented"
    end

    def << obj
      _write obj.to_s
    end

    # Derived write methods
    def print *args; end
    def printf *args; end
    def putc c; end
    def puts *args; end
    def syswrite str; end
    def write str; end
    def write_nonblock str; end
  end

end
