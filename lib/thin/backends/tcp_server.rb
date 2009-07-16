require 'neverblock'
require File.expand_path(File.dirname(__FILE__) + '/../connection')

module Thin
  module Backends
    # Backend to act as a TCP socket server.
    class TcpServer < Base
      
      # Allow using fibers in the backend.
      def fibered?; true; end
            
      def initialize(host, port, options={})
        @host    = host
        @port    = port.to_i
        @timeout = 30
      end
          
      def start
        @reactor = NB.reactor
        @server_socket = TCPServer.new(@host, @port)
        @server_socket.listen(511)
        @reactor.attach(:read, @server_socket) do |server, reactor|
          begin
            loop do
              connection = accept_connection
            end
          rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
          rescue Exception => e
          end
        end        
        loop do
          begin
            @reactor.run
            break unless @reactor.running?
          rescue Exception => e
          end
        end
        @server_socket.close
      end
      
      def stop;@reactor.stop;end
      
      alias :stop! :stop
            
      def trace=(trace);@trace = trace;end
      
      def maxfds=(maxfds);raise "not implemented";end
      
      def maxfds;raise "not implemented";end
      
      def to_s;"#{@host}:#{@port} (NeverBlock)";end
      
      def running?;@reactor.running?;end
      
      protected
        
        def accept_connection
          socket = @server_socket.accept_nonblock
          connection = ::Thin::ReactorConnection.new(socket, @reactor)
          connection.backend                 = self
          connection.app                     = @server.app
          connection.threaded                = false
          connection.post_init
        end

    end
  end
end
