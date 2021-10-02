import streams
import strformat
import bitops
import algorithm
import sequtils
import strutils
import streams
import re
import tables

type UnreachableError* = object of Defect

type  # TODO: Constructors. Make "sub-objects" for each block type?
  FlacBlockHeader* = object
    last_block*: bool
    block_type*: uint8
    block_length*: uint32
  
  SeekPoint* = object
    sample_number*: uint64
    offset*: uint64
    num_samples*: uint16
  
  BlockType* = enum
    btStreamInfo,
    btApplication,
    btVorbisComment,
    btPadding,
    btSeekTable,
    btPicture,
    btCueSheet,
    btInvalid,
    btReserved
  FlacBlock* = FlacBlockObj
  FlacBlockObj* = object
    header*: FlacBlockHeader
    case kind*: BlockType  # Move from variant type to inheriance?
    of btStreamInfo:
      min_block_size, max_block_size: uint16
      min_frame_size, max_frame_size: uint32
      sample_rate: uint32
      num_channels, bits_per_sample: uint8
      total_samples: uint64
      #md5_signiture: array[0..15, uint8]
      md5_signiture: seq[uint8]
    of btApplication:
      application_id: uint32
      application_data: seq[uint8]
    of btVorbisComment:
      vendor_string*: string
      user_comments*: Table[string, string]
    of btPadding:
      pad_len: int
    of btSeekTable:
      seek_points*: seq[SeekPoint]
    of btPicture:
      picture_type, width, height, color_depth, num_colors: uint8
      mime_type, picture_description: string
      picture_data: seq[uint8]
    of btCueSheet:
      cue: bool
    of btReserved:
      reserved_number: uint8
    of btInvalid:
      invalid_number: uint8

proc readU64BE(bytes: openArray[uint8], start_bit, end_bit: uint): uint64 =
  if (end_bit - start_bit + 1) > 64:
    raise newException(ValueError, "Result is too large to fit into a uint64")
  elif(start_bit div 8 == end_bit div 8):
    # Same byte
    return bytes[start_bit div 8].masked(0 .. int(end_bit - start_bit))

  # Combine bytes into a single uint
  for i in start_bit div 8 .. end_bit div 8:
    result = result.rotateLeftBits(8) or bytes[i]

  # Mask out unnecessary bits
  result = result.rotateRightBits((end_bit + 1) mod 8).masked(0 .. int(end_bit - start_bit))

proc readU64BE(bytes: openArray[uint8]): uint64 =
  if (bytes.len()) > 8:
    raise newException(ValueError, "Result is too large to fit into a uint64")

  result = bytes[0]

  for i in 1..<bytes.len:
    result = result.rotateLeftBits(8) or bytes[i]

proc readU32LE(bytes: openArray[uint8]): uint32 =
  if (bytes.len()) > 4:
    raise newException(ValueError, "Result is too large to fit into a uint32")

  result = bytes[0]

  for i in 1..<bytes.len:
    result = result or uint32(bytes[i]).rotateLeftBits(i * 8)

proc newFlacBlock(block_header: FlacBlockHeader, strm: FileStream): FlacBlock =
  case block_header.block_type
  of 0:       # StreamInfo
    # Sanity check. StreamInfo should always be 34 bytes
    doAssert(block_header.block_length == 34)

    var buffer: array[34, uint8]
    doAssert(strm.readData(addr(buffer), 34) == 34)

    let min_block_size = uint16(readU64BE(buffer[0..1]))
    let max_block_size = uint16(readU64BE(buffer[2..3]))
    let min_frame_size = uint32(readU64BE(buffer[4..6]))
    let max_frame_size = uint32(readU64BE(buffer[7..9]))
    let sample_rate = uint32(readU64BE(buffer, 80, 99))
    let num_channels = uint8(readU64BE(buffer, 100, 102))
    let bits_per_sample = uint8(readU64BE(buffer, 103, 107)) + 1
    let total_samples = readU64BE(buffer, 108, 143)

    var md5_signiture = buffer[18..33]
    md5_signiture = md5_signiture.reversed()

    return FlacBlock(header: block_header, kind: btStreamInfo,
      min_block_size: min_block_size, max_block_size: max_block_size,
      min_frame_size: min_frame_size, max_frame_size: max_frame_size,
      sample_rate: sample_rate, num_channels: num_channels,
      bits_per_sample: bits_per_sample, total_samples: total_samples,
      md5_signiture: md5_signiture)
  of 1:       # Padding
    strm.setPosition(strm.getPosition() + int(block_header.block_length))
    return FlacBlock(header: block_header, kind: btPadding, pad_len: int(block_header.block_length))
  of 2:       # Application
    let app_len = int(block_header.block_length)

    var buffer: array[1024, uint8]
    doAssert(strm.readData(addr(buffer), app_len) == app_len)

    let application_id = uint32(readU64BE(buffer, 0, 31))
    let application_data = buffer[4..<app_len]

    return FlacBlock(header: block_header, kind: btApplication,
      application_id: application_id, application_data: application_data)
  of 3:       # SeekTable
    # Sanity check. SeekTable should always be a multiple of 18
    doAssert(block_header.block_length mod 18 == 0)

    let seek_table_len = int(block_header.block_length)
    let num_seek_points = int(seek_table_len / 18)

    var buffer: array[2048, uint8]
    doAssert(strm.readData(addr(buffer), seek_table_len) == seek_table_len)

    var seek_points: seq[SeekPoint]

    for i in 0..<num_seek_points:
      let pos = i * 18

      let sample_number = readU64BE(buffer[pos + 0..pos + 7])
      let offset = readU64BE(buffer[pos + 8..pos + 15])
      let num_samples = uint16(readU64BE(buffer[pos + 16..pos + 17]))

      seek_points.add(SeekPoint(sample_number: sample_number, offset: offset, num_samples: num_samples))

    return FlacBlock(header: block_header, kind: btSeekTable, seek_points: seek_points)
  of 4:       # VorbisComment
    let vorbis_len = int(block_header.block_length)
    var buffer: array[1024, uint8]
    doAssert(strm.readData(addr(buffer), vorbis_len) == vorbis_len)

    # Vorbis Comments use little endian
    let vendor_length = readU32LE(buffer[0..3])

    # Grab bytes for vendor string, convert to chars, join into a string
    let vendor_string = buffer[4..<vendor_length + 4].mapIt(char(it)).join()

    var pos = 4 + vendor_length

    let user_comment_list_len = readU32LE(buffer[pos..<pos + 4])
    pos += 4

    var user_comments = initTable[string, string]()

    for _ in 0..<user_comment_list_len:
      let comment_len = readU32LE(buffer[pos..<pos + 4])
      pos += 4

      let user_comment = buffer[pos..<pos + comment_len].mapIt(char(it)).join()
      let entry_split = user_comment.split(re"=")

      user_comments[entry_split[0]] = entry_split[1]

      pos += comment_len

    return FlacBlock(header: block_header, kind: btVorbisComment,
      vendor_string: vendor_string, user_comments: user_comments)
  of 5:       # Cuesheet (INCOMPLETE)
    echo(block_header.block_length)
    strm.setPosition(strm.getPosition() + int(block_header.block_length)) #REMOVE
    return FlacBlock(header: block_header, kind: btCueSheet, cue: true)
  of 6:       # Picture (WIP)
    var buffer: array[64, uint8]

    # Read the first 8 bytes for the picture type and the mime_type_length
    doAssert(strm.readData(addr(buffer), 8) == 8)
    let picture_type: uint8 = uint8(readU64BE(buffer, 0, 31))
    let mime_type_length: int = int(readU64BE(buffer, 32, 63))

    # Read the mime_type from file and convert the bytes into a string
    var mime_type: string = ""
    doAssert(strm.readData(addr(buffer), mime_type_length) == mime_type_length)
    for idx, v in buffer[0..<mime_type_length]:
      mime_type.add(chr(v))

    # Read the next 4 bytes for the picture_description_length
    doAssert(strm.readData(addr(buffer), 4) == 4)
    let picture_description_length: int = int(readU64BE(buffer, 0, 31))
    # echo("Picture desc length: ", picture_description_length)

    # Read the picture_description from file and convert the bytes into a string
    doAssert(strm.readData(addr(buffer), picture_description_length) == picture_description_length)
    var picture_description: string = ""
    for idx, v in buffer[0..<picture_description_length]:
      picture_description.add(chr(v))

    # Read the next 20 bytes for the picture's width and height, 
    # color depth, number of colors, and length of the picture data
    doAssert(strm.readData(addr(buffer), 20) == 20)
    let width: uint8 = uint8(readU64BE(buffer, 0, 31))
    let height: uint8 = uint8(readU64BE(buffer, 32, 63))
    let color_depth = uint8(readU64BE(buffer, 64, 95))
    let num_colors = uint8(readU64BE(buffer, 96, 127))
    let picture_data_length = int(readU64BE(buffer, 128, 159))

    # echo("Width: ", width)
    # echo("Height: ", height)
    # echo("color_depth: ", color_depth)
    # echo("num_colors: ", num_colors)
    # echo("picture_data_length: ", picture_data_length)

    var picture_data: seq[uint8]
    #var picture_buffer: array[1048576, uint8]
    var picture_buffer: array[1024, uint8]

    var picture_bytes_remaining = picture_data_length
    while picture_bytes_remaining > 0:
       let to_read = min(picture_buffer.len(), picture_bytes_remaining)

       doAssert(strm.readData(addr(picture_buffer), to_read) == to_read)
       picture_data.add(picture_buffer[0..<to_read])

       picture_bytes_remaining -= to_read

    # var s = newFileStream("test_files/test_pic.png", fmWrite)
    # for b in picture_data:
    #   s.write(b)
    # s.close()

    return FlacBlock(header: block_header, kind: btPicture, picture_type: picture_type, width: width, height: height,
                    color_depth: color_depth, num_colors: num_colors, picture_description: picture_description,
                    picture_data: picture_data)
  of 7..126:  # Reserved
    return FlacBlock(header: block_header, kind: btReserved, reserved_number: block_header.block_type)
  else:       # Invalid block
    strm.setPosition(strm.getPosition() + int(block_header.block_length)) # Skip over invalid block
    return FlacBlock(header: block_header, kind: btInvalid, invalid_number: block_header.block_type)

  raise newException(UnreachableError, "newFlacBlock terminated without returning a flac block")

proc readBlock(strm : FileStream): FlacBlock =
  var header_bytes: array[4, uint8]
  doAssert(strm.readData(addr(header_bytes), 4) == 4)

  let last_block = (header_bytes[0] and 0b1000_0000) == 128
  let block_type = header_bytes[0] and 0b0111_1111

  let block_length = uint32(readU64BE(header_bytes, 8, 31))

  let block_header = FlacBlockHeader(last_block: last_block, block_type: block_type,
    block_length: block_length)

  #echo(&"last_block: {last_block}; block_type: {block_type}; block_length: {block_length} bytes")

  result = newFlacBlock(block_header, strm)

proc readFlacFile*(file_location: string): seq[FlacBlock] =
  # TODO: make sure file exists
  var strm = newFileStream(file_location, fmRead)

  let magic_number = strm.readStr(4)
  if magic_number != "fLaC":
    # Not a flac file
    return

  # Get all the blocks in the file
  while true:
    var tmp_block = readBlock(strm)

    result.add(tmp_block)
    
    if tmp_block.header.last_block:
      break