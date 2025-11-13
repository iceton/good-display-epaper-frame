#!/usr/bin/env ruby

require 'fcgi'
require 'cgi'
require 'digest/md5'
require 'fileutils'
require 'json'
require 'shellwords'
require 'open3'

begin
  require 'chunky_png'
rescue LoadError
  # We'll handle this gracefully - chunky_png is optional but recommended
end

# Make stderr unbuffered for immediate logging
$stderr.sync = true

# ============================================================================
# CONFIGURATION
# ============================================================================

UPLOAD_PATH = ENV['UPLOAD_PATH'] || '/tmp/uploads'
OUTPUT_PATH = ENV['OUTPUT_PATH'] || ENV['UPLOAD_PATH'] || '/tmp/uploads'
IMAGEMAGICK_PATH = ENV['IMAGEMAGICK_PATH'] || 'magick'

# Display configuration
DISPLAY_WIDTH = 800
DISPLAY_HEIGHT = 480

# ============================================================================
# COLOR PALETTE CONSTANTS
# ============================================================================

# Direct color index mapping (0-6) for the GDEP073E01 7-color e-ink display
COLOR_INDICES = {
  'Black'  => 0,  # Display nibble 0x0
  'White'  => 1,  # Display nibble 0x1
  'Yellow' => 2,  # Display nibble 0x2
  'Red'    => 3,  # Display nibble 0x3
  'Blue'   => 5,  # Display nibble 0x5
  'Green'  => 6,  # Display nibble 0x6
}

# RGB palette for ImageMagick - 6 colors only
PALETTE_RGB = [
  [255, 255, 255],  # White
  [0, 0, 0],        # Black
  [255, 0, 0],      # Red
  [255, 255, 0],    # Yellow
  [0, 255, 0],      # Green
  [0, 0, 255],      # Blue
]

# Map RGB to color indices
RGB_TO_INDEX = {
  [255, 255, 255] => 1,  # White
  [0, 0, 0]       => 0,  # Black
  [255, 0, 0]     => 3,  # Red
  [255, 255, 0]   => 2,  # Yellow
  [0, 255, 0]     => 6,  # Green
  [0, 0, 255]     => 5,  # Blue
}

# Map color indices to hex values for C header file
INDEX_TO_HEX = {
  0 => 0x00,  # Black
  1 => 0xFF,  # White
  2 => 0xFC,  # Yellow
  3 => 0xE0,  # Red
  5 => 0x03,  # Blue
  6 => 0x1C,  # Green
}

INDEX_TO_NAME = {
  0 => 'Black',
  1 => 'White',
  2 => 'Yellow',
  3 => 'Red',
  5 => 'Blue',
  6 => 'Green'
}

# ============================================================================
# LOGGING
# ============================================================================

def debug_log(message)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  $stderr.puts "[#{timestamp}] #{message}"
end

# ============================================================================
# INITIALIZATION
# ============================================================================

debug_log("Starting upload_image.rb with integrated image processing")
debug_log("UPLOAD_PATH: #{UPLOAD_PATH}")
debug_log("OUTPUT_PATH: #{OUTPUT_PATH}")
debug_log("IMAGEMAGICK_PATH: #{IMAGEMAGICK_PATH}")
debug_log("Display: #{DISPLAY_WIDTH}x#{DISPLAY_HEIGHT}")

# Ensure directories exist
FileUtils.mkdir_p(UPLOAD_PATH) unless Dir.exist?(UPLOAD_PATH)
FileUtils.mkdir_p(OUTPUT_PATH) unless Dir.exist?(OUTPUT_PATH)
debug_log("Directories created/verified")

# ============================================================================
# IMAGE PROCESSING FUNCTIONS
# ============================================================================

def create_palette_image(work_dir)
  """Create a palette.bmp file for ImageMagick's -remap option"""
  debug_log("Creating palette image...")
  palette_path = File.join(work_dir, 'palette.bmp')

  # Create a 6x1 BMP with our 6 colors
  # We'll use ImageMagick to create it
  colors = PALETTE_RGB.map { |rgb| "rgb(#{rgb[0]},#{rgb[1]},#{rgb[2]})" }.join(' ')

  cmd = [
    IMAGEMAGICK_PATH,
    '-size', '6x1',
    'xc:white',
    '-depth', '8'
  ]

  # Add each color as a pixel
  PALETTE_RGB.each_with_index do |rgb, i|
    cmd += ['-fill', "rgb(#{rgb[0]},#{rgb[1]},#{rgb[2]})", '-draw', "point #{i},0"]
  end

  cmd += [palette_path]

  result = run_command(cmd)
  unless result[:success]
    raise "Failed to create palette: #{result[:stderr]}"
  end

  debug_log("  Created #{palette_path}")
  palette_path
end

def resize_and_pad_image(input_path, work_dir)
  """Resize and pad image to display dimensions"""
  debug_log("Resizing and padding image...")
  resized_path = File.join(work_dir, 'temp_resized.png')

  cmd = [
    IMAGEMAGICK_PATH, input_path,
    '-resize', "#{DISPLAY_WIDTH}x#{DISPLAY_HEIGHT}",
    '-background', 'black',
    '-gravity', 'center',
    '-extent', "#{DISPLAY_WIDTH}x#{DISPLAY_HEIGHT}",
    resized_path
  ]

  result = run_command(cmd)
  unless result[:success]
    raise "Failed to resize image: #{result[:stderr]}"
  end

  debug_log("  Created #{resized_path}")
  resized_path
end

def apply_dithering(resized_path, palette_path, work_dir)
  """Apply Floyd-Steinberg dithering and remap to 6-color palette"""
  debug_log("Applying dithering and color remapping...")
  dithered_path = File.join(work_dir, 'temp_dithered.bmp')

  cmd = [
    IMAGEMAGICK_PATH, resized_path,
    '-dither', 'FloydSteinberg',
    '-remap', palette_path,
    dithered_path
  ]

  result = run_command(cmd)
  unless result[:success]
    raise "Failed to dither image: #{result[:stderr]}"
  end

  debug_log("  Created #{dithered_path}")
  dithered_path
end

def rgb_to_color_index(rgb)
  """Convert RGB array to color index (0-6)"""
  # Try exact match first
  return RGB_TO_INDEX[rgb] if RGB_TO_INDEX.key?(rgb)

  # Find closest color
  min_dist = Float::INFINITY
  best_index = 1  # Default to white

  RGB_TO_INDEX.each do |palette_rgb, color_index|
    dist = rgb.zip(palette_rgb).sum { |p, c| (p - c) ** 2 }
    if dist < min_dist
      min_dist = dist
      best_index = color_index
    end
  end

  best_index
end

def read_image_pixels(image_path)
  """Read pixels from BMP image and convert to color indices"""
  debug_log("Converting pixels to color indices...")

  # Try using chunky_png if available
  if defined?(ChunkyPNG)
    return read_pixels_with_chunky_png(image_path)
  else
    # Fallback to ImageMagick
    return read_pixels_with_imagemagick(image_path)
  end
end

def read_pixels_with_chunky_png(image_path)
  """Read pixels using ChunkyPNG library"""
  debug_log("  Using ChunkyPNG to read pixels...")

  # Convert BMP to PNG first if needed
  if image_path.end_with?('.bmp')
    png_path = image_path.sub('.bmp', '_temp.png')
    cmd = [IMAGEMAGICK_PATH, image_path, png_path]
    result = run_command(cmd)
    raise "Failed to convert to PNG: #{result[:stderr]}" unless result[:success]
    image_path = png_path
  end

  image = ChunkyPNG::Image.from_file(image_path)
  data = []

  DISPLAY_HEIGHT.times do |y|
    DISPLAY_WIDTH.times do |x|
      pixel = image[x, y]
      r = ChunkyPNG::Color.r(pixel)
      g = ChunkyPNG::Color.g(pixel)
      b = ChunkyPNG::Color.b(pixel)

      color_index = rgb_to_color_index([r, g, b])
      data << color_index
    end
  end

  debug_log("  Converted #{data.length} pixels")
  data
end

def read_pixels_with_imagemagick(image_path)
  """Read pixels using ImageMagick txt: format"""
  debug_log("  Using ImageMagick to read pixels...")

  cmd = [IMAGEMAGICK_PATH, image_path, '-depth', '8', 'txt:-']
  result = run_command(cmd)
  raise "Failed to read pixels: #{result[:stderr]}" unless result[:success]

  data = []
  result[:stdout].each_line do |line|
    # Parse lines like: "0,0: (255,255,255) #FFFFFF white"
    next unless line =~ /^\d+,\d+:\s*\((\d+),(\d+),(\d+)\)/

    r, g, b = $1.to_i, $2.to_i, $3.to_i
    color_index = rgb_to_color_index([r, g, b])
    data << color_index
  end

  debug_log("  Converted #{data.length} pixels")
  data
end

def generate_binary_file(data, output_dir)
  """Generate binary file with color indices"""
  debug_log("Generating binary file...")
  bin_path = File.join(output_dir, 'image.bin')

  File.open(bin_path, 'wb') do |f|
    f.write(data.pack('C*'))
  end

  debug_log("  Generated #{bin_path}")
  debug_log("  File size: #{data.length} bytes (#{(data.length / 1024.0).round(1)} KB)")

  bin_path
end

def generate_header_file(data, output_dir)
  """Generate C header file for embedded use"""
  debug_log("Generating header file...")
  h_path = File.join(output_dir, 'image.h')

  File.open(h_path, 'w') do |f|
    f.puts 'const unsigned char image[] PROGMEM={'

    data.each_with_index do |color_index, i|
      f.print ',' if i > 0
      f.print "\n  " if i % 16 == 0
      hex_val = INDEX_TO_HEX[color_index] || 0x00
      f.print sprintf('0x%02X', hex_val)
    end

    f.puts "\n};"
  end

  debug_log("  Generated #{h_path}")
  h_path
end

def generate_color_statistics(data)
  """Generate color usage statistics"""
  debug_log("\nColor usage statistics:")

  color_counts = Hash.new(0)
  data.each { |color_index| color_counts[color_index] += 1 }

  stats = {}
  color_counts.keys.sort.each do |color_index|
    count = color_counts[color_index]
    name = INDEX_TO_NAME[color_index] || 'Unknown'
    percentage = (count.to_f / data.length) * 100

    debug_log(sprintf("  %d: %-8s - %6d pixels (%5.2f%%)", color_index, name, count, percentage))

    stats[name] = {
      index: color_index,
      count: count,
      percentage: percentage.round(2)
    }
  end

  stats
end

def run_command(cmd)
  """Execute shell command safely and capture output"""
  # Properly escape all arguments
  escaped_cmd = cmd.map { |arg| Shellwords.escape(arg) }.join(' ')

  stdout, stderr, status = Open3.capture3(escaped_cmd)

  {
    success: status.success?,
    stdout: stdout,
    stderr: stderr,
    exit_code: status.exitstatus
  }
rescue => e
  {
    success: false,
    stdout: '',
    stderr: e.message,
    exit_code: -1
  }
end

def process_image_complete(input_path, output_dir)
  """
  Complete image processing pipeline for e-ink display
  Returns hash with success status and details
  """
  debug_log("="*60)
  debug_log("Starting image processing for: #{input_path}")
  debug_log("="*60)

  work_dir = File.dirname(input_path)
  temp_files = []

  begin
    # Step 1: Create palette
    palette_path = create_palette_image(work_dir)
    temp_files << palette_path

    # Step 2: Resize and pad
    resized_path = resize_and_pad_image(input_path, work_dir)
    temp_files << resized_path

    # Step 3: Apply dithering
    dithered_path = apply_dithering(resized_path, palette_path, work_dir)
    temp_files << dithered_path

    # Step 4: Convert to color indices
    data = read_image_pixels(dithered_path)

    if data.length != DISPLAY_WIDTH * DISPLAY_HEIGHT
      raise "Pixel count mismatch: expected #{DISPLAY_WIDTH * DISPLAY_HEIGHT}, got #{data.length}"
    end

    # Step 5: Generate binary file
    bin_path = generate_binary_file(data, output_dir)

    # Step 6: Generate header file
    h_path = generate_header_file(data, output_dir)

    # Step 7: Generate statistics
    stats = generate_color_statistics(data)

    debug_log("\nSuccess! Image processed:")
    debug_log("  Binary: #{bin_path}")
    debug_log("  Header: #{h_path}")
    debug_log("  Display dimensions: #{DISPLAY_WIDTH}x#{DISPLAY_HEIGHT}")
    debug_log("  Total pixels: #{data.length}")

    {
      success: true,
      binary_path: bin_path,
      header_path: h_path,
      dimensions: { width: DISPLAY_WIDTH, height: DISPLAY_HEIGHT },
      total_pixels: data.length,
      color_stats: stats
    }
  rescue => e
    debug_log("ERROR in image processing: #{e.message}")
    debug_log("  Backtrace: #{e.backtrace[0..2].join("\n  ")}")

    {
      success: false,
      error: e.message
    }
  ensure
    # Clean up temporary files
    debug_log("Cleaning up temporary files...")
    temp_files.each do |temp_file|
      if File.exist?(temp_file)
        File.delete(temp_file)
        debug_log("  Removed #{temp_file}")
      end
    end
  end
end

# ============================================================================
# FILE UPLOAD HANDLERS
# ============================================================================

def handle_file_upload(cgi)
  """Handle file upload from CGI request"""
  uploaded_file = cgi['image']

  if uploaded_file.nil? || !uploaded_file.respond_to?(:original_filename) || uploaded_file.original_filename.empty?
    debug_log("ERROR: No valid file uploaded")
    return {
      success: false,
      error: "No file uploaded. Please provide a file with the 'image' field."
    }
  end

  debug_log("File uploaded: #{uploaded_file.original_filename}")

  begin
    # Get file extension from original filename
    original_filename = uploaded_file.original_filename
    extension = File.extname(original_filename)
    debug_log("File extension: #{extension}")

    # Determine source file path
    source_path = if uploaded_file.respond_to?(:path) && uploaded_file.path
      # Large file - already on disk as tempfile
      debug_log("Large file detected, using tempfile: #{uploaded_file.path}")
      uploaded_file.path
    else
      # Small file - in memory, write it once
      temp_filename = "temp_#{Time.now.to_i}_#{rand(100000)}#{extension}"
      temp_path = File.join(UPLOAD_PATH, temp_filename)
      debug_log("Small file detected, writing to: #{temp_path}")
      File.open(temp_path, 'wb') { |f| f.write(uploaded_file.read) }
      debug_log("File written successfully")
      temp_path
    end

    # Calculate MD5 hash from the file on disk
    debug_log("Calculating MD5 hash for: #{source_path}")
    md5_hash = Digest::MD5.file(source_path).hexdigest
    file_size = File.size(source_path)
    debug_log("MD5: #{md5_hash}, Size: #{file_size} bytes")

    # Move/rename file to final MD5-based name
    filename = "#{md5_hash}#{extension}"
    file_path = File.join(UPLOAD_PATH, filename)
    debug_log("Moving file from #{source_path} to #{file_path}")
    FileUtils.mv(source_path, file_path, force: true)
    FileUtils.chmod(0644, file_path)
    debug_log("File moved successfully")

    # Process the image
    debug_log("Starting image processing...")
    processing_result = process_image_complete(file_path, OUTPUT_PATH)

    # Return success response
    debug_log("Building response")
    response = {
      success: true,
      filename: filename,
      md5: md5_hash,
      path: file_path,
      size: file_size,
      original_filename: original_filename,
      processing: processing_result
    }

    debug_log("Upload successful: #{filename}")
    response

  rescue => e
    # Cleanup on failure
    debug_log("ERROR in processing: #{e.class} - #{e.message}")
    debug_log("Backtrace: #{e.backtrace[0..2].join("\n")}")

    File.delete(source_path) if defined?(source_path) && File.exist?(source_path)
    File.delete(file_path) if defined?(file_path) && file_path != source_path && File.exist?(file_path)

    {
      success: false,
      error: "Failed to process upload: #{e.message}"
    }
  end
end

def validate_request_method(env)
  """Validate that the request is a POST"""
  if env['REQUEST_METHOD'] != 'POST'
    debug_log("ERROR: Invalid method - #{env['REQUEST_METHOD']}")
    return {
      success: false,
      error: "Only POST requests are accepted. Received: #{env['REQUEST_METHOD']}"
    }
  end
  nil
end

# ============================================================================
# FASTCGI REQUEST HANDLER
# ============================================================================

FCGI.each do |request|
  begin
    debug_log("=== New request received ===")

    # Set up environment and input stream for CGI
    $stdin = request.in
    ENV.update(request.env)
    debug_log("Request method: #{ENV['REQUEST_METHOD']}")
    debug_log("Content-Type: #{ENV['CONTENT_TYPE']}")
    debug_log("Content-Length: #{ENV['CONTENT_LENGTH']}")

    # Validate request method
    error_response = validate_request_method(ENV)
    response_body = if error_response
      error_response.to_json
    else
      # Parse the CGI request
      debug_log("Parsing CGI request")
      cgi = CGI.new
      debug_log("CGI parsed successfully")

      # Handle file upload and processing
      result = handle_file_upload(cgi)
      result.to_json
    end

    # Set response headers and output
    debug_log("Sending response (#{response_body.length} bytes)")
    request.out do
      "Content-Type: application/json; charset=utf-8\r\n\r\n#{response_body}"
    end

    debug_log("Request completed")
  rescue => e
    # Catch-all error handler for unexpected errors
    debug_log("FATAL ERROR: #{e.class} - #{e.message}")
    debug_log("Backtrace: #{e.backtrace[0..5].join("\n")}")

    error_response = {
      success: false,
      error: "Internal server error: #{e.message}"
    }.to_json

    request.out do
      "Content-Type: application/json; charset=utf-8\r\n\r\n#{error_response}"
    end
  ensure
    request.finish
  end
end
