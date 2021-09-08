import unittest
import flac

suite "flac_header":
    test "flac_blocks":
        let flac_blocks = readFlacFile("test_files/Ashes.flac")

        check(flac_blocks.len() == 4)

        let expected_blocks = @[btStreamInfo, btVorbisComment, btPicture, btPadding]

        for i, flac_block in flac_blocks:
            check(flac_block.kind == expected_blocks[i])

    test "vorbis_comment_search":
        let vorbis_comment = @["TITLE=Ashes", "ARTIST=Ghost", "ALBUM ARTIST=Ghost", "ALBUMARTIST=Ghost", "ALBUM=Prequelle", 
            "TRACKNUMBER=1", "YEAR=2018", "GENRE=Heavy Metal", "DATE=2018", "ENCODER=MediaMonkey 4.1.19", "ENSEMBLE=Ghost", 
            "REPLAYGAIN_TRACK_PEAK=0.988525", "REPLAYGAIN_TRACK_GAIN=-4.340000 dB", "REPLAYGAIN_ALBUM_GAIN=-8.210000 dB"]
        
        let tags = @["TITLE", "ARTIST", "ALBUM ARTIST", "ALBUMARTIST", "ALBUM", 
            "TRACKNUMBER", "YEAR", "GENRE", "DATE", "ENCODER", "ENSEMBLE", 
            "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN"]
        
        let values = @["Ashes", "Ghost", "Ghost", "Ghost", "Prequelle", 
            "1", "2018", "Heavy Metal", "2018", "MediaMonkey 4.1.19", "Ghost", 
            "0.988525", "-4.340000 dB", "-8.210000 dB"]
        
        # Ensure that each tag is found with the correct value
        for i in 0..<vorbis_comment.len():
            check(searchVorbisComment(vorbis_comment, tags[i]) == values[i])
        
        # Search for a tag that doesn't exist
        check(searchVorbisComment(vorbis_comment, "APPLE") == "")
