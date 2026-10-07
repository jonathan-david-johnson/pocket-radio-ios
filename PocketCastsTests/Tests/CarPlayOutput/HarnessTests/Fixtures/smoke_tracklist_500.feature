Feature: Smoke scenario with a failing tracklist (harness self-test; expected to fail)
  Background:
    Given the system now-playing display is empty
    And a station "KCRW Eclectic 24" that streams from the local test server

  Scenario: The tracklist endpoint fails
    Given the station's tracklist lists only "Song 1" by "Artist 1" with red artwork
    And the station's tracklist fails with status 500
    When the listener starts the station
    And the stream announces "Song 1" by "Artist 1"
    Then the display shows the title "Song 1", the artist "Artist 1" and the album "Album"
    And the display shows red artwork
