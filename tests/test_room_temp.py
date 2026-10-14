from miraie_ac_mac.core import room_temp


def test_plain_reading_on_firmware_302_is_kept():
    # What a real AC on firmware 3.02 sent; the library turned it into None.
    assert room_temp("23.00", "3.02") == 23.0


def test_plain_half_degree_is_not_read_as_packed():
    # 50 after the dot would be 50°, too hot for a room, so it is plain.
    assert room_temp("23.97", "3.02") == 23.97


def test_ambiguous_reading_drops_the_impossible_one():
    # Real reading on 15 Oct: "23.12" is 23.12°, not the packed 12.09°.
    assert room_temp("23.12", "3.02") == 23.12
    # And the other way round: 12.22° is too cold for the room, so packed 22.05°.
    assert room_temp("12.22", "3.02") == 22.05


def test_packed_reading_still_decodes():
    # Packed format: "<fraction byte>.<whole degrees>", 64/256 = 0.25.
    assert room_temp("64.27", "3.02") == 27.25


def test_older_firmware_and_junk():
    assert room_temp("27", "2.10") == 27.0
    assert room_temp("", "3.02") is None
    assert room_temp("255.0", "3.02") is None
