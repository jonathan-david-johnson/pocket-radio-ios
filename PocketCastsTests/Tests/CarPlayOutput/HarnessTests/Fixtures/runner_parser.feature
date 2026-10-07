# a comment
Feature: Parser fixture
  Free-form description line that is ignored.

  Background:
    Given the world is up
    # comment inside background
    And the radio is tuned

  @ios @carplay
  Scenario: First
    When a song plays
    And a second song plays
    But not a third
    Then the title is "Alpha"

  Scenario: Second has no tags
    Then the title is "Beta"
