require 'socket'
require 'fileutils'
require 'zlib'
require 'stringio'

def gzip_compress(data)
  buffer = StringIO.new
  gz = Zlib::GzipWriter.new(buffer)
  gz.write(data)
  gz.close
  buffer.string
end

def find_file(folder_path, target_filename)
  Dir.glob("#{folder_path}/**/#{target_filename}") do |file|
    return file if File.file?(file)
  end
  nil
end

def create_directory(dir_name)
  if Dir.exist?(dir_name)
    puts "Directory '#{dir_name}' already exists."
  else
    FileUtils.mkdir_p(dir_name)
    puts "Directory '#{dir_name}' created successfully."
  end
end

def send_response(socket, status, connection = '', accept_encoding = '', headers = {}, body = '')
  connection = connection&.strip&.downcase
  headers['Connection'] = connection == 'close' ? 'close' : 'keep-alive'

  # Compress if client accepts gzip and body is not empty
  if accept_encoding.include?('gzip') && !body.empty?
    body = gzip_compress(body)
    headers['Content-Encoding'] = 'gzip'
  end

  headers['Content-Length'] = body.bytesize.to_s
  headers['Content-Type'] ||= 'text/plain'

  # Construct header
  header_string = headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")
  response = "HTTP/1.1 #{status}\r\n#{header_string}\r\n\r\n"

  # Write header and raw body
  socket.write(response)
  socket.write(body) unless body.empty?
end

server = TCPServer.new('localhost', 4221)
puts 'Server running on http://localhost:4221'

loop do
  client_socket, = server.accept

  Thread.new(client_socket) do |socket|
    begin
      loop do
        # Skip blank lines (some clients send \r\n first)
        request_line = nil
        while (line = socket.gets)
          line = line.strip
          next if line.empty?
          request_line = line
          break
        end

        break unless request_line # If still nil, client closed connection

        tcp_request_part = request_line.split
        break if tcp_request_part.size < 2 # Malformed request

        request_type = tcp_request_part[0]
        page_path = tcp_request_part[1]

        # Read all headers
        headers = {}
        while (line = socket.gets) && (line != "\r\n")
          key, value = line.chomp.split(': ', 2)
          headers[key] = value
        end

        connection_header = headers['Connection']&.downcase
        accept_encoding = headers['Accept-Encoding']&.downcase || ''
        accept_encoding = accept_encoding.split(', ')

        # Handle GET
        if request_type == 'GET'
          if page_path == '/'
            send_response(socket, '200 OK')

          elsif page_path.include? '/files/'
            folder_name = ARGV[1]
            file_name = page_path.split('/files/').last
            file_path = find_file(folder_name, file_name)
            if file_path
              file_data = File.read(file_path)
              send_response(socket, '200 OK', connection_header, accept_encoding, { 'Content-Type' => 'application/octet-stream' }, file_data)
            else
              send_response(socket, '404 Not Found')
            end

          elsif page_path.include? '/echo/'
            echo_data = page_path.split('/echo/')[1]
            send_response(socket, '200 OK', connection_header, accept_encoding, { 'Content-Type' => 'text/plain' }, echo_data)

          elsif page_path.include? '/user-agent'
            user_agent = headers['User-Agent'] || 'Unknown'
            send_response(socket, '200 OK', connection_header, accept_encoding, { 'Content-Type' => 'text/plain' }, user_agent)

          else
            send_response(socket, '404 Not Found')
          end

        # Handle POST
        elsif request_type == 'POST'
          create_directory ARGV[1] if ARGV[0] == '--directory'
          if page_path.include? '/files/'
            file_name = page_path.split('/files/').last
            content_length = headers['Content-Length'].to_i
            post_body = socket.read(content_length)
            file_path = File.join(ARGV[1], file_name)
            File.write(file_path, post_body)
            send_response(socket, '201 Created')
          else
            send_response(socket, '404 Not Found')
          end

        else
          # Method not allowed
          send_response(socket, '405 Method Not Allowed')
        end

        # Close if connection header is "close"
        break if connection_header == 'close'
      end
    rescue => e
      puts "Error: #{e.message}"
      puts e.backtrace
    ensure
      socket.close
    end
  end
end
