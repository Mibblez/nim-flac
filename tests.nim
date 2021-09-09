import unittest
import flac
import tables

suite "flac_header":
    setup:
        let flac_blocks = readFlacFile("test_files/Ashes.flac")

        check(flac_blocks.len() == 4)

        let expected_blocks = @[btStreamInfo, btVorbisComment, btPicture, btPadding]

        for i, flac_block in flac_blocks:
            check(flac_block.kind == expected_blocks[i])
        
        let vorbis_comment = flac_blocks[1]

    test "vorbis_comment_search":
        let user_comments = vorbis_comment.user_comments

        let expected_comments = {"ALBUM": "Prequelle", "ARTIST": "Ghost", "TITLE": "Ashes",
            "REPLAYGAIN_TRACK_GAIN": "-4.340000 dB", "ALBUM ARTIST": "Ghost",
            "DATE": "2018", "REPLAYGAIN_ALBUM_GAIN": "-8.210000 dB",
            "ENCODER": "MediaMonkey 4.1.19", "TRACKNUMBER": "1",
            "REPLAYGAIN_TRACK_PEAK": "0.988525", "YEAR": "2018",
            "ENSEMBLE": "Ghost", "ALBUMARTIST": "Ghost", "GENRE": "Heavy Metal"}.toTable
        
        for k, v in expected_comments:
            check(user_comments.hasKey(k))
            check(user_comments[k] == v)
