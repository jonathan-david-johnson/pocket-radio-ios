Feature: Synthetic strict expected failures

  Scenario: Synthetic artwork policy
    Given synthetic playback is ready
    Then synthetic artwork is blue
    And synthetic live marker is present
