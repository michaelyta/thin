require 'neverblock/io/io'
 
module Thin
  # Connection between the server and client.
  # This class is instanciated by EventMachine on each new connection
  # that is opened.
  class ReactorConnection
 
    CONTENT_LENGTH    = 'Content-Length'.freeze
    TRANSFER_ENCODING = 'Transfer-Encoding'.freeze
    CHUNKED_REGEXP    = /\bchunked\b/i.freeze
 
    # whenever we accumulate this buffer size we flush to the socket
    # when flush is called the buffer is emptied (and the conn is blocked)
    BUFFER_SIZE = 256*1024  

    include Logging
        
    # Rack application (adapter) served by this connection.
    attr_accessor :app
 
    # Backend to the server
    attr_accessor :backend
 
    # Current request served by the connection
    attr_accessor :request
 
    # Next response sent through the connection
    attr_accessor :response
 
    # Calling the application in a threaded allowing
    # concurrent processing of requests.
    attr_writer :threaded
 
    # Calling the application in a fiber allowing
    # concurrent processing of requests.
    attr_writer :fibered
    attr_writer :reactor 
    attr_writer :socket 
    
    def initialize(socket, reactor)
      @socket = socket
      @reactor = reactor
      @data = ""
      @sends = 0
      @t = Time.now
      @request  = Request.new
      @response = Response.new
    end
    
    def post_init
      @request  = Request.new
      @response = Response.new
      @reactor.attach(:read, @socket) do |socket, reactor|
        begin          
          receive_data(@socket.read_nonblock(8*1024))
        rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
        rescue Exception => e
          close_connection
        end
      end
    end
  
    def close_connection(after_writing=false)
      unless after_writing
        @reactor.detach(:read, @socket)
      end
      if after_writing        
        @reactor.detach(:read, @socket) if @reactor.attached?(:read, @socket)
        @socket.close unless @socket.closed?
      end
    end

    def close_connection_after_writing
      close_connection(true)
    end
    
    def send_data(data)
      @data << data 
      flush_data if @data.length >= BUFFER_SIZE
    end

    def flush_data
      return if @data.blank?
      begin
        @socket.syswrite(@data)
      rescue Exception => e
        puts e
        close_connection
        return 
      end
      @data = ''      
    end

    # Called when data is received from the client.
    def receive_data(data)  
      trace { data }
      post_process(pre_process) if @request.parse(data)
    rescue InvalidRequest => e
      log "!! Invalid request"
      log_error e
      close_connection
    end
 
    # Called when all data was received and the request
    # is ready to be processed.
 
    def pre_process
      @app.call(@request.env)
    rescue Exception
      handle_error
      terminate_request
      nil # Signal to post_process that the request could not be processed
    end
 
    def post_process(result)
      begin
        return unless result
        result = result.to_a
        # Set the Content-Length header if possible
        set_content_length(result) if need_content_length?(result)        
        @response.status, @response.headers, @response.body = *result
        log "!! Rack application returned nil body. Probably you wanted it to be an empty string?" if @response.body.nil?
        # Send the response
        @response.each do |chunk|
          trace { chunk }
          send_data chunk
        end
        flush_data
      rescue Exception
        handle_error
      ensure
        terminate_request
      end
    end
 
    # Logs catched exception and closes the connection.
    def handle_error
      log "!! Unexpected error while processing request: #{$!.message}"
      log_error
      close_connection rescue nil
    end
 
    def close_request_response
      @request.close  rescue nil
      @response.close rescue nil
    end
 
    def terminate_request
      close_connection_after_writing rescue nil
      close_request_response
    end
  
    # Allows this connection to be persistent.
    def can_persist!
    end
 
    # Return +true+ if this connection is allowed to stay open and be persistent.
    def can_persist?
      false
    end
 
    # Return +true+ if the connection must be left open
    # and ready to be reused for another request.
    def persistent?
      false
    end
 
    def threaded?
      false
    end
 
    # IP Address of the remote client.
    def remote_address
      @request.forwarded_for || socket_address
    rescue Exception
      log_error
      nil
    end
 
    protected
 
      # Returns IP address of peer as a string.
      def socket_address
        Socket.unpack_sockaddr_in(get_peername)[1]
      end
 
    private
      def need_content_length?(result)
        status, headers, body = result
        return false if status == -1
        return false if headers.has_key?(CONTENT_LENGTH)
        return false if (100..199).include?(status) || status == 204 || status == 304
        return false if headers.has_key?(TRANSFER_ENCODING) && headers[TRANSFER_ENCODING] =~ CHUNKED_REGEXP
        return false unless body.kind_of?(String) || body.kind_of?(Array)
        true
      end
 
      def set_content_length(result)
        headers, body = result[1..2]
        case body
        when String
          # See http://redmine.ruby-lang.org/issues/show/203
          headers[CONTENT_LENGTH] = (body.respond_to?(:bytesize) ? body.bytesize : body.size).to_s
        when Array
           bytes = 0
           body.each do |p|
             bytes += p.respond_to?(:bytesize) ? p.bytesize : p.size
           end
           headers[CONTENT_LENGTH] = bytes.to_s
        end
      end
  end
end
