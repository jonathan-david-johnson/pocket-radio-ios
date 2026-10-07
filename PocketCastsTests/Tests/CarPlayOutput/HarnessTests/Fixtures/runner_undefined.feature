Feature: Undefined step fixture

  Scenario: Third step is undefined
    Given step one
    When step two
    Then nobody defined this step
    And step four
