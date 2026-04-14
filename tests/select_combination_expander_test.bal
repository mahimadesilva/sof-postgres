import ballerina/test;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

# Convenience constructor: a bare select element with no special fields.
# + return - empty `ViewDefinitionSelect`
isolated function plainSelect() returns ViewDefinitionSelect {
    return {};
}

# Convenience constructor: a select element with the given unionAll branches.
# + branches - union branch array to set on the select element
# + return - `ViewDefinitionSelect` with `unionAll` set to `branches`
isolated function selectWithUnion(ViewDefinitionSelect[] branches) returns ViewDefinitionSelect {
    return {unionAll: branches};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@test:Config {}
function testExpandEmpty() {
    SelectCombination[] result = expandCombinations([]);
    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0].selects.length(), 0);
    test:assertEquals(result[0].unionChoices.length(), 0);
}

@test:Config {}
function testExpandNoUnion() {
    ViewDefinitionSelect sel = plainSelect();
    SelectCombination[] result = expandCombinations([sel]);
    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0].selects.length(), 1);
    test:assertEquals(result[0].unionChoices, [-1]);
}

@test:Config {}
function testExpandSingleUnion() {
    // One select with 2 simple unionAll branches → 2 combinations.
    ViewDefinitionSelect sel = selectWithUnion([plainSelect(), plainSelect()]);
    SelectCombination[] result = expandCombinations([sel]);

    test:assertEquals(result.length(), 2);
    test:assertEquals(result[0].unionChoices, [0]);
    test:assertEquals(result[1].unionChoices, [1]);
    // Both combinations reference the same outer select element.
    test:assertTrue(result[0].selects[0] === sel);
    test:assertTrue(result[1].selects[0] === sel);
}

@test:Config {}
function testExpandTwoSelectsNoUnion() {
    // Two selects, neither has unionAll → 1 combination with two -1 choices.
    SelectCombination[] result = expandCombinations([plainSelect(), plainSelect()]);
    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0].unionChoices, [-1, -1]);
    test:assertEquals(result[0].selects.length(), 2);
}

@test:Config {}
function testExpandCartesianProduct() {
    // Select A (no union) × select B (2 union branches) → 2 combinations.
    ViewDefinitionSelect selA = plainSelect();
    ViewDefinitionSelect selB = selectWithUnion([plainSelect(), plainSelect()]);
    SelectCombination[] result = expandCombinations([selA, selB]);

    test:assertEquals(result.length(), 2);
    test:assertEquals(result[0].unionChoices, [-1, 0]);
    test:assertEquals(result[1].unionChoices, [-1, 1]);
    // Both combinations carry selA as the first element.
    test:assertTrue(result[0].selects[0] === selA);
    test:assertTrue(result[1].selects[0] === selA);
}

@test:Config {}
function testExpandTwoSelectsBothUnion() {
    // Select A (2 union branches) × select B (2 union branches) → 4 combinations.
    ViewDefinitionSelect selA = selectWithUnion([plainSelect(), plainSelect()]);
    ViewDefinitionSelect selB = selectWithUnion([plainSelect(), plainSelect()]);
    SelectCombination[] result = expandCombinations([selA, selB]);

    test:assertEquals(result.length(), 4);
    test:assertEquals(result[0].unionChoices, [0, 0]);
    test:assertEquals(result[1].unionChoices, [0, 1]);
    test:assertEquals(result[2].unionChoices, [1, 0]);
    test:assertEquals(result[3].unionChoices, [1, 1]);
}

@test:Config {}
function testExpandNestedUnion() {
    // One select whose unionAll has:
    //   branch 0: simple (no nested union)
    //   branch 1: itself has 2 unionAll branches (nested)
    // Expected: 3 combinations total (1 + 2).
    ViewDefinitionSelect nestedBranch = selectWithUnion([plainSelect(), plainSelect()]);
    ViewDefinitionSelect outerSel = selectWithUnion([plainSelect(), nestedBranch]);
    SelectCombination[] result = expandCombinations([outerSel]);

    test:assertEquals(result.length(), 3);
    // Combination from branch 0 (simple).
    test:assertEquals(result[0].unionChoices, [0]);
    test:assertEquals(result[0].selects.length(), 1);
    // Combinations from branch 1 (nested) — outer unionIndex is 1, then nested indices.
    test:assertEquals(result[1].unionChoices, [1, 0]);
    test:assertEquals(result[1].selects.length(), 2);
    test:assertEquals(result[2].unionChoices, [1, 1]);
    test:assertEquals(result[2].selects.length(), 2);
}
