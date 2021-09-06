import strformat
import flac

let flac_blocks = readFlacFile("test_files/Ashes.flac")

for flac_block in flac_blocks:
    echo(flac_block.kind)

    if flac_block.kind == btVorbisComment:
        echo(flac_block.user_comments)
  
    if flac_block.kind == btSeekTable:
        echo(flac_block.seek_points)
    
    echo("")
